"""Conservative reconciliation of already compiled OSM routing items.

Only combine copies whose directed geometry and attributes agree. Different
intersection splits are normalized to their union; coordinate coincidences
between different OSM ways are never used to invent a split.
"""

import collections
import sqlite3
import struct

from binfile import records


class MergeError(ValueError):
    pass


def coordinates(data):
    count = struct.unpack_from("<I", data, 8)[0]
    return tuple(struct.iter_unpack("<ii", data[12 : 12 + count * 4]))


def attribute_data(data):
    result = {}
    for _, _, _, attrs in records(data):
        for kind, pos, size in attrs:
            if kind in result:
                raise MergeError(
                    "Repeated routing attribute needs explicit reconciliation"
                )
            result[kind] = data[pos : pos + size]
    return result


def item(kind, coords, attrs):
    body = b"".join(struct.pack("<ii", *c) for c in coords)
    for atype, value in sorted(attrs.items()):
        body += struct.pack("<II", 1 + len(value) // 4, atype) + value
    return struct.pack("<III", len(body) // 4 + 2, kind, len(coords) * 2) + body


def record_identity(data, ignored):
    """Comparable record retaining repeated attributes such as polygon holes."""
    _, _, kind, attributes = next(records(data))
    coords = coordinates(data)
    attrs = sorted(
        (atype, data[pos : pos + size])
        for atype, pos, size in attributes
        if atype not in ignored
    )
    body = b"".join(struct.pack("<ii", *c) for c in coords)
    for atype, value in attrs:
        body += struct.pack("<II", 1 + len(value) // 4, atype) + value
    return struct.pack("<III", len(body) // 4 + 2, kind, len(coords) * 2) + body


def tombstone(data):
    """Keep word offsets valid while making an old item non-renderable/unroutable."""
    length = len(data) // 4 - 1
    if length < 4:
        raise MergeError("Routing record too short to replace")
    return struct.pack("<IIIII", length, 0, 0, length - 3, 0) + bytes(len(data) - 20)


class Overlap:
    def __init__(self, path, attrs, items, road_types):
        self.db = sqlite3.connect(path)
        self.attrs, self.items, self.road_types = attrs, items, road_types
        self.restrictions = {
            items["street_turn_restriction_no"],
            items["street_turn_restriction_only"],
        }
        self.counts = collections.Counter()
        self.db.executescript("""
            CREATE TABLE roads (way INTEGER, source INTEGER, tile INTEGER, offset INTEGER, data BLOB);
            CREATE TABLE areas (relation INTEGER, source INTEGER, tile INTEGER, offset INTEGER, data BLOB);
            CREATE TABLE restrictions (source INTEGER, tile INTEGER, offset INTEGER, data BLOB);
            CREATE TABLE features (identity BLOB, kind INTEGER, source INTEGER, tile INTEGER,
                                   offset INTEGER, data BLOB);
            CREATE TABLE replacements (source INTEGER, tile INTEGER, offset INTEGER, data BLOB,
                                       PRIMARY KEY(source,tile,offset));
            CREATE TABLE tails (source INTEGER, tile INTEGER, data BLOB);
            CREATE TABLE endpoints (source INTEGER, start BLOB, end BLOB, near_start BLOB, near_end BLOB,
                                    segments INTEGER, PRIMARY KEY(source,start,end));
            CREATE TABLE vertices (point BLOB, way INTEGER, source INTEGER,
                                   PRIMARY KEY(point,way,source));
            CREATE TABLE seen_restrictions (data BLOB PRIMARY KEY);
        """)

    def add(self, source, tile, data):
        for start, end, kind, attributes in records(data):
            for atype, _, _ in attributes:
                # Road offsets become tombstones; these optional indexes need
                # rebuilding, not relocation to the now-inactive original road.
                if atype in (
                    self.attrs["item_id"],
                    self.attrs["zipfile_ref_block"],
                    self.attrs["ch_edge"],
                ):
                    raise MergeError(
                        "Indexed item/block or CH references require rebuilding; unsupported input"
                    )
            record = bytes(data[start:end])
            if kind in self.road_types:
                ids = {
                    atype: data[pos : pos + size]
                    for atype, pos, size in attributes
                    if atype in (self.attrs["osm_wayid"], self.attrs["osm_relationid"])
                }
                # Multipolygon pedestrian areas carry relation IDs and may
                # contain repeated poly_hole attributes. Preserve those records
                # intact; only byte-equivalent overlapping surfaces can dedupe.
                if (
                    self.attrs["osm_wayid"] not in ids
                    and self.attrs["osm_relationid"] in ids
                ):
                    (relation,) = struct.unpack("<q", ids[self.attrs["osm_relationid"]])
                    self.db.execute(
                        "INSERT INTO areas VALUES (?,?,?,?,?)",
                        (relation, source, tile, start, record),
                    )
                    self.counts["areas_in"] += 1
                    continue
                attrs = attribute_data(record)
                if self.attrs["osm_wayid"] not in attrs:
                    raise MergeError("Routing item without OSM way ID")
                (way,) = struct.unpack("<q", attrs[self.attrs["osm_wayid"]])
                flags = int.from_bytes(attrs.get(self.attrs["flags"], b"\0"), "little")
                if flags & 4:
                    raise MergeError(f"Way {way}: AF_SEGMENTED encoding is unsupported")
                self.db.execute(
                    "INSERT INTO roads VALUES (?,?,?,?,?)",
                    (way, source, tile, start, record),
                )
                self.counts["roads_in"] += 1
            elif kind in self.restrictions:
                self.db.execute(
                    "INSERT INTO restrictions VALUES (?,?,?,?)",
                    (source, tile, start, record),
                )
                self.counts["restrictions_in"] += 1
            elif kind not in {
                self.items[name]
                for name in ("none", "submap", "countryindex", "map_information")
            }:
                identity = sorted(
                    (atype, data[pos : pos + size])
                    for atype, pos, size in attributes
                    if atype
                    in {
                        self.attrs[name]
                        for name in ("osm_nodeid", "osm_wayid", "osm_relationid")
                    }
                )
                if identity:
                    if any(len(value) != 8 for _, value in identity):
                        raise MergeError("Invalid OSM feature identity")
                    if any(
                        atype == self.attrs["zipfile_ref"] for atype, _, _ in attributes
                    ):
                        raise MergeError("Feature search references require rebuilding")
                    key = b"".join(
                        struct.pack("<I", atype) + value for atype, value in identity
                    )
                    self.db.execute(
                        "INSERT INTO features VALUES (?,?,?,?,?,?)",
                        (key, kind, source, tile, start, record),
                    )
                    self.counts["features_in"] += 1
                else:
                    self.counts["unidentified_features_preserved"] += 1

    @staticmethod
    def pack(point):
        return struct.pack("<ii", *point)

    def endpoint(self, source, start, end, near_start, near_end, count):
        args = (
            source,
            self.pack(start),
            self.pack(end),
            self.pack(near_start),
            self.pack(near_end),
            count,
        )
        old = self.db.execute(
            "SELECT near_start,near_end,segments FROM endpoints WHERE source=? AND start=? AND end=?",
            args[:3],
        ).fetchone()
        if old and old != args[3:]:
            # Parallel paths and closed roads can legitimately share endpoints.
            # This lookup is needed only when rebasing a restriction. Remember
            # ambiguity and reject it if a restriction actually uses this leg.
            self.db.execute(
                "UPDATE endpoints SET segments=0 WHERE source=? AND start=? AND end=?",
                args[:3],
            )
        self.db.execute("INSERT OR IGNORE INTO endpoints VALUES (?,?,?,?,?,?)", args)

    def normalize_way(self, way, rows):
        ignored = {self.attrs["debug"], self.attrs["order"]}
        versions = collections.defaultdict(collections.Counter)
        for source, _, _, data in rows:
            attrs = attribute_data(data)
            identity = item(
                struct.unpack_from("<I", data, 4)[0],
                coordinates(data),
                {k: v for k, v in attrs.items() if k not in ignored},
            )
            versions[source][identity] += 1
        owner = next(iter(versions))
        # Preserve non-overlapping ways byte-for-byte, including roundabouts and
        # legitimate self-intersections. Identical segment multisets also need
        # no reconstruction: retain one source, including its multiplicities.
        if all(version == versions[owner] for version in versions.values()):
            for source, tile, offset, data in rows:
                coords = coordinates(data)
                if len(coords) < 2:
                    raise MergeError(f"Way {way}: fewer than two coordinates")
                self.endpoint(source, coords[0], coords[-1], coords[-1], coords[0], 1)
                self.endpoint(source, coords[-1], coords[0], coords[0], coords[-1], 1)
                for point in coords:
                    self.db.execute(
                        "INSERT OR IGNORE INTO vertices VALUES (?,?,?)",
                        (self.pack(point), way, source),
                    )
                if source == owner:
                    self.counts["roads_out"] += 1
                else:
                    self.db.execute(
                        "INSERT INTO replacements VALUES (?,?,?,?)",
                        (source, tile, offset, tombstone(data)),
                    )
            return
        parsed, cuts, signatures = [], set(), collections.defaultdict(dict)
        for source, tile, offset, data in rows:
            coords = coordinates(data)
            if len(coords) < 2:
                raise MergeError(f"Way {way}: fewer than two coordinates")
            # Closed ways are allowed. Repeated interior coordinates are
            # ambiguous without the original OSM node IDs.
            core = coords[:-1] if coords[0] == coords[-1] else coords
            if len(set(core)) != len(core):
                raise MergeError(
                    f"Way {way}: repeated coordinates need original node identities"
                )
            kind = struct.unpack_from("<I", data, 4)[0]
            attrs = attribute_data(data)
            signature = tuple(
                sorted(
                    (key, value) for key, value in attrs.items() if key not in ignored
                )
            )
            for left, right in zip(coords, coords[1:]):
                key = (kind, left, right)
                old = signatures[source].get(key)
                if old is not None and old != signature:
                    raise MergeError(
                        f"Way {way}: conflicting attributes on the same directed edge"
                    )
                signatures[source][key] = signature
            cuts.update((coords[0], coords[-1]))
            parsed.append((source, tile, offset, data, coords, kind, attrs))
        # Complete-way extracts can differ in segmentation but not in their
        # underlying directed edges. Reject stale, reversed or clipped variants.
        first = next(iter(signatures.values()))
        if any(signature != first for signature in signatures.values()):
            raise MergeError(
                f"Way {way}: geometry/type/attributes differ between inputs; rebuild from one snapshot"
            )
        emitted = set()
        for source, tile, offset, data, coords, kind, attrs in parsed:
            positions = (
                [0]
                + [i for i in range(1, len(coords) - 1) if coords[i] in cuts]
                + [len(coords) - 1]
            )
            parts = [coords[a : b + 1] for a, b in zip(positions, positions[1:])]
            self.endpoint(
                source, coords[0], coords[-1], parts[0][-1], parts[-1][0], len(parts)
            )
            self.endpoint(
                source, coords[-1], coords[0], parts[-1][0], parts[0][-1], len(parts)
            )
            self.db.execute(
                "INSERT INTO replacements VALUES (?,?,?,?)",
                (source, tile, offset, tombstone(data)),
            )
            for part in parts:
                signature = (
                    kind,
                    part,
                    tuple(
                        sorted(
                            (key, value)
                            for key, value in attrs.items()
                            if key not in ignored
                        )
                    ),
                )
                if signature in emitted:
                    continue
                emitted.add(signature)
                self.db.execute(
                    "INSERT INTO tails VALUES (?,?,?)",
                    (source, tile, item(kind, part, attrs)),
                )
                self.counts["roads_out"] += 1
            for point in coords:
                self.db.execute(
                    "INSERT OR IGNORE INTO vertices VALUES (?,?,?)",
                    (self.pack(point), way, source),
                )

    def resolve_leg(self, source, start, end):
        leg = self.db.execute(
            "SELECT near_start,near_end,segments FROM endpoints WHERE source=? AND start=? AND end=?",
            (source, self.pack(start), self.pack(end)),
        ).fetchone()
        if leg is None or leg[2] == 0:
            raise MergeError("Restriction leg has no unambiguous source road")
        return struct.unpack("<ii", leg[0]), struct.unpack("<ii", leg[1]), leg[2]

    def normalize(self):
        self.db.executescript(
            "CREATE INDEX roads_way ON roads(way,source,tile,offset);"
        )
        for (way,) in self.db.execute("SELECT DISTINCT way FROM roads ORDER BY way"):
            rows = self.db.execute(
                "SELECT source,tile,offset,data FROM roads WHERE way=? ORDER BY source,tile,offset",
                (way,),
            ).fetchall()
            self.normalize_way(way, rows)
        self.db.execute(
            "CREATE INDEX features_identity ON features(identity,kind,source,tile,offset)"
        )
        ignored = {self.attrs["order"], self.attrs["debug"]}
        for identity, kind in self.db.execute(
            "SELECT DISTINCT identity,kind FROM features ORDER BY identity,kind"
        ):
            rows = self.db.execute(
                "SELECT source,tile,offset,data FROM features WHERE identity=? AND kind=? ORDER BY source,tile,offset",
                (identity, kind),
            ).fetchall()
            versions = collections.defaultdict(collections.Counter)
            for source, _, _, data in rows:
                versions[source][record_identity(data, ignored)] += 1
            owner = next(iter(versions))
            if any(version != versions[owner] for version in versions.values()):
                raise MergeError(
                    "Overlapping feature geometry/attributes differ; rebuild complete features from one snapshot"
                )
            for source, tile, offset, data in rows:
                if source == owner:
                    self.counts["features_out"] += 1
                else:
                    self.db.execute(
                        "INSERT INTO replacements VALUES (?,?,?,?)",
                        (source, tile, offset, tombstone(data)),
                    )
        self.db.execute("CREATE INDEX areas_relation ON areas(relation)")
        for (relation,) in self.db.execute(
            "SELECT DISTINCT relation FROM areas ORDER BY relation"
        ):
            rows = self.db.execute(
                "SELECT source,tile,offset,data FROM areas WHERE relation=? ORDER BY source,tile,offset",
                (relation,),
            ).fetchall()
            versions = collections.defaultdict(set)
            for source, _, _, data in rows:
                versions[source].add(data)
            first = next(iter(versions.values()))
            if any(version != first for version in versions.values()):
                raise MergeError(
                    f"Relation {relation}: overlapping routing areas differ; rebuild from one snapshot"
                )
            seen = set()
            for source, tile, offset, data in rows:
                if data in seen:
                    self.db.execute(
                        "INSERT INTO replacements VALUES (?,?,?,?)",
                        (source, tile, offset, tombstone(data)),
                    )
                else:
                    seen.add(data)
                    self.counts["areas_out"] += 1
        # Require a source witnessing all ways at a coincident vertex. Otherwise
        # a genuine shared node and two distinct nodes which round to the same
        # coordinate cannot be distinguished in legacy binfiles.
        ambiguous = self.db.execute("""
            WITH totals AS (SELECT point,COUNT(DISTINCT way) AS ways FROM vertices GROUP BY point),
            witnessed AS (SELECT point,source,COUNT(*) AS ways FROM vertices GROUP BY point,source)
            SELECT hex(t.point) FROM totals t JOIN witnessed w ON t.point=w.point
            GROUP BY t.point,t.ways HAVING t.ways>1 AND MAX(w.ways)<t.ways LIMIT 1
        """).fetchone()
        if ambiguous:
            raise MergeError(
                "Shared coordinate lacks a source witnessing the junction; original OSM node IDs are required"
            )
        for source, tile, offset, data in self.db.execute(
            "SELECT * FROM restrictions ORDER BY source,tile,offset"
        ):
            coords = list(coordinates(data))
            if len(coords) not in (3, 4):
                raise MergeError("Unsupported turn restriction geometry")
            _, coords[0], _ = self.resolve_leg(source, coords[0], coords[1])
            coords[-1], _, _ = self.resolve_leg(source, coords[-2], coords[-1])
            if len(coords) == 4:
                if self.resolve_leg(source, coords[1], coords[2])[2] != 1:
                    raise MergeError(
                        "Via-way restriction needs more than four coordinates after splitting"
                    )
            kind = struct.unpack_from("<I", data, 4)[0]
            attrs = attribute_data(data)
            normalized = item(kind, coords, attrs)
            identity = item(
                kind,
                coords,
                {k: v for k, v in attrs.items() if k != self.attrs["order"]},
            )
            self.db.execute(
                "INSERT INTO replacements VALUES (?,?,?,?)",
                (source, tile, offset, tombstone(data)),
            )
            if self.db.execute(
                "INSERT OR IGNORE INTO seen_restrictions VALUES (?)", (identity,)
            ).rowcount:
                self.db.execute(
                    "INSERT INTO tails VALUES (?,?,?)", (source, tile, normalized)
                )
                self.counts["restrictions_out"] += 1
        self.db.executescript("CREATE INDEX tails_tile ON tails(source,tile);")
        self.db.commit()

    def rewrite(self, source, tile, data):
        data = bytearray(data)
        for offset, replacement in self.db.execute(
            "SELECT offset,data FROM replacements WHERE source=? AND tile=?",
            (source, tile),
        ):
            data[offset : offset + len(replacement)] = replacement
        for (tail,) in self.db.execute(
            "SELECT data FROM tails WHERE source=? AND tile=? ORDER BY rowid",
            (source, tile),
        ):
            data.extend(tail)
        return data

    def close(self):
        self.db.close()

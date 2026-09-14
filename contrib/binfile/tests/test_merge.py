import collections
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from binfile import NavitZip, definitions, records
from merge import SOURCE, merge
from overlap import MergeError, attribute_data, coordinates, item

A, I = definitions(SOURCE / "attr_def.h", "ATTR"), definitions(
    SOURCE / "item_def.h", "ITEM"
)
POINTS = {
    1: (1000, 1000),
    2: (2000, 1000),
    3: (3000, 1000),
    4: (2000, 2000),
    5: (4000, 1000),
}


def road(way, nodes, **tags):
    attrs = {A["osm_wayid"]: struct.pack("<Q", way), A["street_name"]: b"Road\0\0\0\0"}
    attrs.update({A[k]: struct.pack("<Q", value) for k, value in tags.items()})
    return item(I["street_1_city"], [POINTS[n] for n in nodes], attrs)


def restriction(nodes, only=False):
    return item(
        I["street_turn_restriction_only" if only else "street_turn_restriction_no"],
        [POINTS[n] for n in nodes],
        {A["order"]: struct.pack("<I", 14 << 16)},
    )


def routing(path):
    result = collections.Counter()
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            data = archive.read(member)
            for start, end, kind, _ in records(data):
                if kind == I["street_1_city"] or kind in [
                    I["street_turn_restriction_no"],
                    I["street_turn_restriction_only"],
                ]:
                    record = data[start:end]
                    attrs = attribute_data(record)
                    attrs.pop(A["order"], None)
                    attrs.pop(A["debug"], None)
                    result[
                        (kind, coordinates(record), tuple(sorted(attrs.items())))
                    ] += 1
    return result


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def bin(self, name, entries):
        path = self.root / (name + ".bin")
        with path.open("wb") as output:
            writer = NavitZip(output)
            metadata = item(
                I["map_information"], [], {A["version"]: struct.pack("<I", 1)}
            )
            writer.add("index", metadata + b"".join(entries))
            writer.finish()
        return path

    def assert_merge(self, west, east, expected):
        left, right, reference = (
            self.bin("west", west),
            self.bin("east", east),
            self.bin("reference", expected),
        )
        output = self.root / "merged.bin"
        report = merge([left, right], output)
        self.assertEqual(routing(reference), routing(output))
        other = self.root / "reordered.bin"
        merge([right, left], other)
        self.assertEqual(output.read_bytes(), other.read_bytes())
        with zipfile.ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
        return report

    def test_unsplit_overlap_matches_single_source(self):
        self.assert_merge(
            [road(10, [1, 2, 3])],
            [road(10, [1, 2]), road(10, [2, 3]), road(20, [2, 4])],
            [road(10, [1, 2]), road(10, [2, 3]), road(20, [2, 4])],
        )

    def test_oneway_and_speed_are_preserved(self):
        self.assert_merge(
            [road(10, [1, 2, 3], flags=1, maxspeed=30)],
            [
                road(10, [1, 2], flags=1, maxspeed=30),
                road(10, [2, 3], flags=1, maxspeed=30),
            ],
            [
                road(10, [1, 2], flags=1, maxspeed=30),
                road(10, [2, 3], flags=1, maxspeed=30),
            ],
        )

    def test_restriction_from_endpoint_is_rebased(self):
        self.assert_merge(
            [road(10, [1, 2, 3]), road(20, [3, 5]), restriction([1, 3, 5])],
            [
                road(10, [1, 2]),
                road(10, [2, 3]),
                road(20, [3, 5]),
                road(30, [2, 4]),
                restriction([2, 3, 5]),
            ],
            [
                road(10, [1, 2]),
                road(10, [2, 3]),
                road(20, [3, 5]),
                road(30, [2, 4]),
                restriction([2, 3, 5]),
            ],
        )

    def test_only_restriction_to_endpoint_is_rebased(self):
        self.assert_merge(
            [road(10, [1, 2, 3]), road(20, [3, 5]), restriction([5, 3, 1], only=True)],
            [
                road(10, [1, 2]),
                road(10, [2, 3]),
                road(20, [3, 5]),
                restriction([5, 3, 2], only=True),
            ],
            [
                road(10, [1, 2]),
                road(10, [2, 3]),
                road(20, [3, 5]),
                restriction([5, 3, 2], only=True),
            ],
        )

    def test_repeated_file_is_idempotent(self):
        path = self.bin("one", [road(10, [1, 2, 3])])
        output = self.root / "out.bin"
        merge([path, path], output)
        self.assertEqual(routing(path), routing(output))

    def test_attribute_and_geometry_conflicts_leave_no_output(self):
        for replacement in [
            road(10, [1, 2, 3], maxspeed=10),
            road(10, [3, 2, 1]),
            road(10, [1, 2, 5]),
        ]:
            with self.subTest(replacement=replacement):
                left = self.bin("left", [road(10, [1, 2, 3])])
                right = self.bin("right", [replacement])
                output = self.root / "out.bin"
                with self.assertRaises(MergeError):
                    merge([left, right], output)
                self.assertFalse(output.exists())

    def test_unproven_shared_interior_vertex_is_rejected(self):
        left = self.bin("left", [road(10, [1, 2, 3])])
        right = self.bin("right", [road(20, [2, 4])])
        with self.assertRaisesRegex(MergeError, "original OSM node IDs"):
            merge([left, right], self.root / "out.bin")

    def test_geometric_crossing_does_not_create_junction(self):
        # Lines cross between vertices. No original topology supports a junction.
        attrs = {A["osm_wayid"]: struct.pack("<Q", 20)}
        bridge = item(I["street_1_city"], [(2000, 500), (2000, 1500)], attrs)
        self.assert_merge([road(10, [1, 3])], [bridge], [road(10, [1, 3]), bridge])

    def test_existing_output_is_not_overwritten(self):
        path = self.bin("one", [road(10, [1, 2])])
        before = path.read_bytes()
        with self.assertRaises(FileExistsError):
            merge([path], path)
        self.assertEqual(before, path.read_bytes())

    def test_single_source_loop_is_preserved(self):
        path = self.bin("loop", [road(10, [1, 2, 4, 1])])
        output = self.root / "out.bin"
        merge([path], output)
        self.assertEqual(routing(path), routing(output))

    def test_unwitnessed_endpoint_connection_is_rejected(self):
        left = self.bin("left", [road(10, [1, 2])])
        right = self.bin("right", [road(20, [2, 4])])
        with self.assertRaisesRegex(MergeError, "original OSM node IDs"):
            merge([left, right], self.root / "out.bin")

    def test_split_via_way_restriction_is_refused(self):
        common = [road(20, [3, 5]), road(30, [4, 1])]
        left = self.bin(
            "left", common + [road(10, [1, 2, 3]), restriction([4, 1, 3, 5])]
        )
        right = self.bin("right", common + [road(10, [1, 2]), road(10, [2, 3])])
        with self.assertRaisesRegex(MergeError, "Via-way restriction"):
            merge([left, right], self.root / "out.bin")
        self.assertFalse((self.root / "out.bin").exists())

    def test_advanced_references_are_refused(self):
        for name, payload in [
            ("item_id", struct.pack("<II", 0, 0)),
            ("zipfile_ref_block", struct.pack("<III", 0, 0, 1)),
        ]:
            path = self.bin(
                "input", [item(I["point_unkn"], [POINTS[1]], {A[name]: payload})]
            )
            with self.subTest(name=name), self.assertRaises(MergeError):
                merge([path], self.root / "out.bin")
            self.assertFalse((self.root / "out.bin").exists())

    def test_invalid_tile_reference_leaves_no_output(self):
        path = self.bin(
            "bad",
            [item(I["countryindex"], [], {A["zipfile_ref"]: struct.pack("<I", 9)})],
        )
        with self.assertRaisesRegex(ValueError, "Reference outside"):
            merge([path], self.root / "out.bin")
        self.assertFalse((self.root / "out.bin").exists())

    def test_duplicate_routing_area_preserves_multiple_holes(self):
        area = item(
            I["street_pedestrian"],
            [POINTS[n] for n in [1, 2, 4, 1]],
            {A["osm_relationid"]: struct.pack("<Q", 100)},
        )
        for point in [(1500, 1200), (1700, 1300)]:
            hole = struct.pack("<Iii", 1, *point)
            area += struct.pack("<II", 4, A["poly_hole"]) + hole
        area = struct.pack("<I", len(area) // 4 - 1) + area[4:]
        left = self.bin("left", [area])
        right = self.bin("right", [area, item(I["point_unkn"], [POINTS[5]], {})])
        output = self.root / "out.bin"
        report = merge([left, right], output)
        self.assertEqual(report["counts"]["areas_in"], 2)
        self.assertEqual(report["counts"]["areas_out"], 1)
        found = []
        with zipfile.ZipFile(output) as archive:
            for member in archive.infolist():
                data = archive.read(member)
                found.extend(
                    data[start:end]
                    for start, end, kind, _ in records(data)
                    if kind == I["street_pedestrian"]
                )
        self.assertEqual(found, [area])


@unittest.skipUnless(
    os.environ.get("NAVIT_BUILD"),
    "Set NAVIT_BUILD to run maptool and native routing comparisons",
)
class NativeTests(unittest.TestCase):
    setUp = MergeTests.setUp
    tearDown = MergeTests.tearDown

    @classmethod
    def setUpClass(cls):
        cls.build = Path(os.environ["NAVIT_BUILD"]).resolve()
        cls.tool = cls.build / "navit/maptool/maptool"
        cls.plugin = cls.build / "navit/map/binfile/libmap_binfile.so"
        cls.compiler_tmp = tempfile.TemporaryDirectory()
        cls.reader = Path(cls.compiler_tmp.name) / "native-route"
        subprocess.run(
            [
                "gcc",
                "-I" + str(cls.build),
                "-I" + str(SOURCE),
                *subprocess.check_output(
                    ["pkg-config", "--cflags", "glib-2.0"], text=True
                ).split(),
                str(Path(__file__).with_name("native_route.c")),
                "-L" + str(cls.build / "navit"),
                "-lnavit_core",
                "-Wl,-rpath," + str(cls.build / "navit"),
                "-o",
                str(cls.reader),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.compiler_tmp.cleanup()

    def osm(self, name, ways, restrictions=()):
        directory = self.root / name
        directory.mkdir()
        osm = ET.Element("osm", version="0.6")
        points = {
            1: (7.410, 43.730),
            2: (7.415, 43.730),
            3: (7.420, 43.730),
            4: (7.415, 43.740),
            5: (7.430, 43.730),
        }
        for number, (lon, lat) in points.items():
            ET.SubElement(osm, "node", id=str(number), lat=str(lat), lon=str(lon))
        for number, nodes, tags in ways:
            way = ET.SubElement(osm, "way", id=str(number))
            for node in nodes:
                ET.SubElement(way, "nd", ref=str(node))
            for key, value in {
                "highway": "residential",
                "name": f"Road {number}",
                **tags,
            }.items():
                ET.SubElement(way, "tag", k=key, v=value)
        for number, kind, fromway, via, toway in restrictions:
            relation = ET.SubElement(osm, "relation", id=str(number))
            for typ, ref, role in [
                ("way", fromway, "from"),
                ("node", via, "via"),
                ("way", toway, "to"),
            ]:
                ET.SubElement(relation, "member", type=typ, ref=str(ref), role=role)
            ET.SubElement(relation, "tag", k="type", v="restriction")
            ET.SubElement(relation, "tag", k="restriction", v=kind)
        tree = ET.ElementTree(osm)
        ET.indent(tree)
        tree.write(directory / "input.osm", encoding="utf-8", xml_declaration=True)
        result = subprocess.run(
            [str(self.tool), "-t", "2026-09-14T00:00:00", "-i", "input.osm", "map.bin"],
            cwd=directory,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return directory / "map.bin"

    def route(self, path, start, end):
        result = subprocess.run(
            [
                str(self.reader),
                str(self.plugin),
                str(path),
                *map(str, start),
                *map(str, end),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_real_maptool_and_native_routes(self):
        through = (10, [1, 2, 3], {})
        branch = (20, [2, 4], {})
        west = self.osm("west", [through])
        east = self.osm("east", [through, branch])
        output = self.root / "merged.bin"
        merge([west, east], output)
        self.assertEqual(routing(east), routing(output))
        for start, end in [
            ((7.411, 43.730), (7.415, 43.738)),
            ((7.415, 43.738), (7.419, 43.730)),
        ]:
            reference = self.route(east, start, end)
            self.assertEqual(reference["found"], 1, reference)
            self.assertEqual(reference, self.route(output, start, end))

    def test_real_restriction_rebase_and_native_route(self):
        roads = [(10, [1, 2, 3], {}), (20, [3, 5], {})]
        branch = (30, [2, 4], {})
        restrictions = [(100, "no_straight_on", 10, 3, 20)]
        west = self.osm("west", roads, restrictions)
        east = self.osm("east", roads + [branch], restrictions)
        output = self.root / "merged.bin"
        merge([west, east], output)
        self.assertEqual(routing(east), routing(output))
        start, end = (7.416, 43.730), (7.429, 43.730)
        reference = self.route(east, start, end)
        self.assertEqual(reference, self.route(output, start, end))
        control = self.osm("unrestricted", roads + [branch])
        permitted = self.route(control, start, end)
        self.assertEqual(permitted["found"], 1, permitted)
        self.assertTrue(
            not reference["found"] or reference["length"] > permitted["length"],
            (reference, permitted),
        )

    def test_real_oneway_routes_in_both_directions(self):
        roads = [(10, [1, 2, 3], {"oneway": "yes"})]
        branch = (20, [2, 4], {})
        west = self.osm("west", roads)
        east = self.osm("east", roads + [branch])
        output = self.root / "merged.bin"
        merge([west, east], output)
        forward = ((7.411, 43.730), (7.415, 43.738))
        backward = tuple(reversed(forward))
        for start, end in [forward, backward]:
            self.assertEqual(
                self.route(east, start, end), self.route(output, start, end)
            )
        self.assertEqual(self.route(output, *forward)["found"], 1)
        self.assertEqual(self.route(output, *backward)["found"], 0)


if __name__ == "__main__":
    unittest.main()

# Merge regional OSM binfiles

`merge.py` reconciles compatible copies of OSM roads before assembling one
Navit-readable binfile. It requires Python 3.11 or later and uses only the standard
library. The output format works with an unmodified Navit reader. Complete address
search validation also needs the reader fixes on this branch, described below.

```sh
python3 contrib/binfile/merge.py -o combined.bin region-a.bin region-b.bin
```

The merger fixes the case where a through road is unsplit in one extract and
split at a side-road junction in another. Both inputs must describe the same
directed geometry and routing attributes for that OSM way. The output contains
one copy of each segment, split at the union of the known junctions. One-way,
access, speed and other attributes are retained. Three-coordinate turn
restrictions are rebased to the new adjacent segments, then deduplicated.
Four-coordinate restrictions are accepted only when the via segment remains
unsplit.

Input order does not change the output. Source SHA-256 hashes determine ownership
of duplicates. Identical input files are consumed once. The command prints a JSON
report with hashes and routing counts. `--scratch DIRECTORY` selects the location
of the temporary SQLite database; the road and vertex indexes are kept on disk,
with one OSM way processed in memory at a time.

## What can be merged safely

The tool accepts differences in compiled intersection splits, but refuses
different road geometry, direction, item types or attributes for the same OSM
way across inputs. Use extracts from a consistent source snapshot and the same
maptool build. A matching date in filenames alone is not sufficient evidence of
consistency.

Legacy binfiles retain way IDs but not the original node ID at every coordinate.
For a coordinate shared by multiple ways, the tool requires at least one source
containing all those ways at that coordinate. It never creates a junction merely
because lines cross. Unwitnessed coincident vertices are refused: distinguishing
a true shared node from separate nodes which project to the same coordinate
requires rebuilding with original OSM data. This conservative rule can reject
otherwise valid input sets.

Non-overlapping ways are preserved byte-for-byte. Identical segment multisets
across sources are deduplicated without reconstruction, including loops and
self-intersections. Repeated interior coordinates are still refused when splits
differ and reconstruction would be ambiguous. Parallel roads sharing endpoints
are allowed; restrictions using an ambiguous endpoint lookup are refused.
Partially clipped geometry or conflicting versions are refused. Relation-based routing surfaces, such as
pedestrian multipolygons with holes, are preserved intact and only deduplicated
when their complete sets of records are identical.

POIs, buildings, other non-routing ways, town/search records and boundary polygons
are deduplicated by retained OSM identity and item type. Complete record multisets
must agree across sources, ignoring only debug/order attributes; repeated polygon
holes and within-source multiplicities are preserved. Distinct OSM entities at
the same coordinate remain distinct. Inconsistent or partially clipped copies
are rejected. Anonymous legacy features are retained and counted in the report;
their identities cannot safely be inferred. Arbitrary polygon/coastline repair
is not implemented.

Maptool on this branch retains town node IDs in search records and copies boundary
relation IDs from the typed attribute instead of looking for an OSM tag named
`osm_relationid`. Rebuild inputs with this maptool to retain those identities.

Contraction-hierarchy maps, AF_SEGMENTED roads, and maps using `item_id` or
`zipfile_ref_block` indexes are refused. These require rebuilding indexes or
additional topology handling. A refused merge does not create the requested
output; existing outputs are never overwritten.

This is not a complete planet rebuild: it cannot recover missing regions or
relations, and planet-scale resource use has not been validated. ZIP64 member and
directory offsets beyond 4 GiB are tested with a sparse file, which does not test
planet-sized topology or payload volume. Navit's current route engine explicitly
ignores four-coordinate via-way restrictions; preserving their records does not
establish that they are enforced. Do not publish output as a complete, fully
validated planet on the strength of the small-fixture tests.

## File layout

Original member numbering is relocated and each input root remains reachable
through a new global root. Country indexes are also exposed from that global
root so town search can traverse them. Central-directory entries have the fixed
stride and offset-only ZIP64 extra fields expected by Navit.

`NavitZip` also accepts forward-only output sinks, including sinks which return
short writes. Its `add_precompressed` API copies a final tile payload in at most
1 MiB reads and checks its SHA-256 against a trusted tile catalog. The catalog
must already contain final member references, compression method, CRC and sizes;
this copying stage does not decode or validate tile contents. The central
directory is spooled to a temporary disk file. Abort/discard the output on any
failure. This is a primitive for streaming planet assembly; the existing merge
CLI still needs local inputs, a topology database and a staged local output.

Replaced routing records become same-length `type_none` records, preserving other
item offsets. Canonical segments are appended to a source tile that previously
contained the enclosing segment; they therefore remain reachable through its
existing spatial hierarchy. The unused records compress well. This preserves
the source hierarchy but does not optimize its size or zoom-level performance.

## Tests

```sh
python3 -m unittest discover -s contrib/binfile/tests -v
cmake -S . -B build-merge -G Ninja -DSAMPLE_MAP=OFF -DDISABLE_QT=ON -DDISABLE_CXX=ON
cmake --build build-merge --target maptool map_binfile -j 4
NAVIT_BUILD="$PWD/build-merge" python3 -m unittest discover -s contrib/binfile/tests -v
```

The native tests compile fixtures from OSM XML, merge their regional binfiles,
and compare routing items and actual Navit route results against a single
conversion of the combined input. Cases cover intersection splits, one-way
travel in both directions, and rebasing a prohibited turn. The suite also checks
order independence, conflict rejection, coincident-node ambiguity and atomic
output behavior. Native tests are explicitly skipped without `NAVIT_BUILD`;
the dedicated CI workflow sets it.

As an additional smoke test, the 2026-09-14 Monaco, Liechtenstein and Andorra
release maps retained all 63,306 street items counted by `item_is_street`, all
269 turn restrictions, all 1,333,105 coordinates, and town-search counts of
10, 93 and 158 respectively. Those regions do not exercise adjoining borders.

## Reproducible real adjoining-chunk proof

```sh
python3 contrib/binfile/validate_chunks.py --build build-merge --output acceptance --large-offsets
```

This offline test builds the checked-in Monaco OSM snapshot once as a reference
and twice with overlapping west/east way sets. Their union covers all 6,248 ways:
1,426 shared, 2,959 west-only and 1,863 east-only. Both chunks receive all snapshot
nodes/relations and available relation-member ways as context. This is deliberately
a small correctness fixture, not the bounded planet dependency planner.

The assembled `combined.bin` matches all 13,951 compiled feature records including
attributes and polygon holes, ignoring only layout metadata, inactive placeholders
and debug/order attributes. Native traversal matches 13,928 reachable feature
records. Native country searches (France and Monaco) yield the same 10 towns,
2,748 street results and 3,962 house results. Street/house totals include repeated
queries under different towns; they are not counts of unique real-world addresses.
Six cross-boundary car routes have identical full coordinate sequences and lengths
to the reference. The ZIP64 variant repeats these checks with every referenced
member beyond 4 GiB, allocating only about 385 KiB locally.

The address tests exposed two existing binfile-reader bugs, fixed on this branch:
house searches could compare an absent parent street name (or an uninitialized
indexed street attribute), and a boundary check exhausted the coordinate cursor
before address deduplication, making distinct address positions collapse to the
same key. The unmodified reader was separately checked for feature traversal,
town/street search and the six routes at normal and large offsets; full house
searches require the fixes.

The command retains the inputs, reference, combined map, logs and `validation.json`.
Its report records artifact hashes and per-maptool RSS/runtime measurements.
These measurements exclude the Python coordinator and do not establish the
whole-job planet budget. `certifies_planet` is explicitly false and remaining
gaps are listed. CI runs this proof on standard Actions runners and uploads the
small maps/report; the sparse 4 GiB test file is intentionally excluded.

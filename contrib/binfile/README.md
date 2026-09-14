# Merge regional OSM binfiles

`merge.py` reconciles compatible copies of OSM roads before assembling one
Navit-readable binfile. It requires Python 3.11 or later, uses only the standard
library, and works with an unmodified Navit reader.

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

Non-overlapping ways are preserved byte-for-byte. Overlapping ways with repeated
interior coordinates, ambiguous endpoint paths, partially clipped geometry or
conflicting versions are refused. Relation-based routing surfaces, such as
pedestrian multipolygons with holes, are preserved intact and only deduplicated
when their complete sets of records are identical. Arbitrary polygon/coastline
stitching and non-routing feature deduplication are not implemented.

Contraction-hierarchy maps, AF_SEGMENTED roads, and maps using `item_id` or
`zipfile_ref_block` indexes are refused. These require rebuilding indexes or
additional topology handling. A refused merge does not create the requested
output; existing outputs are never overwritten.

This is not a complete planet rebuild: it cannot recover missing regions or
relations, and planet-scale resource use and offsets beyond 4 GiB have not been
validated. Do not publish output as a complete planet without coverage and
source-provenance checks.

## File layout

Original member numbering is relocated and each input root remains reachable
through a new global root. Country indexes are also exposed from that global
root so town search can traverse them. Central-directory entries have the fixed
stride and offset-only ZIP64 extra fields expected by Navit.

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

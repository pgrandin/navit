# Monaco OSM fixture

`monaco-260913.osm.gz` is the Monaco extract from
https://download.geofabrik.de/europe/monaco-260913.osm.pbf, downloaded 2026-09-14,
with its OSM objects converted to XML using pyosmium 4.3.1, then gzip-compressed with a
zero timestamp. It is kept here so correctness tests do not depend on a changing
download, an unavailable historical daily extract, or a PBF conversion package.

Original PBF SHA-256:
`5522a7e2ac8084d935302d78e2ec9bbec8ec5eba8740ea29050e1e02bcdaa9c6`.
Compressed XML SHA-256:
`7813ac2ea38efefbcc52bd788a32f741dc641f9585f303896d1b118da18216c2`.

Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
available under the [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
Extract provided by [Geofabrik](https://download.geofabrik.de/europe/monaco.html).
This data fixture retains its ODbL license, independently of Navit's code license.

This regional snapshot is not complete planet data. The test supplies all its
nodes and relations as shared context and partitions its ways across overlapping
west/east regions. This intentionally isolates conversion/stitching correctness
from the still-unimplemented planet dependency planner.

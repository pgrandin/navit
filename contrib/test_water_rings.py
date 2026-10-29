"""Exercise real maptool assembly and slicing, with water AND dry controls.

Usage: python test_water_rings.py SOURCE MAPTOOL OUTPUT_DIRECTORY
No source-data edits, graphics, third-party Python packages or copied C logic.
"""
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
from test_inland_water import geo, polygons, is_water

source, binary, output = map(lambda p: Path(p).resolve(), sys.argv[1:4])
output.mkdir(parents=True, exist_ok=False)
results = []
for water_kind, tags, item_type in [('lake', ('natural','water'), 'poly_water'),
                                   ('river', ('waterway','riverbank'), 'poly_water'),
                                   ('reservoir', ('landuse','reservoir'), 'poly_reservoir'),
                                   ('basin', ('landuse','basin'), 'poly_basin')]:
    for reverse in [False, True]:
        for rotate in range(4):
            root = ET.Element('osm', version='0.6')
            nodes, ways, relations = [], [], []
            def ring(coords):
                ids = []
                for x, y in coords:
                    nid = len(nodes) + 1
                    # Stay within the intended projected integer cell on either side of zero.
                    lon, lat = geo(x + (.25 if x >= 0 else -.25), y + (.25 if y >= 0 else -.25))
                    nodes.append((nid, lon, lat)); ids.append(nid)
                ids = ids[rotate:] + ids[:rotate]
                if reverse: ids.reverse()
                return ids + ids[:1]
            def way(refs):
                wid = 1000 + len(ways); ways.append((wid, refs)); return wid
            def relation(members):
                relations.append(members)
            def square(x, y, size):
                return ring([(x,y),(x+size,y),(x+size,y+size),(x,y+size)])
            # Crossing x=0 triggers the tile slicer. The island's first vertex
            # aligns with an outer vertex: the old strict crossing loses the hole.
            outer = ring([(200000,100000),(450000,200000),(200000,300000),(-50000,200000)])
            hole = ring([(200000,180000),(220000,200000),(200000,220000),(180000,200000)])
            relation([(way(outer),'outer'), (way(hole),'inner')])
            # Four nested rings, split at corners and intentionally mixed roles.
            # Geometry determines alternating water/island/lake/island coverage.
            for_nested = []
            for k in range(4):
                ids = square(1000000+k*10000,1000000+k*10000,80000-k*20000)
                for j in range(4):
                    refs = ids[j:j+2]
                    if j%2: refs = list(reversed(refs))
                    for_nested.append((way(refs),'inner' if j%2 else 'outer'))
            # Disjoint outer ring in the same relation must stay water.
            for_nested.append((way(square(1100000,1000000,20000)),'outer'))
            relation(for_nested)
            # Touching rings share OSM nodes. Island A shares an edge with the
            # larger island B and sits inside B's bounding box; island C touches
            # the outer shore at a node; island F touches it mid-edge, without a
            # node; lake E touches its island D at one node.
            shared = {}
            def shared_ring(coords):
                ids = []
                for x, y in coords:
                    if (x, y) not in shared:
                        lon, lat = geo(x + .25, y + .25)
                        nodes.append((len(nodes) + 1, lon, lat)); shared[x, y] = len(nodes)
                    ids.append(shared[x, y])
                ids = ids[rotate:] + ids[:rotate]
                if reverse: ids.reverse()
                return ids + ids[:1]
            relation([(way(shared_ring([(2000000,1000000),(2100000,1000000),(2100000,1080000),(2100000,1100000),(2000000,1100000)])),'outer'),
                      (way(shared_ring([(2040000,1025000),(2050000,1025000),(2050000,1045000),(2040000,1045000)])),'inner'),
                      (way(shared_ring([(2030000,1010000),(2080000,1010000),(2080000,1060000),(2030000,1060000),(2030000,1050000),(2050000,1045000),(2050000,1025000),(2030000,1020000)])),'inner'),
                      (way(shared_ring([(2100000,1080000),(2085000,1075000),(2085000,1090000)])),'inner'),
                      (way(shared_ring([(2020000,1100000),(2010000,1090000),(2030000,1090000)])),'inner'),
                      (way(shared_ring([(2040000,1065000),(2075000,1065000),(2075000,1080000),(2075000,1095000),(2040000,1095000)])),'inner'),
                      (way(shared_ring([(2075000,1080000),(2060000,1072000),(2050000,1080000),(2060000,1088000)])),'outer')])
            for nid, lon, lat in nodes:
                ET.SubElement(root,'node',id=str(nid),version='1',lon=f'{lon:.12f}',lat=f'{lat:.12f}')
            for wid, ids in ways:
                w=ET.SubElement(root,'way',id=str(wid),version='1')
                for nid in ids: ET.SubElement(w,'nd',ref=str(nid))
            for rid, members in enumerate(relations,2000):
                r=ET.SubElement(root,'relation',id=str(rid),version='1')
                for wid, role in members: ET.SubElement(r,'member',type='way',ref=str(wid),role=role)
                for k,v in [('type','multipolygon'),tags]: ET.SubElement(r,'tag',k=k,v=v)
            folder=output/f'{water_kind}-r{rotate}-reverse{int(reverse)}';folder.mkdir()
            ET.indent(root);ET.ElementTree(root).write(folder/'input.osm',encoding='utf-8',xml_declaration=True)
            with (folder/'conversion.log').open('w') as log:
                subprocess.run([str(binary),'-i',str(folder/'input.osm'),str(folder/'map.bin')],cwd=folder,stdout=log,stderr=subprocess.STDOUT,check=True)
            water=polygons(source,folder/'map.bin',item_type)
            checks=[((200000,200000),False),((200000,150000),True),((200000,250000),True),
                    ((200000,50000),False),((1005000,1040000),True),((1015000,1040000),False),
                    ((1025000,1040000),True),((1040000,1040000),False),((1110000,1010000),True),
                    ((1090000,1040000),False),
                    ((2045000,1035000),False),((2065000,1035000),False),((2035000,1035000),True),
                    ((2092000,1082000),False),((2045000,1090000),False),((2060000,1080000),True),
                    ((2090000,1020000),True),((2020000,1095000),False)]
            bad=[dict(point=p,expected=e,actual=is_water(water,p)) for p,e in checks if is_water(water,p)!=e]
            results.append(dict(case=folder.name,checks=len(checks),failures=bad))
(output/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results),flush=True)
assert not any(r['failures'] for r in results), 'Water ring regression; see results.json'

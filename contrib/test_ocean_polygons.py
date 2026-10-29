"""Exercise the prepared-ocean production path, its holes and failure behavior.

Usage: python test_ocean_polygons.py SOURCE MAPTOOL OUTPUT_DIRECTORY
Requires pyshp and Shapely >= 2.0. All artifacts stay in OUTPUT_DIRECTORY.
"""
import importlib.util
import json
import math
import re
import zipfile
from pathlib import Path
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

import shapefile
from shapely.geometry import Polygon, box

def geo(x, y):
    return math.degrees(x / 6371000), math.degrees(2 * math.atan(math.exp(y / 6371000)) - math.pi / 2)


def enum_value(path, macro, name):
    value = -1
    for line in path.read_text().splitlines():
        match = re.fullmatch(rf'{macro}(2)?\((?:([^,]+),\s*)?(\w+)\)', line.strip())
        if match:
            value = int(match[2], 0) if match[1] else value + 1
            if match[3] == name:
                return value
    raise RuntimeError(f'Missing {macro} {name}')


def polygons(source, binfile, item_type='poly_water_tiled'):
    """Decode actual little-endian binfile items, including every hole attribute."""
    water_type = enum_value(source / 'navit/item_def.h', 'ITEM', item_type)
    hole_type = enum_value(source / 'navit/attr_def.h', 'ATTR', 'poly_hole')
    result = []
    with zipfile.ZipFile(binfile) as archive:
        for member in archive.infolist():
            raw = archive.read(member)
            pos = 0
            while pos < len(raw):
                length, kind, clen = struct.unpack_from('<III', raw, pos)
                end = pos + (length + 1) * 4
                if length < 2 or clen % 2 or pos + 12 + clen * 4 > end or end > len(raw):
                    raise RuntimeError(f'Malformed item in {member.filename} at {pos}')
                if kind == water_type:
                    outer = list(struct.iter_unpack('<ii', raw[pos + 12:pos + 12 + clen * 4]))
                    holes = []
                    attr = pos + 12 + clen * 4
                    while attr < end:
                        alen, atype = struct.unpack_from('<II', raw, attr)
                        aend = attr + (alen + 1) * 4
                        if alen < 1 or aend > end:
                            raise RuntimeError('Malformed polygon attribute')
                        if atype == hole_type:
                            count, = struct.unpack_from('<I', raw, attr + 8)
                            if count < 4 or alen != 2 + count * 2:
                                raise RuntimeError('Malformed polygon hole')
                            holes.append(list(struct.iter_unpack('<ii', raw[attr + 12:aend])))
                        attr = aend
                    result.append(dict(outer=outer, holes=holes))
                pos = end
    return result


def inside(ring, point):
    # Independent even/odd ray crossing oracle. Samples avoid polygon edges.
    x, y = point
    result = False
    for (ax, ay), (bx, by) in zip(ring, ring[1:] + ring[:1]):
        if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
            result = not result
    return result


def is_water(items, point):
    return any(inside(p['outer'], point) and not any(inside(h, point) for h in p['holes']) for p in items)



source, binary, output = map(lambda arg: Path(arg).resolve(), sys.argv[1:4])
output.mkdir(parents=True, exist_ok=False)
spec = importlib.util.spec_from_file_location('ocean', source / 'contrib/coastline-polygons.py')
ocean = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ocean)
assert ocean.WATER == enum_value(source / 'navit/item_def.h', 'ITEM', 'poly_water_tiled')
assert ocean.HOLE == enum_value(source / 'navit/attr_def.h', 'ATTR', 'poly_hole')

# A mainland crossing the map boundary and an island fully inside it.
domain = (-10000, -10000, 10000, 10000)
land_file = output / 'land_polygons.shp'
with shapefile.Writer(str(land_file), shapeType=shapefile.POLYGON) as writer:
    writer.field('id', 'N')
    for i, polygon in enumerate([box(-20000, -20000, -3000, 20000), box(1000, 1000, 2000, 2000)]):
        ring = [(x / ocean.SCALE, y / ocean.SCALE) for x, y in reversed(polygon.exterior.coords)]
        writer.poly([ring])
        writer.record(i)
land_file.with_suffix('.prj').write_text('EPSG:3857 Mercator 6378137')
(output / 'README.txt').write_text('Synthetic complete land fixture; not downloaded OSM')
water = output / 'ocean.items'
ocean.prepare(land_file, (*geo(*domain[:2]), *geo(*domain[2:])), water)
# A deliberately incomplete local coastline source: only a small island.
# Prepared coverage must replace it, including mainland absent from this XML.
osm = ET.Element('osm', version='0.6', generator='navit-ocean-regression')
ring = [(1100, 1100), (1900, 1100), (1900, 1900), (1100, 1900)]
for nid, xy in enumerate(ring, 1):
    lon, lat = geo(*xy)
    ET.SubElement(osm, 'node', id=str(nid), version='1', lon=str(lon), lat=str(lat))
coast = ET.SubElement(osm, 'way', id='100001', version='1')
for nid in (1, 2, 3, 4, 1):
    ET.SubElement(coast, 'nd', ref=str(nid))
ET.SubElement(coast, 'tag', k='natural', v='coastline')
# Existing non-ocean features must survive the substitution.
for nid, xy in [(90001, (-7000, 0)), (90002, (-6000, 0))]:
    lon, lat = geo(*xy)
    node = ET.SubElement(osm, 'node', id=str(nid), version='1', lon=str(lon), lat=str(lat))
    if nid == 90001:
        ET.SubElement(node, 'tag', k='place', v='town')
        ET.SubElement(node, 'tag', k='name', v='Ocean regression town')
way = ET.SubElement(osm, 'way', id='90003', version='1')
for nid in (90001, 90002):
    ET.SubElement(way, 'nd', ref=str(nid))
ET.SubElement(way, 'tag', k='highway', v='residential')
ET.SubElement(way, 'tag', k='name', v='Retained street')
osm[:] = sorted(osm, key=lambda element: (element.tag != 'node', int(element.attrib['id'])))
ET.indent(osm)
xml = output / 'input.osm'
xml.write_bytes(ET.tostring(osm, encoding='utf-8', xml_declaration=True))


def run(name, items, success=True, options=()):
    folder = output / name
    folder.mkdir()
    command = [str(binary), *options, '-i', str(xml), '--ocean-polygons', str(items), str(folder / 'map.bin')]
    process = subprocess.run(command, cwd=folder, capture_output=True)
    (folder / 'conversion.log').write_bytes(process.stdout + process.stderr)
    assert (process.returncode == 0) == success, (name, process.returncode)
    return folder / 'map.bin'


map_file = run('complete', water)
decoded = polygons(source, map_file)
assert decoded and all(Polygon(p['outer'], p['holes']).is_valid for p in decoded)
probes = [((-7000, 0), False), ((1500, 1500), False), ((5000, 5000), True),
          ((15000, 5000), False), ((1500, 2500), True)]
for point, expected in probes:
    assert is_water(decoded, point) == expected, point
with zipfile.ZipFile(map_file) as archive:
    raw = b''.join(archive.read(name) for name in archive.namelist())
assert b'Retained street' in raw and b'Ocean regression town' in raw
empty = output / 'empty.items'
empty.write_bytes(b'')
assert polygons(source, run('inland', empty)) == []

# No silent fallback to the legacy flood-fill for absent or damaged coverage.
run('missing', output / 'missing.items', False)
valid = water.read_bytes()
bad_type = bytearray(valid)
struct.pack_into('=I', bad_type, 4, 0)
bad_coords = bytearray(valid)
struct.pack_into('=I', bad_coords, 8, 0xffffffff)
for name, payload in [('partial-length', b'\x01'), ('oversized', struct.pack('=I', 0x7fffffff)),
                      ('truncated', valid[:-1]), ('wrong-type', bad_type), ('bad-coordinates', bad_coords)]:
    file = output / (name + '.items')
    file.write_bytes(payload)
    run(name, file, False)
result = {'passed': True, 'coverage_probes': 5, 'invalid_input_cases': 6,
          'empty_inland_map': True, 'island_holes': True, 'roads_and_towns_retained': True}
(output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))

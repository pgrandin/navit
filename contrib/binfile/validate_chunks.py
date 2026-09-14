#!/usr/bin/env python3
"""Reproducible adjoining-chunk acceptance test, using a small real OSM snapshot.

This is a correctness fixture, not a planet partitioner. All nodes and relations
are deliberately supplied as context to both chunks. Only way sets differ.
"""

import argparse
import collections
import gzip
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

from binfile import NavitZip, definitions, records
from merge import SOURCE, merge
from overlap import record_identity

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "tests/data/monaco-260913.osm.gz"
FIXTURE_SHA256 = "7813ac2ea38efefbcc52bd788a32f741dc641f9585f303896d1b118da18216c2"
TIMESTAMP = "2026-09-13T20:21:20"
TIMED_CHILD = """
import resource, subprocess, sys, time
started = time.monotonic()
result = subprocess.run(sys.argv[1:], timeout=290)
with open('resources.txt', 'w') as output:
    output.write(f'{resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss} {time.monotonic() - started}')
sys.exit(result.returncode)
"""


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def compile_native(build, output, name):
    target = output / name
    subprocess.run(
        [
            "gcc",
            "-I" + str(build),
            "-I" + str(SOURCE),
            *subprocess.check_output(
                ["pkg-config", "--cflags", "glib-2.0"], text=True
            ).split(),
            str(HERE / "tests" / (name + ".c")),
            "-L" + str(build / "navit"),
            "-lnavit_core",
            *subprocess.check_output(
                ["pkg-config", "--libs", "glib-2.0"], text=True
            ).split(),
            "-Wl,-rpath," + str(build / "navit"),
            "-o",
            str(target),
        ],
        check=True,
    )
    return target


def feature_records(path):
    attrs = definitions(SOURCE / "attr_def.h", "ATTR")
    items = definitions(SOURCE / "item_def.h", "ITEM")
    structural = {
        items[k] for k in ("none", "submap", "countryindex", "map_information")
    }
    result = collections.Counter()
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise AssertionError("ZIP CRC validation failed")
        for member in archive.infolist():
            data = archive.read(member)
            for start, end, kind, _ in records(data):
                if kind not in structural:
                    result[
                        record_identity(
                            data[start:end], {attrs["debug"], attrs["order"]}
                        )
                    ] += 1
    return result


def compare(expected, actual, description):
    missing, extra = expected - actual, actual - expected
    if missing or extra:
        raise AssertionError(
            f"{description}: {sum(missing.values())} missing, {sum(extra.values())} extra"
        )


def make_chunks(output, tool):
    if sha256(FIXTURE) != FIXTURE_SHA256:
        raise AssertionError("Fixture checksum mismatch")
    root = ET.fromstring(gzip.decompress(FIXTURE.read_bytes()))
    nodes = {int(obj.attrib["id"]): obj for obj in root.findall("node")}
    ways = {int(obj.attrib["id"]): obj for obj in root.findall("way")}
    relations = root.findall("relation")
    context = {
        int(member.attrib["ref"])
        for relation in relations
        for member in relation.findall("member")
        if member.attrib["type"] == "way" and int(member.attrib["ref"]) in ways
    }
    builds, selected = {}, {}
    for name, side in [("reference", None), ("west", -1), ("east", 1)]:
        chosen = (
            set(ways)
            if side is None
            else {
                wid
                for wid, way in ways.items()
                if any(
                    side * (float(nodes[int(nd.attrib["ref"])].attrib["lon"]) - 7.425)
                    >= -0.001
                    for nd in way.findall("nd")
                    if int(nd.attrib["ref"]) in nodes
                )
            }
            | context
        )
        selected[name] = chosen
        chunk = ET.Element("osm", version="0.6")
        chunk.extend(nodes.values())
        chunk.extend(ways[wid] for wid in sorted(chosen))
        chunk.extend(relations)
        directory = output / name
        directory.mkdir()
        ET.ElementTree(chunk).write(
            directory / "input.osm", encoding="utf-8", xml_declaration=True
        )
        with (directory / "maptool.log").open("w") as log:
            subprocess.run(
                [
                    sys.executable,
                    "-c",
                    TIMED_CHILD,
                    str(tool),
                    "--64bit",
                    "--slice-size",
                    "6442450944",
                    "-t",
                    TIMESTAMP,
                    "-i",
                    "input.osm",
                    "map.bin",
                ],
                cwd=directory,
                stdout=log,
                stderr=log,
                check=True,
                timeout=300,
            )
        rss, elapsed = (directory / "resources.txt").read_text().split()
        builds[name] = {
            "ways": len(chosen),
            "maptool_peak_rss_kib": int(rss),
            "maptool_elapsed_seconds": float(elapsed),
            "input_xml_bytes": (directory / "input.osm").stat().st_size,
            "bin_bytes": (directory / "map.bin").stat().st_size,
            "bin_sha256": sha256(directory / "map.bin"),
        }
    if selected["west"] | selected["east"] != selected["reference"]:
        raise AssertionError("Incomplete way coverage")
    if not (
        selected["west"] - selected["east"] and selected["east"] - selected["west"]
    ):
        raise AssertionError("Fixture must have exclusive ways on both sides")
    builds["coverage"] = {
        "nodes": len(nodes),
        "relations": len(relations),
        "shared_ways": len(selected["west"] & selected["east"]),
        "west_only_ways": len(selected["west"] - selected["east"]),
        "east_only_ways": len(selected["east"] - selected["west"]),
        "context": "All snapshot nodes/relations and available relation-member ways in both chunks",
    }
    return builds


def sparse_offsets(source, output):
    """Move all real members beyond 4 GiB, without allocating/uploading padding.

    Unindexed bytes between ZIP records are ignored by directory-based readers.
    The initial magic identifies this as a ZIP to Navit; all referenced payloads
    and all directory offsets are serialized by the production writer.
    """
    zeros = bytes(1024 * 1024)
    with output.open("xb") as dest:

        class SparseSink:
            def write(self, data):
                if data.obj is zeros:
                    dest.seek(len(data), 1)
                    return len(data)
                return dest.write(data)

        with NavitZip(SparseSink()) as writer, zipfile.ZipFile(source) as archive:
            writer._write(struct.pack("<I", 0x04034B50))
            for _ in range(4096):
                writer._write(zeros)
            for member in archive.infolist():
                writer.add(member.filename, archive.read(member))
            writer.finish()
    if output.stat().st_size <= 2**32:
        raise AssertionError("Large-offset fixture did not cross 4 GiB")


def validate(build, output, large_offsets=False):
    started = time.monotonic()
    output.mkdir(parents=True, exist_ok=False)
    tool, plugin = (
        build / "navit/maptool/maptool",
        build / "navit/map/binfile/libmap_binfile.so",
    )
    inspector = compile_native(build, output, "native_inspect")
    router = compile_native(build, output, "native_route")
    report = {
        "fixture_sha256": FIXTURE_SHA256,
        "maptool_sha256": sha256(tool),
        "binfile_reader_sha256": sha256(plugin),
        "reader_includes_address_search_fixes": True,
    }
    report["builds"] = make_chunks(output, tool)
    reference, combined = output / "reference/map.bin", output / "combined.bin"
    report["merge"] = merge(
        [output / "west/map.bin", output / "east/map.bin"], combined
    )
    expected = feature_records(reference)
    compare(expected, feature_records(combined), "Compiled feature multiset")
    report["compiled_features"] = sum(expected.values())

    def inspect(path):
        result = subprocess.run(
            [str(inspector), str(plugin), str(path), "250", "492"],
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        )
        return collections.Counter(result.stdout.splitlines())

    native = inspect(reference)
    compare(native, inspect(combined), "Native feature traversal and searches")
    # Independent regression assertion: two different OSM nodes carry this
    # address at distinct positions. A boundary test must not erase their
    # coordinates before duplicate detection and arbitrarily hide one of them.
    address = (
        "house 492 "
        + " ".join(
            value.encode().hex()
            for value in ("Monaco", "Boulevard du Jardin Exotique", "45")
        )
        + " "
    )
    positions = {
        tuple(map(int, line[len(address) :].split()))
        for line in native
        if line.startswith(address)
    }
    if positions != {(824647, 5418736), (824648, 5418729)}:
        raise AssertionError(
            "Boundary-filtered address search lost a distinct location"
        )
    counts = collections.Counter()
    for line, count in native.items():
        counts[line.split()[0]] += count
    for key in ("feature", "town", "street", "house"):
        if counts[key] == 0:
            raise AssertionError(f"Fixture did not exercise {key}")
    report["native"] = dict(counts)

    pairs = [
        # Points on named public roads, not arbitrary coordinates which may
        # snap to disconnected/private access roads in the source extract.
        ((7.4220798, 43.7329615), (7.4317338, 43.7475335)),
        ((7.4176878, 43.7321776), (7.4306922, 43.74302)),
        ((7.4201019, 43.7374752), (7.4372737, 43.7491857)),
    ]
    routes = []

    def route(path, start, end):
        result = subprocess.run(
            [str(router), str(plugin), str(path), *map(str, start), *map(str, end)],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return json.loads(result.stdout)

    for a, b in pairs:
        for start, end in [(a, b), (b, a)]:
            expected_route = route(reference, start, end)
            if not expected_route["found"] or not expected_route["coordinates"]:
                raise AssertionError(f"No reference route from {start} to {end}")
            if route(combined, start, end) != expected_route:
                raise AssertionError(f"Route geometry differs from {start} to {end}")
            routes.append(
                {
                    "start": start,
                    "end": end,
                    "length": expected_route["length"],
                    "coordinates": len(expected_route["coordinates"]),
                }
            )
    report["routes"] = routes
    if large_offsets:
        large = output / "large-offsets.bin"
        sparse_offsets(combined, large)
        compare(expected, feature_records(large), "ZIP64 feature multiset")
        compare(native, inspect(large), "Native ZIP64 traversal and searches")
        for a, b in pairs:
            for start, end in [(a, b), (b, a)]:
                if route(large, start, end) != route(combined, start, end):
                    raise AssertionError("Native ZIP64 route differs")
        report["large_offsets"] = {
            "logical_bytes": large.stat().st_size,
            "allocated_bytes": large.stat().st_blocks * 512,
            "all_member_offsets_above_4gib": True,
        }
    report["elapsed_seconds"] = time.monotonic() - started
    report["certifies_planet"] = False
    report["remaining_gaps"] = [
        "Planet coverage and bounded dependency/context planning are not established by this fixture",
        "The current route engine ignores four-coordinate via-way restrictions",
        "Split via-way restrictions and inconsistent/clipped overlapping features are rejected",
        "Legacy binfiles cannot disambiguate all coincident endpoints without original OSM node identities",
    ]
    report["scope"] = (
        "Small adjoining-chunk equivalence; not planet coverage, scaling or all OSM restriction semantics"
    )
    (output / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument(
        "--output", type=Path, required=True, help="A new output directory"
    )
    parser.add_argument(
        "--large-offsets",
        action="store_true",
        help="Also exercise a sparse ZIP64 file beyond 4 GiB",
    )
    args = parser.parse_args()
    print(
        json.dumps(
            validate(args.build.resolve(), args.output.resolve(), args.large_offsets),
            indent=2,
        )
    )


if __name__ == "__main__":
    main()

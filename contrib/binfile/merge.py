#!/usr/bin/env python3
"""Merge compatible OSM binfiles, reconciling routing overlaps conservatively."""

import argparse
import hashlib
import json
import os
import pathlib
import re
import tempfile
import zipfile

from binfile import definitions, write_merged
from overlap import MergeError, Overlap

SOURCE = pathlib.Path(__file__).resolve().parents[2] / "navit"


def merge(inputs, output, source=SOURCE, scratch=None):
    inputs = [pathlib.Path(p).resolve() for p in inputs]
    output = pathlib.Path(output).resolve()
    if not inputs:
        raise MergeError("At least one input is required")
    if output.exists():
        raise FileExistsError(output)
    # Content order makes ownership deterministic even if callers reorder/rename
    # their regional files. Identical input files are consumed just once.
    hashes = {}
    for path in inputs:
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        hashes.setdefault(digest, path)
    inputs = [hashes[key] for key in sorted(hashes)]
    attrs, items = definitions(source / "attr_def.h", "ATTR"), definitions(
        source / "item_def.h", "ITEM"
    )
    flag_table = (
        (source / "item.c")
        .read_text()
        .split("struct default_flags default_flags2[] = {", 1)[1]
        .split("};", 1)[0]
    )
    road_types = {items[name] for name in re.findall(r"\{type_(\w+),", flag_table)}
    with tempfile.TemporaryDirectory(prefix="navit-overlap-", dir=scratch) as work:
        overlap = Overlap(
            pathlib.Path(work) / "overlap.sqlite", attrs, items, road_types
        )
        try:
            for source_number, path in enumerate(inputs):
                with zipfile.ZipFile(path) as archive:
                    for number, member in enumerate(archive.infolist()):
                        overlap.add(source_number, number, archive.read(member))
            overlap.normalize()
            # Same filesystem, then link exclusively: validation or write errors
            # cannot leave a partial file under the requested output name.
            with tempfile.TemporaryDirectory(
                prefix=".navit-merge-", dir=output.parent
            ) as pending:
                staged = pathlib.Path(pending) / "map.bin"
                files = write_merged(inputs, staged, source, overlap)
                with staged.open("rb") as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                os.link(staged, output)
            return {
                "inputs": files,
                "input_sha256": sorted(hashes),
                "output_sha256": digest,
                "counts": dict(overlap.counts),
            }
        finally:
            overlap.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", type=pathlib.Path, required=True)
    parser.add_argument(
        "--scratch",
        type=pathlib.Path,
        help="Directory for the temporary SQLite database",
    )
    parser.add_argument("inputs", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    try:
        report = merge(args.inputs, args.output, scratch=args.scratch)
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Merge refused: {error}\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

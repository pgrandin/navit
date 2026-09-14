#!/usr/bin/env python3
"""Binfile record parsing and Navit-compatible ZIP64 assembly."""

import pathlib
import hashlib
import re
import struct
import tempfile
import zipfile
import zlib


def definitions(path, macro):
    result, value = {}, -1
    for line in path.read_text().splitlines():
        if re.match(r"\s*" + macro + r"_UNUSED\b", line):
            value += 1
        match = re.match(macro + r"(2)?\(([^)]+)\)", line)
        if match:
            if match[1]:
                number, name = match[2].split(",")
                value, name = int(number, 0), name.strip()
            else:
                value, name = value + 1, match[2]
            result[name] = value
    return result


def records(data):
    pos = 0
    while pos < len(data):
        if pos + 12 > len(data):
            raise ValueError("Truncated item header")
        length, kind, coords = struct.unpack_from("<III", data, pos)
        end = pos + 4 * (length + 1)
        attr = pos + 12 + 4 * coords
        if length < 2 or coords % 2 or attr > end or end > len(data):
            raise ValueError("Invalid item length")
        attrs = []
        while attr < end:
            if attr + 8 > end:
                raise ValueError("Truncated attribute")
            size, atype = struct.unpack_from("<II", data, attr)
            next_attr = attr + 4 * (size + 1)
            if size < 1 or next_attr > end:
                raise ValueError("Invalid attribute length")
            attrs.append((atype, attr + 8, (size - 1) * 4))
            attr = next_attr
        yield pos, end, kind, attrs
        pos = end


class NavitZip:
    """Forward-only writer matching maptool's offset-only ZIP64 extra fields.

    Output must start at byte zero. Only write() is required of the sink;
    directory metadata is spooled to disk. A failed write invalidates the output,
    so callers must discard staged files or abort multipart uploads on failure.
    """

    def __init__(self, output):
        self.out = output
        self.directory = tempfile.TemporaryFile()
        self.count = 0
        self.offset = 0
        self.finished = False
        self.pending = False

    def _write(self, data):
        view = memoryview(data)
        while view:
            written = self.out.write(view)
            if not isinstance(written, int) or not 0 < written <= len(view):
                raise OSError(
                    "Output sink made no progress or returned an invalid count"
                )
            self.offset += written
            view = view[written:]

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.directory.close()

    def add(self, name, data):
        if len(data) >= 0xFFFFFFFF:
            raise ValueError("Individual tiles must fit in 32 bits")
        compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
        compressed = compressor.compress(data) + compressor.flush()
        method = 8
        if len(compressed) >= len(data):
            compressed, method = data, 0
        crc = zlib.crc32(data)
        self._header(name, method, crc, len(data), len(compressed))
        self._write(compressed)
        self.pending = False

    def add_precompressed(
        self, name, source, *, method, crc, size, compressed_size, sha256
    ):
        """Copy a cataloged tile in bounded blocks, verifying its payload hash.

        The catalog must come from a trusted conversion/validation stage and
        contain final member references, CRC and uncompressed size. SHA-256 covers
        the compressed payload. This copy stage checks transport integrity; it
        does not decompress the tile or validate its Navit records.
        """
        if not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise ValueError("Expected a lowercase SHA-256 payload digest")
        self._header(name, method, crc, size, compressed_size)
        remaining, digest = compressed_size, hashlib.sha256()
        while remaining:
            block = source.read(min(remaining, 1024 * 1024))
            if not block or len(block) > remaining:
                raise ValueError("Invalid compressed tile payload length")
            remaining -= len(block)
            digest.update(block)
            self._write(block)
        if digest.hexdigest() != sha256:
            raise ValueError("Compressed tile payload checksum mismatch")
        self.pending = False

    def _header(self, name, method, crc, size, compressed_size):
        if self.finished:
            raise ValueError("Archive is already finished")
        if self.pending:
            raise ValueError("Previous member did not complete; discard this archive")
        name = name.encode("ascii")
        if not 1 <= len(name) <= 65535:
            raise ValueError("Invalid member name length")
        if method not in (0, 8) or not 0 <= crc <= 0xFFFFFFFF:
            raise ValueError("Invalid compression method or CRC")
        if not (0 <= size < 0xFFFFFFFF and 0 <= compressed_size < 0xFFFFFFFF):
            raise ValueError("Individual tiles must fit in 32 bits")
        if method == 0 and size != compressed_size:
            raise ValueError("Stored tile sizes must match")
        offset = self.offset
        self.pending = True
        self._write(
            struct.pack(
                "<I5H3I2H",
                0x04034B50,
                45,
                0,
                method,
                0,
                33,
                crc,
                compressed_size,
                size,
                len(name),
                0,
            )
        )
        self._write(name)
        extra = struct.pack("<HHQ", 1, 8, offset)
        self.directory.write(
            struct.pack(
                "<I6H3I5H2I",
                0x02014B50,
                0x031E,
                45,
                0,
                method,
                0,
                33,
                crc,
                compressed_size,
                size,
                len(name),
                len(extra),
                0,
                0,
                0,
                0,
                0xFFFFFFFF,
            )
        )
        self.directory.write(name + extra)
        self.count += 1

    def finish(self):
        if self.finished:
            raise ValueError("Archive is already finished")
        if self.pending:
            raise ValueError("Previous member did not complete; discard this archive")
        self.finished = True
        directory_offset, directory_size = self.offset, self.directory.tell()
        self.directory.seek(0)
        while block := self.directory.read(1024 * 1024):
            self._write(block)
        end_offset = self.offset
        self._write(
            struct.pack(
                "<IQ2H2I4Q",
                0x06064B50,
                44,
                0x031E,
                45,
                0,
                0,
                self.count,
                self.count,
                directory_size,
                directory_offset,
            )
        )
        self._write(struct.pack("<IIQI", 0x07064B50, 0, end_offset, 1))
        self._write(
            struct.pack(
                "<I4H2IH",
                0x06054B50,
                0,
                0,
                min(self.count, 65535),
                min(self.count, 65535),
                min(directory_size, 0xFFFFFFFF),
                min(directory_offset, 0xFFFFFFFF),
                0,
            )
        )
        self.directory.close()


def write_merged(inputs, output, source, overlap):
    attrs = definitions(source / "attr_def.h", "ATTR")
    items = definitions(source / "item_def.h", "ITEM")
    ref_sizes = {
        attrs["zipfile_ref"]: (4, 8),
        attrs["zipfile_ref_block"]: (12,),
        attrs["item_id"]: (8,),
    }
    root, metadata, stats = bytearray(), None, []
    # Exclusive creation avoids overwriting either input or existing results.
    with output.open("xb") as dest, NavitZip(dest) as writer:
        for source_number, path in enumerate(inputs):
            with zipfile.ZipFile(path) as archive:
                members, base = archive.infolist(), writer.count
                if base + len(members) >= 0x7FFFFFFF:
                    raise ValueError("Too many members for signed Navit references")
                roots = [
                    i for i, member in enumerate(members) if member.filename == "index"
                ]
                if len(roots) != 1:
                    raise ValueError("Expected exactly one index member")
                countries, rewritten = [], 0
                for number, member in enumerate(members):
                    data = overlap.rewrite(source_number, number, archive.read(member))
                    for start, end, kind, attributes in records(data):
                        for atype, offset, size in attributes:
                            if atype == attrs["ch_edge"]:
                                raise ValueError(
                                    "Contraction hierarchy references are unsupported"
                                )
                            if atype in ref_sizes:
                                if size not in ref_sizes[atype]:
                                    raise ValueError("Unexpected reference size")
                                old = struct.unpack_from("<I", data, offset)[0]
                                if old >= len(members):
                                    raise ValueError("Reference outside input archive")
                                struct.pack_into("<I", data, offset, base + old)
                                rewritten += 1
                        if number == roots[0]:
                            if kind == items["map_information"]:
                                info = data[start:end]
                                if metadata is None:
                                    metadata = info
                                elif info != metadata:
                                    raise ValueError("Input map metadata differs")
                            if kind == items["countryindex"]:
                                countries.append(data[start:end])
                    writer.add(f"m{base + number:013d}", data)
                # Keep original root item offsets valid, and let normal map
                # traversal enter it through a world-sized submap.
                root.extend(
                    struct.pack(
                        "<IIIiiiiIIIIII",
                        12,
                        items["submap"],
                        4,
                        -20015087,
                        -20015087,
                        20015087,
                        20015087,
                        2,
                        attrs["order"],
                        255 << 16,
                        2,
                        attrs["zipfile_ref"],
                        base + roots[0],
                    )
                )
                # Country searches intentionally do not descend submaps.
                for country in countries:
                    root.extend(country)
                stats.append(
                    {
                        "input": str(path),
                        "members": len(members),
                        "references": rewritten,
                    }
                )
        if metadata is None:
            raise ValueError("No map metadata")
        writer.add("index", metadata + root)
        writer.finish()
    return stats

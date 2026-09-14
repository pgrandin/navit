import hashlib
import io
from pathlib import Path
import sys
import unittest
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from binfile import NavitZip


class ShortWriteSink:
    """A pipe-like sink with no seek/tell and deliberate partial writes."""

    def __init__(self):
        self.data = bytearray()

    def write(self, data):
        count = min(len(data), 7)
        self.data.extend(data[:count])
        return count


class BoundedSource(io.BytesIO):
    def read(self, size=-1):
        if not 0 < size <= 1024 * 1024:
            raise AssertionError("Payload reads must be bounded")
        return super().read(min(size, 8191))


class StreamingTests(unittest.TestCase):
    def test_forward_only_output_matches_regular_file_bytes(self):
        expected, sink = io.BytesIO(), ShortWriteSink()
        for target in (expected, sink):
            with NavitZip(target) as writer:
                writer.add("00000000000000", b"tile" * 1024)
                writer.add("index", b"root")
                writer.finish()
        self.assertEqual(expected.getvalue(), sink.data)
        with zipfile.ZipFile(io.BytesIO(sink.data)) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(archive.read("index"), b"root")

    def test_precompressed_payload_matches_serialization(self):
        data = b"tile records" * 100_000
        compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
        compressed = compressor.compress(data) + compressor.flush()
        for method, payload in [(8, compressed), (0, data)]:
            with self.subTest(method=method):
                sink = io.BytesIO()
                with NavitZip(sink) as writer:
                    writer.add_precompressed(
                        "index",
                        BoundedSource(payload),
                        method=method,
                        crc=zlib.crc32(data),
                        size=len(data),
                        compressed_size=len(payload),
                        sha256=hashlib.sha256(payload).hexdigest(),
                    )
                    writer.finish()
                with zipfile.ZipFile(io.BytesIO(sink.getvalue())) as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertEqual(archive.read("index"), data)
                if method == 8:
                    regular = io.BytesIO()
                    with NavitZip(regular) as writer:
                        writer.add("index", data)
                        writer.finish()
                    self.assertEqual(regular.getvalue(), sink.getvalue())

    def test_corrupt_and_truncated_payloads_fail(self):
        for payload, message in [(b"bad!", "checksum"), (b"x", "length")]:
            with self.subTest(payload=payload):
                with NavitZip(io.BytesIO()) as writer:
                    with self.assertRaisesRegex(ValueError, message):
                        writer.add_precompressed(
                            "index",
                            io.BytesIO(payload),
                            method=0,
                            crc=0,
                            size=4,
                            compressed_size=4,
                            sha256=hashlib.sha256(b"good").hexdigest(),
                        )
                    with self.assertRaisesRegex(ValueError, "did not complete"):
                        writer.finish()

    def test_nonprogressing_sink_fails(self):
        class StalledSink:
            def write(self, data):
                return 0

        with NavitZip(StalledSink()) as writer:
            with self.assertRaises(OSError):
                writer.add("index", b"data")

    def test_finish_prevents_further_members_or_trailers(self):
        with NavitZip(io.BytesIO()) as writer:
            writer.add("index", b"data")
            writer.finish()
            with self.assertRaisesRegex(ValueError, "already finished"):
                writer.add("next", b"data")
            with self.assertRaisesRegex(ValueError, "already finished"):
                writer.finish()


if __name__ == "__main__":
    unittest.main()

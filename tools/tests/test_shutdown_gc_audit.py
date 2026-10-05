"""Check saved-dump boundaries without game processes or private evidence files."""

import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "shutdown_gc", Path(__file__).parents[1] / "re" / "audit_shutdown_gc.py"
)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


def saved_range(kind, payload=b"\0\0\0\0\x78\x56\x34\x12"):
    data = bytearray(512)
    data[:4] = b"MDMP"
    struct.pack_into("<II", data, 8, 1, 32)
    stream, captured, address = 64, 256, 0x100000000
    sizes = {5: 20, 9: 32, 3: 52}
    struct.pack_into("<III", data, 32, kind, sizes[kind], stream)
    if kind == 5:
        struct.pack_into("<I", data, stream, 1)
        struct.pack_into("<QII", data, stream + 4, address, len(payload), captured)
    elif kind == 9:
        struct.pack_into("<QQQQ", data, stream, 1, captured, address, len(payload))
    else:
        struct.pack_into("<I", data, stream, 1)
        struct.pack_into("<QII", data, stream + 4 + 24, address, len(payload), captured)
    data[captured:captured + len(payload)] = payload
    return data, address


class SavedDumpTests(unittest.TestCase):
    def test_all_captured_memory_sources(self):
        for kind in (5, 9, 3):
            with self.subTest(kind=kind):
                data, address = saved_range(kind)
                dump = AUDIT.SavedDump(data)
                self.assertEqual(dump.value(address, "<I"), 0)
                self.assertEqual(dump.value(address + 4, "<I"), 0x12345678)
                self.assertIsNone(dump.value(address + 8, "<I"))

    def test_partial_capture_is_unknown_not_zero_filled(self):
        data, address = saved_range(5, b"\x01\x02\x03\x04")
        dump = AUDIT.SavedDump(data)
        self.assertIsNone(dump.value(address))
        with self.assertRaisesRegex(ValueError, "Required memory is absent"):
            dump.required(address)

    def test_unmapped_address_cannot_read_unrelated_file_bytes(self):
        data, address = saved_range(5)
        dump = AUDIT.SavedDump(data)
        self.assertIsNone(dump.read(address - 1, 4))
        self.assertIsNone(dump.read(256, 4))

    def test_truncated_directory_is_rejected(self):
        data, _ = saved_range(5)
        with self.assertRaisesRegex(ValueError, "Truncated"):
            AUDIT.SavedDump(data[:40])

    def test_truncated_memory_payload_is_rejected(self):
        data, _ = saved_range(9)
        with self.assertRaisesRegex(ValueError, "Truncated"):
            AUDIT.SavedDump(data[:260])

    def test_wrong_evidence_hash_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="kf2vr-gc-audit-") as folder:
            path = Path(folder) / "unrelated.dmp"
            path.write_bytes(b"not the recorded evidence")
            with self.assertRaisesRegex(ValueError, "Unrecognized evidence file"):
                AUDIT.checked_file(path, AUDIT.DUMP_SHA256)


if __name__ == "__main__":
    unittest.main()

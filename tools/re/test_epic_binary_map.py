import unittest
from epic_binary_map import normalized

class BytesPE:
    def __init__(self, raw): self.raw=raw
    def read(self, at, size): return self.raw[at-0x1000:at-0x1000+size]

class NormalizationTests(unittest.TestCase):
    def norm(self, raw): return normalized(BytesPE(raw),0x1000,0x1000+len(raw))

    def test_external_calls_masked(self):
        a=self.norm(bytes.fromhex('e8 00 10 00 00 c3'))
        b=self.norm(bytes.fromhex('e8 00 20 00 00 c3'))
        self.assertEqual(a[:2],b[:2])
        self.assertNotEqual(a[2],b[2])
        self.assertTrue(a[3] and b[3])

    def test_internal_branch_topology_retained(self):
        a=self.norm(bytes.fromhex('75 01 90 c3'))
        b=self.norm(bytes.fromhex('75 00 90 c3'))
        self.assertNotEqual(a[0],b[0])

    def test_field_offsets_retained_global_references_masked(self):
        a=self.norm(bytes.fromhex('48 8b 81 80 00 00 00 c3'))
        b=self.norm(bytes.fromhex('48 8b 81 88 00 00 00 c3'))
        self.assertNotEqual(a[0],b[0])
        a=self.norm(bytes.fromhex('48 8b 05 80 00 00 00 c3'))
        b=self.norm(bytes.fromhex('48 8b 05 88 00 00 00 c3'))
        self.assertEqual(a[:2],b[:2])
        self.assertNotEqual(a[2],b[2])

    def test_truncated_instruction_refused(self):
        self.assertFalse(self.norm(bytes.fromhex('48 8b'))[3])

if __name__=='__main__': unittest.main()

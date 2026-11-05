"""Numeric checks for the source-skin visibility-bounds parser."""
import math
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_floating_hands import BONE, Chunk, WEIGHT
from generate_hand_bounds import reference_positions, spheres


def bone(name, parent, position, rotation=(0, 0, 0, 1)):
    return BONE.pack(name.encode(), 0, 0, parent, *rotation, *position, 0, 0, 0, 0)


def skin(bones, points, weights):
    return {
        'REFSKELT': Chunk('REFSKELT', 0, BONE.size, bones),
        'PNTS0000': Chunk('PNTS0000', 0, 12, [struct.pack('<3f', *p) for p in points]),
        'RAWWEIGHTS': Chunk('RAWWEIGHTS', 0, WEIGHT.size, [WEIGHT.pack(*w) for w in weights]),
        'VTXW0000': Chunk('VTXW0000', 0, 16, []),
        'FACE0000': Chunk('FACE0000', 0, 12, []),
        'MATT0000': Chunk('MATT0000', 0, 88, [bytes(88)]),
    }


class HandBoundsTests(unittest.TestCase):
    def test_actorx_child_quaternions_and_translated_root(self):
        half = math.sqrt(.5)
        bones = [bone('Root', 0, (10, 20, 30), (0, 0, half, half)),
                 bone('Wrist', 0, (2, 0, 0), (0, 0, half, half)),
                 bone('Finger', 1, (2, 0, 0))]
        positions = reference_positions([BONE.unpack(row) for row in bones])
        for actual, expected in zip(positions, [(10, 20, 30), (10, 22, 30), (12, 22, 30)]):
            for a, e in zip(actual, expected):
                self.assertAlmostEqual(a, e, places=5)

    def test_small_positive_weight_still_contributes_full_vertex(self):
        chunks = skin([bone('Root', 0, (0, 0, 0)), bone('Wrist', 0, (10, 0, 0))],
                      [(13, 4, 0), (10, 0, 2)],
                      [(.001, 0, 0), (.999, 0, 1), (1, 1, 1)])
        result = {s['bone']: s for s in spheres(chunks)}
        self.assertAlmostEqual(result['Wrist']['radius'], 5 * 1.00001)
        self.assertAlmostEqual(result['Root']['radius'], math.sqrt(185) * 1.00001)
        self.assertEqual(result['Wrist']['reference_length'], 10)

    def test_unweighted_bones_do_not_expand_culling_bounds(self):
        chunks = skin([bone('Root', 0, (0, 0, 0)), bone('Wrist', 0, (10, 0, 0)),
                       bone('Unused', 0, (1000, 0, 0))], [(10, 3, 4)], [(1, 0, 1)])
        result = spheres(chunks)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['bone'], 'Wrist')
        self.assertAlmostEqual(result[0]['radius'], 5 * 1.00001)

    def test_invalid_geometry_rejected(self):
        chunks = skin([bone('Root', 0, (0, 0, 0))], [(float('nan'), 0, 0)], [(1, 0, 0)])
        with self.assertRaises(ValueError):
            spheres(chunks)


if __name__ == '__main__':
    unittest.main()

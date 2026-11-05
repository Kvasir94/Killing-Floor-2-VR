"""Regression checks for the actual stock live-cartridge cut parser."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_reload_props import live_round_faces


class LiveRoundCutTests(unittest.TestCase):
    def parse(self, stem='Wep_1stP_AR15_9mm_Rig', faces=None, owner=None):
        return live_round_faces(stem, ['RW_Weapon', 'RW_Bullets1'],
                                [(0,), (1,), (2,), (3,)],
                                [(0, 1, 2, 0)] if faces is None else faces,
                                [1, 1, 1, 0] if owner is None else owner)

    def test_exact_single_round(self):
        bone, faces, slots = self.parse()
        self.assertEqual((bone, faces, slots), (1, [(0, 1, 2, 0)], [0]))

    def test_medic_shotgun_uses_its_round_material(self):
        self.assertEqual(self.parse('Wep_1stP_Medic_Shotgun_Rig', [(0, 1, 2, 1)])[2], [1])
        with self.assertRaises(ValueError):
            self.parse('Wep_1stP_Medic_Shotgun_Rig')

    def test_crossing_faces_cannot_cut_weapon_geometry(self):
        with self.assertRaises(ValueError):
            self.parse(faces=[(0, 1, 2, 0), (0, 1, 3, 0)])

    def test_empty_cut_is_rejected(self):
        with self.assertRaises(ValueError):
            self.parse(owner=[0, 0, 0, 0])

    def test_unexpected_materials_are_rejected(self):
        for faces in ([(0, 1, 2, 1)], [(0, 1, 2, 0), (0, 1, 2, 1)]):
            with self.subTest(faces=faces), self.assertRaises(ValueError):
                self.parse(faces=faces)

if __name__ == '__main__':
    unittest.main()

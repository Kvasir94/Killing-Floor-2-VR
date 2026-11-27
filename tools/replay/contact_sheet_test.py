"""Contact sheet layout (python -m unittest tools/replay/contact_sheet_test.py)."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contact_sheet


class LayoutTest(unittest.TestCase):
    def test_groups_wrap_to_the_column_count(self):
        groups = [('case 1  9mm', [(f'e{i}', Path(f'{i}.png')) for i in range(13)]), ('case 2  ar15', [('x', Path('x.png'))])]
        lines = contact_sheet.layout(groups, 6)
        self.assertEqual([len(t) for _, t in lines], [6, 6, 1, 1])
        self.assertEqual([label for label, _ in lines],
                         ['case 1  9mm', 'case 1  9mm (cont.)', 'case 1  9mm (cont.)', 'case 2  ar15'])

    def test_index_groups_follow_cases_and_name_the_hands(self):
        index = {'entries': [
            dict(case=1, weapon='KFGameContent.KFWeap_Pistol_9mm', settings='', event='a', image_relative='a.png', held_right='KFWeap_Pistol_9mm'),
            dict(case=1, weapon='KFGameContent.KFWeap_Pistol_9mm', settings='', event='b', image_relative='b.png'),
            dict(case=2, weapon='ar15', settings='preset-classic', event='c', image_relative='c.png'),
            dict(case=2, weapon='ar15', settings='preset-classic', event='missing')]}
        groups = contact_sheet.index_groups(index, Path('cap'))
        self.assertEqual([g[0] for g in groups], ['case 1  KFWeap_Pistol_9mm', 'case 2  ar15  preset-classic'])
        self.assertEqual(groups[0][1][0], ('a [KFWeap_Pistol_9mm]', Path('cap')/'a.png'))
        self.assertEqual(len(groups[1][1]), 1)


if __name__ == '__main__':
    unittest.main()
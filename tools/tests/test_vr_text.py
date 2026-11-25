import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('vr_text', Path(__file__).parents[1] / 'vr_text.py')
vr_text = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vr_text)


def table(text):
    folder = tempfile.TemporaryDirectory()
    path = Path(folder.name) / 'table.txt'
    path.write_text(text, encoding='utf-8')
    return folder, path


class VRTextTableTest(unittest.TestCase):
    def test_generated_class_matches_the_table(self):
        self.assertEqual(vr_text.main(['--check']), 0, 'run python tools/vr_text.py')

    def test_class_source_is_ascii_and_decodes_to_every_translation(self):
        pairs = vr_text.read()
        source = vr_text.source(pairs)
        source.encode('ascii')
        alphabet = re.search(r'Alphabet="([^"]*)"', source).group(1)
        codes = [int(value) for value in re.findall(r'Codes\(\d+\)=(\d+)', source)]
        shown = re.findall(r'Ru\(\d+\)="([^"]*)"', source)
        self.assertNotIn('\\', ''.join(shown))
        self.assertEqual(sorted(vr_text.decode(value, alphabet, codes) for value in shown),
                         sorted(russian for _, russian in pairs))

    def test_whole_texts_come_before_templates_and_longer_templates_first(self):
        order = [english for english, _ in vr_text.ordered(
            [('BACK *', 'НАЗАД *'), ('BACK', 'НАЗАД'), ('BACK *cm', 'НАЗАД * см'), ('OFF', 'ВЫКЛ')])]
        self.assertEqual(order, ['BACK', 'OFF', 'BACK *cm', 'BACK *'])

    def test_quotes_and_backslashes_in_a_translation_are_escaped(self):
        folder, path = table('SAY => «Скажи "да"» \\ ~\n')
        with folder:
            source = vr_text.source(vr_text.read(path))
        line = re.search(r'Ru\(0\)="([^"]*)"', source)
        self.assertIsNotNone(line)
        self.assertNotIn('\\', line.group(1))

    def test_table_mistakes_are_refused(self):
        for text in ('A => Б\nA => В\n',         # the same English twice
                     'PAGE * OF * => СТР. *\n',  # a * lost in translation
                     'A  B\n',                   # no separator
                     'É => Е\n'):                # English must be plain ASCII
            folder, path = table(text)
            with folder, self.subTest(text=text), self.assertRaises(ValueError):
                vr_text.read(path)


if __name__ == '__main__':
    unittest.main()

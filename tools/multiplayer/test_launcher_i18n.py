import os
import tempfile
import unittest
from unittest import mock

import launcher_i18n as i18n
import launcher_settings as model


def shown_texts():
    """Every settings-definition text the window can put on screen, as the window builds it."""
    texts = set()
    for category in model.DEFINITION["categories"]:
        texts.update(category.get(key, "") for key in ("id", "description", "customize", "reset_note"))
    for preset in model.PRESET_DEFS.values():
        texts.update((preset["label"], preset.get("help", "")))
        for option in preset["options"]:
            texts.update(option.get(key, "") for key in ("label", "help", "short"))
    for setting in model.SETTINGS:
        if setting.headset_only:
            continue
        texts.update((setting.label, setting.help, setting.group, setting.requires_reason))
        texts.update(name for _, name in setting.choices)
        texts.update(line for _, line in setting.choice_help)
        texts.update(line for _, line in setting.choice_short)
    for card in model.FIRST_TIME_SETUP["cards"]:
        texts.add(card["label"])
        for hints in card.get("hints", {}).values():
            texts.update(hints.values())
    return {text for text in texts if text and any(letter.isalpha() for letter in text)}


class LanguageTest(unittest.TestCase):
    def tearDown(self):
        i18n.set_language("en")

    def test_english_text_is_shown_as_written(self):
        i18n.set_language("en")
        self.assertEqual(i18n.tr("Play solo"), "Play solo")
        self.assertEqual(i18n.tr("3 maps. Type a name to search."), "3 maps. Type a name to search.")

    def test_unknown_language_means_english(self):
        i18n.set_language("xx")
        self.assertEqual(i18n.language(), "en")

    def test_russian_plural_forms(self):
        forms = ("карта", "карты", "карт")
        self.assertEqual([i18n.plural(n, *forms) for n in (1, 2, 5, 11, 12, 21, 22, 25, 111)],
                         ["карта", "карты", "карт", "карт", "карт", "карта", "карты", "карт", "карт"])

    def test_templates_fill_counts_and_keep_typed_text(self):
        i18n.set_language("ru")
        self.assertEqual(i18n.tr("21 maps. Type a name to search."), "21 карта. Начните вводить название для поиска.")
        # What the player typed is shown as typed, even when it is a word the table translates.
        self.assertEqual(i18n.tr("2 results for “reload”"), "2 результата по запросу «reload»")
        self.assertEqual(i18n.tr("No settings match “Comfort”."), "Нет настроек, подходящих под «Comfort».")

    def test_joined_text_is_translated_part_by_part(self):
        i18n.set_language("ru")
        self.assertEqual(i18n.tr("Burning Paris  ·  Hard  ·  Medium length"), "Burning Paris  ·  Трудная  ·  Средняя")
        self.assertEqual(i18n.tr("Walk with the stick. Online, the host's setting applies."),
                         "Ходьба стиком. В сетевой игре действует настройка хоста.")
        self.assertEqual(i18n.tr("OR CHOOSE A MATCH"), "ИЛИ ВЫБЕРИТЕ МАТЧ")

    def test_in_game_menu_pages_stay_english(self):
        i18n.set_language("ru")
        path = model.menu_path("Comfort")
        self.assertEqual(i18n.tr(path), path)
        self.assertEqual(i18n.tr(f"Snap angle: in {model.VR_MENU}, {path}."),
                         f"Угол поворота рывком: в VR-меню игры, раздел {path}.")

    def test_a_short_template_never_swallows_a_paragraph(self):
        i18n.set_language("ru")
        self.assertEqual(i18n.tr("KF2-VR plays with VAC (Steam's anti-cheat) off, so it joins only VAC-off servers. "
                                 "Matches earn XP as usual."),
                         "KF2-VR играет с выключенным VAC (античитом Steam), поэтому подключается только к серверам "
                         "без VAC. Опыт за матчи начисляется как обычно.")

    def test_every_setting_text_has_a_russian_translation(self):
        i18n.set_language("ru")
        with tempfile.TemporaryDirectory() as folder:
            missing = os.path.join(folder, "missing.txt")
            with mock.patch.dict(os.environ, {"KF2VR_I18N_MISSING": missing}):
                for text in sorted(shown_texts()):
                    i18n.tr(text)
            untranslated = open(missing, encoding="utf-8").read().splitlines() if os.path.exists(missing) else []
        self.assertEqual(untranslated, [])

    def test_a_long_option_help_is_translated_after_its_label(self):
        i18n.set_language("ru")
        with tempfile.TemporaryDirectory() as folder:
            missing = os.path.join(folder, "missing.txt")
            with mock.patch.dict(os.environ, {"KF2VR_I18N_MISSING": missing}):
                for text in sorted(shown_texts()):
                    i18n.tr(f"Selected: {text}")
            untranslated = open(missing, encoding="utf-8").read().splitlines() if os.path.exists(missing) else []
        self.assertEqual(untranslated, [])
        self.assertTrue(i18n.tr("Selected: Swap mags and rack slides, bolts and pumps by hand. An empty trigger "
                                "pull starts the reload and a new mag pushes out the old one.").startswith("Выбрано: "))

    def test_search_finds_settings_by_their_russian_names(self):
        i18n.set_language("ru")
        found = {setting.key for setting in model.search("перезаряд")}
        self.assertIn("bReloadHints", found)
        i18n.set_language("en")
        self.assertEqual(model.search("перезаряд"), [])


if __name__ == "__main__":
    unittest.main()

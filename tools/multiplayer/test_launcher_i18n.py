import json
import os
from pathlib import Path
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

    def test_plural_rules(self):
        self.assertEqual([i18n.plural_form("ru", n) for n in (1, 2, 5, 11, 12, 21, 22, 25, 111, "1.5")],
                         [0, 1, 2, 2, 2, 0, 1, 2, 2, 2])
        self.assertEqual([i18n.plural_form("en", n) for n in (0, 1, 2)], [1, 0, 1])
        self.assertEqual([i18n.plural_form("fr", n) for n in (0, 1, 2)], [0, 0, 1])

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

    def test_number_only_values_choose_their_own_key(self):
        i18n.set_language("ru")
        self.assertEqual(i18n.tr("Use 0–100 %"), "Допустимо: 0–100 %")
        self.assertEqual(i18n.tr("Use Balanced"), "Выбрать «Баланс»")
        self.assertEqual(i18n.tr("3 settings"), "3 настройки")
        self.assertEqual(i18n.tr("Comfort settings"), "настройки «Комфорт»")

    def test_in_game_menu_pages_use_the_headset_words(self):
        i18n.set_language("ru")
        self.assertEqual(i18n.tr(f"Snap angle: in {model.VR_MENU}, {model.menu_path('Comfort')}."),
                         "Угол поворота рывком: в VR-меню игры, раздел Настройки › Комфорт.")
        self.assertEqual(i18n.tr("Settings › Graphics & HUD › Customize › Gore & bodies › More › Corpse physics"),
                         "Настройки › Графика и HUD › Настроить › Кровь и тела › Ещё › Физика тел")

    def test_every_menu_page_the_launcher_names_matches_the_headset(self):
        """A page the launcher points to reads as the VR menu shows it, in capitals there."""
        vr = dict(zip(*(lambda c: (c["En"], c["Shown"]))(i18n.vr_text_config("ru"))))
        paths = set(model.MENU_PATHS.values()) | {model.menu_path(c["id"]) for c in model.DEFINITION["categories"]}
        for setting in model.SETTINGS:
            category, _, group = (setting.menu or f"{setting.tab}/{setting.group}").partition("/")
            if setting.menu or setting.headset_only:
                paths.add(model.menu_path(category, group))
        i18n.set_language("ru")
        for path in sorted(paths):
            for english, shown in zip(path.split(" › "), i18n.tr(path).split(" › ")):
                if english.upper() in vr:
                    self.assertEqual(shown.upper(), vr[english.upper()].upper(), path)

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


class LanguageFileTest(unittest.TestCase):
    def tearDown(self):
        i18n.set_language("en")
        i18n.refresh()

    def test_shipped_files_have_no_problems(self):
        for path in sorted(i18n.SHIPPED.glob("*.json")):
            self.assertEqual(i18n.check(i18n._read(path)), [], path.name)

    def test_a_player_file_adds_a_language_and_wins_over_a_shipped_one(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.dict(os.environ, {"KF2VR_LANGUAGES": folder}):
            Path(folder, "de.json").write_text(json.dumps({"name": "Deutsch", "plural": "en", "launcher": {
                "# heading": "", "Play solo": "Solo spielen", "Cancel": "",
                "{0} mods": "{0} {0:Mod|Mods}", "Broken {0}": "Kaputt {1}"},
                "vr": {"BACK": "ZURÜCK", "PAGE {0} OF {1}": "SEITE {0} VON {1}"}}), encoding="utf-8")
            Path(folder, "ru.json").write_text(json.dumps({"name": "Мой русский", "plural": "ru",
                                                           "launcher": {"Play solo": "Соло!"}}), encoding="utf-8")
            Path(folder, "bad.json").write_text("{ not json", encoding="utf-8")
            i18n.refresh()
            self.assertEqual(dict(i18n.languages()), {"en": "English", "de": "Deutsch", "ru": "Мой русский"})
            i18n.set_language("de")
            self.assertEqual(i18n.tr("Play solo"), "Solo spielen")
            self.assertEqual(i18n.tr("Cancel"), "Cancel")          # not translated yet
            self.assertEqual(i18n.tr("1 mods"), "1 Mod")
            self.assertEqual(i18n.tr("Broken thing"), "Broken thing")   # a faulty entry is left out
            config = i18n.vr_text_config("de")
            self.assertEqual(config, {"Language": "de", "En": ["BACK", "PAGE * OF *"], "Shown": ["ZURÜCK", "SEITE {0} VON {1}"]})
            i18n.set_language("ru")
            self.assertEqual(i18n.tr("Play solo"), "Соло!")
            self.assertEqual(i18n.vr_text_config("ru")["En"], [])

    def test_the_game_gets_the_language_chosen_in_the_launcher(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(i18n.saved_language(folder), i18n.detect())
            Path(folder, "launcher.json").write_text(json.dumps({"language": "ru"}), encoding="utf-8")
            self.assertEqual(i18n.saved_language(folder), "ru")
            Path(folder, "launcher.json").write_text(json.dumps({"language": "xx"}), encoding="utf-8")
            self.assertEqual(i18n.saved_language(folder), i18n.detect())

    def test_english_writes_no_table(self):
        self.assertEqual(i18n.vr_text_config("en"), {"Language": "en", "En": [], "Shown": []})

    def test_vr_templates_come_after_keys_most_fixed_text_first(self):
        config = i18n.vr_text_config("ru")
        stars = [key for key in config["En"] if "*" in key]
        self.assertTrue(stars and all("*" not in key for key in config["En"][:-len(stars)]))
        literal = [len(key.replace("*", "")) for key in stars]
        self.assertEqual(literal, sorted(literal, reverse=True))

    def test_check_names_mistakes(self):
        problems = i18n.check({"name": "X", "plural": "ru", "launcher": {"{0} maps": "{0} {0:карта|карты}", "A {1}": "B {1}"},
                               "vr": {"BACK": 'НА"ЗАД', "{1} AND {0}": "{0} И {1}", "ÜBER": "X"}})
        self.assertEqual(len(problems), 5, problems)
        self.assertIn('"plural" is one of', i18n.check({"name": "X", "plural": "xx"})[0])

    def test_update_adds_new_texts_and_keeps_translations(self):
        reference = {"name": "Русский", "plural": "ru",
                     "launcher": {"# Play": "", "Play solo": "Соло", "New text": "Новое"},
                     "vr": {"BACK": "НАЗАД"}}
        old = {"name": "Deutsch", "plural": "en", "launcher": {"# Old": "", "Play solo": "Solo spielen",
                                                               "Gone text": "Weg", "Gone empty": ""}}
        updated, unused = i18n._updated(old, reference)
        self.assertEqual(updated["name"], "Deutsch")
        self.assertEqual(list(updated["launcher"].items()),
                         [("# Play", ""), ("Play solo", "Solo spielen"), ("New text", ""),
                          ("# no longer in the program (kept for reference; delete when done)", ""), ("Gone text", "Weg")])
        self.assertEqual(updated["vr"], {"BACK": ""})
        self.assertEqual(unused, {"launcher": 1, "vr": 0})
        self.assertEqual(i18n._updated(updated, reference)[0], updated)   # running it again changes nothing

    def test_template_and_check_from_the_command_line(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder, "de.json")
            self.assertEqual(i18n.main(["--template", str(target)]), 0)
            data = json.loads(target.read_text(encoding="utf-8"))
            self.assertIn("Play solo", data["launcher"])
            self.assertTrue(all(value == "" for value in data["vr"].values()))
            data["name"] = "Deutsch"
            target.write_text(json.dumps(data), encoding="utf-8")
            self.assertEqual(i18n.main(["--check", str(target)]), 0)


if __name__ == "__main__":
    unittest.main()

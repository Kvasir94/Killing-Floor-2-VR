"""The player's language: the source text is English and is translated where it is shown.

A language is one JSON file, tools/languages/<code>.json in the release or
Languages/<code>.json in the player's KF2-VR profile folder (a file there wins
over a shipped one with the same code). It names the language, its plural rule
and two tables from the English text to its translation: "launcher" for this
window and "vr" for the in-game VR menu, training, watch and HUD, which the
launcher writes into the game's configuration at every start (vr_text_config).
Keys starting with "# " are headings for translators; an empty translation means
not translated yet. docs/TRANSLATING.md describes the format for translators.

Pages, settings-definition.json and launcher_app keep their English text, which
also stays the saved names, preset labels and search keys; only the widgets
that put text on screen call tr(). In the launcher table:

- a plain key is the whole English text (its capitals form is found too: "MATCH");
- a key with {0}, {1}... is a template for text built with values; each value is
  translated in turn and put where the translation says {0}, {1}... A value in
  quotes in the English (“{0}”) is what the player typed and is shown as it is.
  {0:n} in a key matches only a number ("Use {0:n}" and "Use {0}" are two keys).
  {0:form|form|form} in a translation is the plural form for that count, as
  many forms as the language's plural rule has (PLURALS);
- text no key matches is tried line by line, then by its "·" and "›" parts, then
  sentence by sentence, so text joined from translated pieces is translated too.
  A template that starts and ends with a value ("{0} — {1}") only joins parts and
  is tried last. What is still not found stays English (and is listed in the
  file KF2VR_I18N_MISSING names, for whoever keeps the translation complete).

Run this file with --check FILE to check a language file, or --template FILE to
start a new one from every English text the shipped languages translate.
"""
import json
import os
from pathlib import Path
import re
import sys

SHIPPED = Path(__file__).resolve().parents[1] / "languages"
_CODE = re.compile(r"^[a-z]{2,3}(?:-[a-z0-9]{2,8})?$")


def user_folder():
    """Where a player puts their own language files."""
    override = os.environ.get("KF2VR_LANGUAGES")
    if override:
        return Path(override)
    return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "KF2VR/Profile/Languages"


def _russian(n):
    if n % 10 == 1 and n % 100 != 11:
        return 0
    return 1 if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14 else 2


# Plural rule: (number of forms, which form a whole count takes). A count that is
# not a whole number takes the last form.
PLURALS = {
    "none": (1, lambda n: 0),                           # Chinese, Japanese, Korean, Turkish...
    "en": (2, lambda n: 0 if n == 1 else 1),            # English, German, Spanish, Italian...
    "fr": (2, lambda n: 0 if n in (0, 1) else 1),       # French, Brazilian Portuguese
    "ru": (3, _russian),                                # Russian, Ukrainian, Belarusian, Serbian
    "pl": (3, lambda n: 0 if n == 1 else 1 if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14 else 2),
    "cs": (3, lambda n: 0 if n == 1 else 1 if 2 <= n <= 4 else 2),   # Czech, Slovak
}

_language = "en"
_files = None      # code -> (name, path, data), found once
_tables = {}
_cache = {}
# A sentence ends at . ! ? or … followed by a space and a capital, quote, bracket or digit.
_SENTENCE = re.compile(r"(?<=[.!?…])\s+(?=[A-Z“\"(0-9])")
_KEY_VALUE = re.compile(r"\{(\d+)(:n)?\}")
_SHOWN_VALUE = re.compile(r"\{(\d+)(?::([^{}]*))?\}")
# A value in a template is part of one sentence: no line break and no sentence end inside it, so a short
# template ("KF2-VR {0}") never swallows a paragraph that only starts like it.
_VALUE = r"(?:(?![.!?…]\s+[A-Z“\"(0-9])[^\n])+?"


# ----- language files ------------------------------------------------------------------------------------
def _read(path):
    def pairs(items):
        found = {}
        for key, value in items:
            if key in found:
                raise ValueError(f"the key {key!r} is there twice")
            found[key] = value
        return found
    return json.loads(Path(path).read_text(encoding="utf-8-sig"), object_pairs_hook=pairs)


def _entry_problems(section, key, value, rule):
    """What is wrong with one translation, or [] when it can be used."""
    if not isinstance(value, str):
        return ["the translation is not text"]
    problems = []
    indexes = [int(index) for index, _ in _KEY_VALUE.findall(key)]
    if sorted(indexes) != list(range(len(indexes))):
        problems.append("the key's values must be {0}, {1}... each once")
    forms = PLURALS[rule][0] if rule in PLURALS else None
    for index, spec in _SHOWN_VALUE.findall(value):
        if int(index) not in indexes:
            problems.append(f"the translation uses {{{index}}}, which the key does not have")
        if spec and forms is not None and len(spec.split("|")) != forms:
            problems.append(f"{{{index}:...}} needs {forms} plural forms for the plural rule {rule!r}")
    if section == "vr":
        if not key.isascii():
            problems.append("a VR key is English text in plain (ASCII) letters")
        if any(mark in text for text in (key, value) for mark in ('"', "\\", "\n", "\r")):
            problems.append('VR text cannot hold ", \\ or line breaks')
        if key != key.strip() or value != value.strip():
            problems.append("VR text cannot start or end with a space")
        if ":n}" in key or re.search(r"\{\d+:", value):
            problems.append("VR text has no number-only values or plural forms")
        if indexes != sorted(indexes):
            problems.append("a VR key's values are in order: {0} before {1}")
        if "}{" in key:
            problems.append("two values in a VR key need text between them")
    return problems


def check(data):
    """Every problem in a language file's content, as readable lines; [] when it is fine."""
    if not isinstance(data, dict):
        return ["the file is not a JSON object"]
    problems = []
    if not isinstance(data.get("name"), str) or not data["name"].strip():
        problems.append('"name" is the language\'s own name, such as "Deutsch"')
    rule = data.get("plural")
    if rule not in PLURALS:
        problems.append(f'"plural" is one of {", ".join(PLURALS)}')
    for section in ("launcher", "vr"):
        table = data.get(section, {})
        if not isinstance(table, dict):
            problems.append(f'"{section}" is an object of "English": "translation" pairs')
            continue
        for key, value in table.items():
            if key.startswith("# ") or value == "":
                continue
            problems += [f'{section}: "{key}": {problem}' for problem in _entry_problems(section, key, value, rule)]
    return problems


def _entries(data, section):
    """A section's usable translations: headings, untranslated and faulty entries left out."""
    rule = data.get("plural")
    return {key: value for key, value in (data.get(section) or {}).items()
            if isinstance(data.get(section), dict) and not key.startswith("# ") and value != ""
            and not _entry_problems(section, key, value, rule)}


def _scan():
    found = {}
    for folder in (SHIPPED, user_folder()):
        try:
            paths = sorted(folder.glob("*.json"))
        except OSError:
            continue
        for path in paths:
            code = path.stem.lower()
            if code == "en" or not _CODE.match(code):
                continue
            try:
                data = _read(path)
            except (OSError, ValueError) as error:
                print(f"Language file {path} is skipped: {error}", file=sys.stderr)
                continue
            if not isinstance(data, dict) or not isinstance(data.get("name"), str) or data.get("plural") not in PLURALS:
                print(f"Language file {path} is skipped: " + "; ".join(check(data)[:3]), file=sys.stderr)
                continue
            found[code] = (data["name"].strip(), path, data)
    return found


def _available():
    global _files
    if _files is None:
        _files = _scan()
    return _files


def refresh():
    """Look for language files again (a player may have added one)."""
    global _files
    _files = None
    _tables.clear()
    _cache.clear()


def languages():
    """(code, name in that language) of every language, English first."""
    return (("en", "English"),) + tuple((code, name) for code, (name, _, _) in sorted(_available().items()))


def codes():
    return tuple(code for code, _ in languages())


def language():
    return _language


def set_language(code):
    """Show text in this language from now on; an unknown code means English."""
    global _language
    _language = code if code in codes() else "en"
    _cache.clear()


def detect():
    """The Windows display language when there is a file for it; else English."""
    try:
        import ctypes
        kernel = ctypes.windll.kernel32
        name = ctypes.create_unicode_buffer(85)
        if not kernel.LCIDToLocaleName(kernel.GetUserDefaultUILanguage(), name, 85, 0):
            return "en"
    except (AttributeError, OSError):
        return "en"
    locale = name.value.lower()   # "ru-ru", "pt-br"
    available = codes()
    for code in (locale, locale.split("-")[0]):
        if code in available:
            return code
    return "en"


def saved_language(profile=None):
    """The language the player chose in the launcher (launcher.json), else the Windows display language."""
    from workshop_loadout import _read_preferences
    from vr_config import profile_root
    chosen = _read_preferences(Path(profile or profile_root()) / "launcher.json").get("language")
    return chosen if chosen in codes() else detect()


def plural_form(rule, number):
    """Which plural form (0, 1, 2...) a count takes under a rule."""
    count, choose = PLURALS.get(rule, PLURALS["en"])
    try:
        value = float(str(number).replace(",", ".").replace(" ", "").replace(" ", ""))
    except ValueError:
        return count - 1
    return choose(abs(int(value))) if value == int(value) else count - 1


# ----- the launcher's table ------------------------------------------------------------------------------
def _pattern(key, value=_VALUE):
    """A template key as a regular expression: its text literally, each {n} as a named group."""
    parts, position = [], 0
    for match in _KEY_VALUE.finditer(key):
        parts.append(re.escape(key[position:match.start()]))
        number = r"(?=[-−0-9])" if match.group(2) else ""
        parts.append(f"(?P<a{match.group(1)}>{number}{value})")
        position = match.end()
    parts.append(re.escape(key[position:]))
    return re.compile("".join(parts), re.S)


class _Template:
    def __init__(self, key, value, rule, pattern):
        self.pattern, self.value, self.rule = pattern, value, rule
        # A value in quotes is what the player typed: shown as it is.
        self.verbatim = {int(index) for index in re.findall(r"“\{(\d+)(?::n)?\}”", key)}

    def render(self, arguments):
        def one(match):
            argument = arguments[int(match.group(1))]
            if match.group(2) is None:
                return argument
            forms = match.group(2).split("|")
            return forms[min(plural_form(self.rule, argument), len(forms) - 1)]
        return _SHOWN_VALUE.sub(one, self.value)


class _Table:
    def __init__(self, data):
        rule = data.get("plural", "en")
        self.exact, self.templates, self.loose, self.upper, self.whole = {}, [], [], {}, []
        for key, value in _entries(data, "launcher").items():
            if _KEY_VALUE.search(key):
                literal = len(_KEY_VALUE.sub("", key))
                typed = key.count(":n}")
                loose = key.startswith("{") and key.endswith("}")
                (self.loose if loose else self.templates).append((literal, typed, _Template(key, value, rule, _pattern(key))))
                if not loose:
                    # The same template with values of any length, used only when every value is a whole known
                    # text ("Selected: <a two-sentence option help>").
                    self.whole.append((literal, typed, _Template(key, value, rule, _pattern(key, r".+?"))))
            else:
                self.exact[key] = value
                if key.upper() != key:
                    self.upper.setdefault(key.upper(), value.upper())
        # The most specific template wins: the one with the most fixed text, then the one taking only numbers.
        # Templates that only join parts keep the file's order, which puts the likelier joint ("{0} — {1}")
        # before "{0} and {1}".
        self.templates.sort(key=lambda item: (-item[0], -item[1]))
        self.whole.sort(key=lambda item: (-item[0], -item[1]))


def _table(code):
    if code not in _tables:
        entry = _available().get(code)
        _tables[code] = _Table(entry[2] if entry else {})
    return _tables[code]


def tr(text):
    """The text in the current language; anything without a translation is returned as it is."""
    if _language == "en" or not isinstance(text, str) or not re.search(r"[A-Za-z]", text):
        return text
    found = _cache.get(text)
    if found is None:
        found = _cache[text] = _translate(_table(_language), text, 0)
    return found


def _fill(table, templates, text, depth):
    for _, _, template in templates:
        match = template.pattern.fullmatch(text)
        if match is None:
            continue
        names = sorted(match.groupdict(), key=lambda name: int(name[1:]))
        return template.render([match.group(name) if int(name[1:]) in template.verbatim
                                else _translate(table, match.group(name), depth + 1) for name in names])
    return None


# Where text joined from pieces splits back into them, tried in this order.
_SPLITTERS = (lambda t: t.split("\n"), lambda t: t.split("  ·  "), lambda t: t.split(" · "),
              lambda t: t.split("  ›  "), lambda t: t.split(" › "), _SENTENCE.split)


def _translate(table, text, depth):
    value = table.exact.get(text)
    if value is not None:
        return value
    if depth > 8 or not re.search(r"[A-Za-z]", text):
        return text
    stripped = text.strip()
    if stripped != text:
        if not stripped:
            return text
        head = text[:len(text) - len(text.lstrip())]
        return head + _translate(table, stripped, depth + 1) + text[len(text.rstrip()):]
    if text in table.upper:
        return table.upper[text]
    found = _fill(table, table.templates, text, depth)
    if found is not None:
        return found
    for _, _, template in table.whole:
        match = template.pattern.fullmatch(text)
        if match and all(int(name[1:]) in template.verbatim or part in table.exact
                         for name, part in match.groupdict().items()):
            return _fill(table, [(0, 0, template)], text, depth)
    for splitter in _SPLITTERS:
        parts = splitter(text)
        if len(parts) > 1:
            return _rejoin(text, parts, [_translate(table, part, depth + 1) for part in parts])
    found = _fill(table, table.loose, text, depth)
    if found is not None:
        return found
    _missing(text)
    return text


def _rejoin(text, parts, translated):
    """Put translated parts back with the separators the text had between them."""
    result, position = [], 0
    for part, done in zip(parts, translated):
        start = text.find(part, position)
        result.append(text[position:start])
        result.append(done)
        position = start + len(part)
    result.append(text[position:])
    return "".join(result)


def _missing(text):
    path = os.environ.get("KF2VR_I18N_MISSING")
    if not path or not re.search(r"[A-Za-z]{2}", text):
        return
    try:
        with open(path, "a", encoding="utf-8") as log:
            log.write(text.replace("\n", "\\n") + "\n")
    except OSError:
        pass


# ----- the in-game table -----------------------------------------------------------------------------------
VR_SECTION = "KF2VR.VRText"


def vr_text_config(code):
    """[KF2VR.VRText] values for the game: the language and its VR table, keys first and templates after,
    the one with the most fixed text first. VRText reads a key's values as * and puts them where the
    translation says {0}, {1}... English (or a language without a VR table) writes no table."""
    entry = _available().get(code) if code != "en" else None
    table = _entries(entry[2], "vr") if entry else {}
    exact = [(key, value) for key, value in table.items() if "{" not in key]
    templates = sorted(((key, value) for key, value in table.items() if "{" in key),
                       key=lambda item: -len(_KEY_VALUE.sub("", item[0])))
    ordered = exact + templates
    return {"Language": code if table else "en",
            "En": [_KEY_VALUE.sub("*", key) for key, _ in ordered],
            "Shown": [value for _, value in ordered]}


# ----- for translators -------------------------------------------------------------------------------------
def _template(source):
    data = _read(source)
    return {"name": "", "plural": "en",
            **{section: {key: "" for key in data.get(section, {})} for section in ("launcher", "vr")}}


def main(argv):
    if len(argv) == 2 and argv[0] == "--template":
        source = SHIPPED / "ru.json"
        Path(argv[1]).write_text(json.dumps(_template(source), ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"Wrote {argv[1]}: every English text, ready to translate. Name the file <code>.json (de.json).")
        return 0
    if len(argv) >= 2 and argv[0] == "--check":
        reference = _read(SHIPPED / "ru.json")
        failed = False
        for name in argv[1:]:
            try:
                data = _read(name)
            except (OSError, ValueError) as error:
                print(f"{name}: {error}")
                failed = True
                continue
            problems = check(data)
            failed |= bool(problems)
            print(f"{name}: " + ("fine" if not problems else f"{len(problems)} problem(s)"))
            for problem in problems:
                print("  " + problem)
            for section in ("launcher", "vr"):
                done = set(_entries(data, section)) if isinstance(data, dict) else set()
                wanted = [key for key in reference.get(section, {}) if not key.startswith("# ")]
                left = [key for key in wanted if key not in done]
                print(f"  {section}: {len(wanted) - len(left)} of {len(wanted)} texts translated")
        return 1 if failed else 0
    print(__doc__.split("\n\n")[-1].strip())
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

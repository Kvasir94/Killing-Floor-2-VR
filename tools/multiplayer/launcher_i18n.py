"""The player window's language: the source text is English and is translated where it is shown.

Pages, settings-definition.json and launcher_app keep their English text, which
also stays the saved names, preset labels and search keys; only the widgets
that put text on screen call tr(). A language is one module (launcher_lang_<code>.py)
holding TEXT, a table from the English text to its translation:

- a plain key is the whole English text (its capitals form is found too: "MATCH");
- a key with {0}, {1}... is a template for text built with values; each value is
  translated in turn, and the translation is a format string or a function of
  the (translated) values, so plural forms and word order are the language's own; Verbatim marks values
  shown as they are, such as a search the player typed;
- text no key matches is tried line by line, then by its "·" and "›" parts, then
  sentence by sentence, so text joined from translated pieces is translated too.
  A template that starts and ends with a value ("{0} — {1}") only joins parts and
  is tried last. What is still not found stays English (and is listed in the
  file KF2VR_I18N_MISSING names, for whoever keeps the translation complete).

KEEP lists patterns of text shown as it is, such as the page names of the
in-game VR menu, which the headset shows in English.
"""
import importlib
import os
import re

# (code, name shown in that language). English is the source text.
LANGUAGES = (("en", "English"), ("ru", "Русский"))
CODES = tuple(code for code, _ in LANGUAGES)
_language = "en"
_tables = {}
_cache = {}
# A sentence ends at . ! ? or … followed by a space and a capital, quote, bracket or digit.
_SENTENCE = re.compile(r"(?<=[.!?…])\s+(?=[A-Z“\"(0-9])")
_PLACEHOLDER = re.compile(r"\{(\d+)\}")
# A value in a template is part of one sentence: no line break and no sentence end inside it, so a short
# template ("KF2-VR {0}") never swallows a paragraph that only starts like it.
_VALUE = r"(?:(?![.!?…]\s+[A-Z“\"(0-9])[^\n])+?"


def language():
    return _language


def set_language(code):
    """Show text in this language from now on; an unknown code means English."""
    global _language
    _language = code if code in CODES else "en"
    _cache.clear()


def detect():
    """The Windows display language, when the launcher has it; else English."""
    try:
        import ctypes
        primary = ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF
    except (AttributeError, OSError):
        return "en"
    return {0x19: "ru"}.get(primary, "en")


def plural(number, one, few, many):
    """The Russian-style plural of a count: 1 карта, 2 карты, 5 карт (also 21, 22, 25...)."""
    try:
        n = abs(int(float(str(number).replace(",", "."))))
    except ValueError:
        return many
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


class Verbatim:
    """A template translation some of whose values are shown as they are (what the player typed)."""

    def __init__(self, value, *indexes):
        self.value, self.indexes = value, set(indexes)

    def __call__(self, *arguments):
        return self.value(*arguments) if callable(self.value) else self.value.format(*arguments)


def _pattern(key, value=_VALUE):
    """A template key as a regular expression: its text literally, each {n} as a named group."""
    parts, position = [], 0
    for match in _PLACEHOLDER.finditer(key):
        parts.append(re.escape(key[position:match.start()]))
        parts.append(f"(?P<a{match.group(1)}>{value})")
        position = match.end()
    parts.append(re.escape(key[position:]))
    return re.compile("".join(parts), re.S)


class _Table:
    def __init__(self, module):
        self.exact, self.templates, self.loose, self.upper = {}, [], [], {}
        # The same templates with values of any length, used only when every value is a whole known text
        # ("Selected: <a two-sentence option help>").
        self.whole = []
        self.keep = [re.compile(pattern) for pattern in getattr(module, "KEEP", ())]
        for key, value in module.TEXT.items():
            if _PLACEHOLDER.search(key):
                literal = len(_PLACEHOLDER.sub("", key))
                loose = key.startswith("{") and key.endswith("}")
                (self.loose if loose else self.templates).append((literal, _pattern(key), value))
                if not loose:
                    self.whole.append((literal, _pattern(key, r".+?"), value))
            else:
                self.exact[key] = value
                if isinstance(value, str) and key.upper() != key:
                    self.upper.setdefault(key.upper(), value.upper())
        # The most specific template wins: the one with the most fixed text. Templates that only join parts
        # keep the language module's order, which puts the likelier joint ("{0} — {1}") before "{0} and {1}".
        self.templates.sort(key=lambda item: -item[0])
        self.whole.sort(key=lambda item: -item[0])


class _Empty:
    TEXT = {}


def _table(code):
    if code not in _tables:
        try:
            _tables[code] = _Table(importlib.import_module(f"launcher_lang_{code}"))
        except ImportError:
            _tables[code] = _Table(_Empty)
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
    for _, pattern, value in templates:
        match = pattern.fullmatch(text)
        if match is None:
            continue
        names = sorted(match.groupdict(), key=lambda name: int(name[1:]))
        verbatim = value.indexes if isinstance(value, Verbatim) else ()
        arguments = [match.group(name) if int(name[1:]) in verbatim else _translate(table, match.group(name), depth + 1)
                     for name in names]
        return value(*arguments) if callable(value) else value.format(*arguments)
    return None


# Where text joined from pieces splits back into them, tried in this order.
_SPLITTERS = (lambda t: t.split("\n"), lambda t: t.split("  ·  "), lambda t: t.split(" · "),
              lambda t: t.split("  ›  "), _SENTENCE.split)


def _translate(table, text, depth):
    value = table.exact.get(text)
    if value is not None:
        return value
    if depth > 8 or not re.search(r"[A-Za-z]", text) or any(pattern.search(text) for pattern in table.keep):
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
    for _, pattern, value in table.whole:
        match = pattern.fullmatch(text)
        verbatim = value.indexes if isinstance(value, Verbatim) else ()
        if match and all(int(name[1:]) in verbatim or part in table.exact for name, part in match.groupdict().items()):
            return _fill(table, [(0, pattern, value)], text, depth)
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

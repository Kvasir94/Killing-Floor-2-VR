# Translating KF2-VR

The launcher window and the in-game VR menu (with VR training, the watch, HUD
prompts and the weapon wheel) can be shown in any language that has a language
file. A language file is plain JSON: no build, no tools beyond a text editor.

## Where language files live

- Shipped languages: `app/tools/languages/<code>.json` in the release.
- Your own: `%LOCALAPPDATA%\KF2VR\Profile\Languages\<code>.json`. In the
  launcher, **Game & headset > Your own translation > Open folder** opens it.
  A file there is listed under **Language** next to the shipped ones; one with
  the same code as a shipped language replaces it.

`<code>` is the language's ISO code in lower case: `de`, `fr`, `pt-br`. When no
language was chosen yet, the launcher picks the one matching the Windows
display language. The in-game VR text follows the launcher's choice from the
next start; Killing Floor 2's own menus keep the game's language.

## Starting a file

From a source checkout, write a template with every English text left empty:

```
python tools/multiplayer/launcher_i18n.py --template de.json
```

Or copy `ru.json` and replace the translations. Fill in `"name"` (the
language's own name, as the language list shows it) and `"plural"`.

## The format

```json
{
 "name": "Deutsch",
 "plural": "en",
 "launcher": {
  "# Play": "",
  "Play solo": "Solo spielen",
  "{0} mods": "{0} {0:Mod|Mods}",
  "No map matches “{0}”.": "Keine Karte passt zu „{0}“."
 },
 "vr": {
  "BACK": "ZURÜCK",
  "PAGE {0} OF {1}": "SEITE {0} VON {1}"
 }
}
```

- `"launcher"` is the player window, `"vr"` the text drawn in the headset.
- A key is the English text exactly as the program writes it, capitals
  included. Keep keys as they are; translate only the values.
- An empty value (`""`) means not translated yet: that text stays English.
- Keys starting with `# ` are headings and are ignored.
- `{0}`, `{1}`... stand for parts filled in at run time (a number, a name, a
  setting's value). Put them where your language needs them, in any order.
  Each part is translated in turn when the file has it.
- A part in quotes in the English (`“{0}”`) is what the player typed; it is
  shown as typed.
- `{0:n}` in a key matches only a number, so `"Use {0:n}"` and `"Use {0}"`
  are two different texts ("Use 0–100 %" under a number box, "Use Balanced"
  on a preset button).
- `{0:form|form...}` in a translation picks the plural form for the number in
  `{0}`: as many forms as the plural rule has.

Plural rules (`"plural"`):

| Rule | Forms | Languages |
| --- | --- | --- |
| `none` | 1 | Chinese, Japanese, Korean, Turkish... |
| `en` | 2: one, other | English, German, Spanish, Italian, Dutch, Swedish... |
| `fr` | 2: 0 and 1, other | French, Brazilian Portuguese |
| `ru` | 3: 1/21, 2–4/22–24, other | Russian, Ukrainian, Belarusian, Serbian |
| `pl` | 3: 1, 2–4/22–24, other | Polish |
| `cs` | 3: 1, 2–4, other | Czech, Slovak |

Text the file does not have whole is split where pieces were joined (lines,
`·` and `›` separators, sentences; in the VR menu also `: `, ` / `, `; ` and
similar) and the pieces are translated, so a sentence built from a label and a
value usually needs no key of its own.

## In-game text

The `"vr"` part is drawn with the game's fonts. Cyrillic works; scripts the
game's fonts lack (Chinese, Japanese, Arabic...) may show as boxes. Keep the
English capitals style where the menu uses it, and watch lengths: a much
longer text may be cut off on the watch or a menu row. In `"vr"`:

- keys are English in plain (ASCII) letters, values in your language;
- no `"`, `\`, line breaks, or spaces at the start or end;
- `{0}`, `{1}`... appear in the key in order, with text between them;
- no `{0:n}` and no plural forms.

## Checking a file

```
python tools/multiplayer/launcher_i18n.py --check de.json
```

lists every mistake and how many texts of each part are translated. A faulty
entry is skipped (that text stays English); a file that is not valid JSON, or
has no `"name"` or a known `"plural"`, is not listed at all. Start the launcher
again after changing a file; the in-game text changes at the next match start.

To share a translation, open an issue or a pull request with the file on the
project's GitHub page.

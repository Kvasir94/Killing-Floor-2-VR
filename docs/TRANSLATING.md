# Translating KF2-VR

The launcher window and the in-game VR text (the VR menu, VR training, the
watch, HUD prompts, the weapon wheel and the range) can be shown in any
language that has a language file. A language file is plain JSON that you edit
in a text editor: no build, no game files changed, and a translation never
breaks playing together with friends who use another language.

- [How it works](#how-it-works)
- [Where language files live](#where-language-files-live)
- [Running the language tool](#running-the-language-tool)
- [Adding a new language](#adding-a-new-language)
- [Updating a translation for a new release](#updating-a-translation-for-a-new-release)
- [Fixing or changing a shipped translation](#fixing-or-changing-a-shipped-translation)
- [The file format](#the-file-format)
- [Finding text that is still English](#finding-text-that-is-still-english)
- [Sharing a translation](#sharing-a-translation)
- [For developers: adding English text](#for-developers-adding-english-text)

## How it works

The program is written in English, and that English text is the key: a
language file maps each English text to its translation. The launcher
translates its own window while it draws it. When you press Play, it writes the
chosen language's in-game table into the game's configuration for that
session, and the VR menu translates what it draws from that table.

So:

- the launcher's **Language** choice (Welcome page or **Game & headset**) sets
  both the window and the in-game VR text; the window changes at once, the
  in-game text at the next match start;
- Killing Floor 2's own menus (Options, Trader, scoreboard) keep the game's
  language, which you set in Steam (Killing Floor 2 > Properties > Language);
- any text the file does not have is shown in English, so a partial
  translation works.

## Where language files live

| Where | What |
| --- | --- |
| `app\tools\languages\<code>.json` in the KF2-VR folder | Languages shipped with the release. Replaced by every update: do not edit them there. |
| `%LOCALAPPDATA%\KF2VR\Profile\Languages\<code>.json` | Your own files. Kept across updates. |

In the launcher, **Game & headset > Your own translation > Open folder** opens
your folder (and creates it). A file there is listed under **Language** next to
the shipped ones; a file with the same code as a shipped language replaces it.

`<code>` is the language's ISO 639-1 code in lower case, with a region when it
matters: `de`, `fr`, `es`, `pt-br`, `zh-cn`. When nobody has chosen a language
yet, the launcher picks the one matching the Windows display language (first
`pt-br`, then `pt`).

## Running the language tool

The tool makes a new file, brings a file up to date and checks it. It needs no
installation: the release carries its own Python. In PowerShell, with the
KF2-VR folder (the one with `Start KF2-VR.cmd`) as the current folder:

```powershell
& .\app\runtime\python.exe .\app\tools\multiplayer\launcher_i18n.py --check "$env:LOCALAPPDATA\KF2VR\Profile\Languages\de.json"
```

If you installed KF2-VR with its own installer, the folder is
`%LOCALAPPDATA%\KF2VR\current`. From a source checkout, use any Python 3.12+:
`python tools/multiplayer/launcher_i18n.py ...`.

| Command | What it does |
| --- | --- |
| `--template FILE` | Writes a new file with every English text and empty translations. |
| `--update FILE` | Adds the English texts this release has and the file lacks (empty), puts everything in the release's order under its headings, and moves texts the release no longer uses to the end. Translations are never lost. |
| `--check FILE` | Lists every mistake and how many texts of each part are translated. Exit code 1 when there are mistakes. |

Below, `launcher_i18n.py` stands for the whole command.

## Adding a new language

1. **Make the file.** In your languages folder:

   ```powershell
   launcher_i18n.py --template "$env:LOCALAPPDATA\KF2VR\Profile\Languages\de.json"
   ```

   Or copy `app\tools\languages\ru.json` there under your code's name and
   translate over the Russian; this shows how each text was handled.

2. **Fill in the header.** `"name"` is the language's own name as the list
   shows it (`"Deutsch"`, not `"German"`). `"plural"` is the plural rule from
   [the table below](#plural-forms).

3. **Translate.** Open the file in an editor that saves UTF-8 (VS Code,
   Notepad++, or Windows Notepad). Translate the values on the right; never
   change the English keys on the left. Leave a value `""` to keep that text
   English for now. Headings (`"# Play": ""`) say where texts are used.

   Start with what players see first: in `"launcher"` the sections down to
   **Play** and **match forms**, in `"vr"` **Shared values**, **VR menu: pages
   and titles** and **VR menu: setting rows**.

4. **Check it** and fix what the tool lists:

   ```powershell
   launcher_i18n.py --check "$env:LOCALAPPDATA\KF2VR\Profile\Languages\de.json"
   ```

5. **See it in the launcher.** Start the launcher (or go to **Game & headset**
   again) and pick your language under **Language**. Click through every page
   and dialog.

6. **See it in the headset.** Start a Solo match. Open the VR menu (Menu
   button on the left controller, or hold both sticks) and go through every
   page; open the weapon wheel and the watch; run VR training once. Look for
   text that is cut off or overlaps, and for boxes instead of letters (the
   game's fonts lack that script).

7. **Share it** when you are happy with it ([below](#sharing-a-translation)).

A translation does not have to be complete to be useful: missing texts show
in English.

## Updating a translation for a new release

New releases add and change English texts; a changed text is a new key, so its
old translation no longer applies. After updating KF2-VR:

1. Bring your file up to date:

   ```powershell
   launcher_i18n.py --update "$env:LOCALAPPDATA\KF2VR\Profile\Languages\de.json"
   ```

   It prints how many texts are new (empty now) and how many are no longer
   used.

2. Translate the new, empty texts. Search the file for `": ""` to find them
   (headings are empty too; skip those).

3. Look at the section **no longer in the program** at the end of each part.
   A text there was usually reworded: find its new English version among the
   empty ones and reuse your translation. Then delete the section (or leave it;
   it does no harm).

4. `--check` the file and look at the changed screens in the launcher and the
   headset.

Your file in the profile folder is never touched by an update. If it is a
shipped language you override, compare it with the new shipped file too: the
shipped translation may have been fixed meanwhile.

## Fixing or changing a shipped translation

To change a few texts of a shipped language for yourself, copy its file from
`app\tools\languages\` into your languages folder and edit the copy: your copy
replaces the shipped one. Remember that it also replaces the shipped file's
later fixes, so `--update` it after each release, or delete it once your fixes
are shipped.

To fix it for everyone, send the change ([below](#sharing-a-translation)).

## The file format

```json
{
 "name": "Deutsch",
 "plural": "en",
 "launcher": {
  "# Play": "",
  "Play solo": "Solo spielen",
  "{0} mods": "{0} {0:Mod|Mods}",
  "No map matches “{0}”.": "Keine Karte passt zu „{0}“.",
  "Use {0:n}": "Erlaubt: {0}",
  "Use {0}": "„{0}“ verwenden"
 },
 "vr": {
  "BACK": "ZURÜCK",
  "PAGE {0} OF {1}": "SEITE {0} VON {1}"
 }
}
```

### Keys and values

- `"launcher"` is the player window, `"vr"` the text drawn in the headset.
- A key is the English text exactly as the program writes it, capitals and
  punctuation included. Keys are case-sensitive in `"vr"` (`"OFF"` and `"Off"`
  are different texts). In `"launcher"`, a key also covers its all-capitals
  form: `"Match"` translates `"MATCH"` too.
- An empty value (`""`) means not translated yet.
- Keys starting with `# ` are headings and are ignored. Keys must be unique.
- Typographic quotes and dashes in the English (`“ ” ’ — …`) are part of the
  key; copy keys, do not retype them.
- JSON needs `\"` for a straight double quote and `\\` for a backslash inside
  a value. Prefer your language's own quotation marks (`„ “`, `« »`).

### Parts filled in at run time

- `{0}`, `{1}`... stand for parts the program fills in: a number, a name, a
  setting's value, another sentence. Put them where your language needs them,
  in any order; you may leave one out. Each part is itself translated when the
  file has it (`"Hard"` inside `"{0} difficulty"`).
- A part in quotes in the English (`“{0}”`) is what the player typed, such as
  a search; it is shown as typed.
- `{0:n}` in a key matches only a number, so `"Use {0:n}"` and `"Use {0}"` are
  two different texts: `"Use 0–100 %"` under a number box and `"Use Balanced"`
  on a preset button. When the key has `{0:n}`, the value still writes `{0}`.

### Plural forms

`{0:form|form|...}` in a value is replaced by the form that fits the number in
`{0}`: `"{0} {0:карта|карты|карт}"` gives `1 карта`, `3 карты`, `5 карт`. Give
exactly as many forms as the file's plural rule has:

| `"plural"` | Forms, in this order | Languages |
| --- | --- | --- |
| `none` | 1 | Chinese, Japanese, Korean, Thai, Turkish, Vietnamese |
| `en` | 2: one, other | English, German, Dutch, Swedish, Danish, Norwegian, Spanish, Italian, Greek, Hungarian, Finnish |
| `fr` | 2: 0 and 1, other | French, Brazilian Portuguese |
| `ru` | 3: 1, 21, 31...; 2–4, 22–24...; other | Russian, Ukrainian, Belarusian, Serbian, Croatian |
| `pl` | 3: 1; 2–4, 22–24...; other | Polish |
| `cs` | 3: 1; 2–4; other | Czech, Slovak |

A number with a fraction takes the last form. If your language needs a rule
that is not listed, ask for it ([below](#sharing-a-translation)).

### Joined text

Many texts on screen are built from pieces: `"Burning Paris  ·  Hard  ·  Medium length"`,
`"Comfort › Turning"`, a label and its value, several sentences. Text the file
does not have whole is split where pieces were joined (line breaks, `·`, `›`,
sentence ends; in the VR menu also `: `, ` / `, ` | `, `; `, ` + `, ` - `) and
each piece is translated. So translate the pieces (`"Hard"`, `"Medium length"`)
and the joined text follows. A template such as `"{0} — {1}"` or `"{0} and {1}"`
says how two translated pieces are joined in your language.

### Rules for in-game text (`"vr"`)

The VR text is drawn with the game's fonts, in small spaces:

- Cyrillic, Latin and Greek letters work. Scripts the game's fonts lack
  (Chinese, Japanese, Korean, Arabic, Hebrew, Thai...) show as boxes.
- Keep lengths close to the English. The watch, the weapon wheel and menu rows
  have fixed widths; a much longer text is cut off or squeezed. Prefer short
  words and common abbreviations over full phrases.
- Keep the English capitals style: the menu is written in capitals.
- Values must not contain `"`, `\`, line breaks, or spaces at the start or end.
- `{0}`, `{1}`... appear in a key in order, with text between them; no `{0:n}`
  and no plural forms in `"vr"`.
- Use the same words as the launcher for the same things: the launcher points
  players to VR menu pages by name (`Settings › Comfort`), and those names
  must match what the headset shows.

`--check` reports every rule a value breaks; an entry with a mistake is
skipped (that text stays English) and the rest of the file still works. A file
that is not valid JSON, or has no `"name"` or no known `"plural"`, is not
listed at all; `--check` names the problem.

## Finding text that is still English

**Launcher.** Start the launcher with a list of untranslated texts written to
a file, click through every page and dialog, then read the file:

```powershell
$env:KF2VR_I18N_MISSING = "$env:USERPROFILE\Desktop\untranslated.txt"
& ".\Start KF2-VR.cmd"   # in your KF2-VR folder
```

Names of maps, mods, folders and graphics cards are listed too; those stay as
they are.

**Headset.** Go through the menus and note what is still English, then search
the `"vr"` part for it. Most in-game text is written in capitals; search
ignoring case. If a text is built from pieces (`"TURN SPEED: 45"`), translate
the label (`"TURN SPEED"`); values like `"45"` need nothing.

## Sharing a translation

On the project's GitHub page, either:

- open an issue, attach your `<code>.json`, and say which release it is for;
  or
- open a pull request that adds or changes `tools/languages/<code>.json`.
  Run `--check` first, and say how much you checked in the launcher and in the
  headset.

New files are shipped in the next release and appear for every player in the
language list.

## For developers: adding English text

- Write player-facing text in English as usual. The launcher translates it
  where a widget puts it on screen (`launcher_i18n.tr`); in the game, every
  function that draws text passes it through `VRText.T`. Text built from
  pieces should join them with the separators above so the pieces translate on
  their own.
- When you add or change English text, add its key to `tools/languages/ru.json`
  under the matching heading (with the Russian translation, or `""`): that file
  is the reference `--template` and `--update` copy keys from. Other languages
  pick the new key up with `--update`.
- A changed English text is a new key: change the key in `ru.json` too, or
  the old one moves to "no longer in the program" at the next `--update`.
- `python -m unittest test_launcher_i18n` (in `tools/multiplayer`) checks the
  shipped files, that every setting's text is translated in Russian, and that
  the launcher names VR menu pages the way the headset does.

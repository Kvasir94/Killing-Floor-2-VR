"""The player window's pages: welcome, first-time setup, Play, match forms, Join, the running session,
Setup and Help, plus the Graphics and Your controls dialogs. Settings live in launcher_ui_settings.py.

Pages only show LauncherState and call it; every launch argument is built there.
"""

from pathlib import Path

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QDesktopServices, QGuiApplication
from PySide6.QtCore import QUrl
from PySide6.QtWidgets import QGridLayout, QPlainTextEdit, QProgressBar, QSizePolicy, QWidget, QLineEdit, QFrame

import launcher_app as app
import launcher_settings as model
import launcher_ui_theme as T
from launcher_ui_widgets import (Accordion, FlowGrid, SplitRow, PathLabel, ArrowCard, Button, Callout, Card, Dialog, Dropdown, Heading, HeroFrame, Mark, Page, Panel,
                                 Segmented, SettingRow, SwitchControl, TextField, clear, glyph, hbox, holder, label,
                                 rule, section, set_tone, vbox)


def status_row(ok, text, detail=None, state=None):
    """A mark, a line and an optional muted line beneath it."""
    mark = Mark(state or ("ok" if ok else "warn"), size=22)
    lines = vbox(label(text, "h3", wrap=True), spacing=2)
    if detail:
        lines.addWidget(label(detail, "help", wrap=True))
    row = hbox(spacing=T.S3)
    row.addWidget(mark, 0, Qt.AlignmentFlag.AlignTop)
    row.addLayout(lines, 1)
    return holder(row)


def store_cards(installs, selected, command, columns=2):
    """One card per installation found; the chosen one is outlined in red."""
    grid = FlowGrid(min_column=280, max_columns=columns)
    for install in installs:
        chosen = selected is not None and str(install.root).casefold() == str(selected.root).casefold()
        card = Card(clickable=True, selected=chosen)
        head = hbox(label(app.STORE_NAMES[install.store], "h2"), None, spacing=T.S2)
        if chosen:
            # The red outline marks the choice; the tag is a plain check so it doesn't compete with Recommended.
            head.addWidget(label("✓ Selected", "help"))
        card.layout_.addLayout(head)
        steam = install.store == "steam"
        tag = hbox(label("Recommended" if steam else "Experimental", "tag", "ok" if steam else "warn"),
                   label("Solo, Host and Join" if steam else "Solo in VR only", "help", wrap=True), spacing=T.S2)
        card.layout_.addLayout(tag)
        card.add(PathLabel(str(install.root)))
        card.clicked.connect(lambda install=install: command(install))
        grid.add(card)
    return grid


def graphics_row(page, on_change):
    """A row of the form's card: the graphics every match uses, and a link to change them without leaving the form."""
    value = page.state.graphics_summary().removeprefix("Graphics: ")
    cell = hbox(spacing=T.S3)
    cell.addWidget(label(value[0].upper() + value[1:], "body"))
    if page.state.vr:
        cell.addWidget(Button("Change…", lambda: (GraphicsDialog(page.window_).run(), on_change()), size="sm"))
    return SettingRow("Graphics", "", holder(cell))


def missing_game_actions(window, after):
    """What a player without the game found can do: get it, point at it, or look again."""
    return ((app.GET_GAME, lambda: QDesktopServices.openUrl(QUrl(app.STEAM_STORE_URL)), "secondary"),
            (app.OTHER_FOLDER, lambda: window.pick_game_folder(after), "secondary"),
            ("Check again", after, "secondary"))


def short_choices(setting):
    names = [text for _, text in setting.choices]
    return 2 <= len(names) <= 3 and all(len(name) <= 14 for name in names)


def recommended_values():
    """{setting key: recommended value} from first-time setup's advice cards (never the player's own hand or posture)."""
    values = {}
    for card in model.FIRST_TIME_SETUP["cards"]:
        if card["id"] in app.PERSONAL_CARDS or "recommended" not in card:
            continue
        wanted = card["recommended"]
        values.update({card["setting"]: wanted} if "setting" in card else wanted)
    for entry in model.DEFINITION["settings"]:
        if "recommended" in entry and "key" in entry:
            values.setdefault(entry["key"], entry["recommended"])
    return {key: str(value) for key, value in values.items()}


RECOMMENDED = recommended_values()


def setting_control(setting, value, on_change, width=T.CONTROL_WIDTH):
    """The one control a setting uses on every page: a switch for on/off, joined buttons for two or three
    short choices, otherwise a dropdown. Numbers return None; their pages build a stepper."""
    names = dict(setting.choices)
    if setting.kind == "toggle":
        return SwitchControl(value, on_change)
    if setting.kind == "choice" and sorted(names.values()) == ["Off", "On"]:
        on = next(stored for stored, text in names.items() if text == "On")
        off = next(stored for stored, text in names.items() if text == "Off")
        return SwitchControl(str(value) == on, lambda chosen: on_change(on if chosen else off))
    if setting.kind == "choice" and short_choices(setting) and str(value) in names:
        return Segmented(setting.choices, str(value), on_change, recommended=RECOMMENDED.get(setting.key))
    if setting.kind == "choice":
        return Dropdown(model.labels(setting, value), value, on_change, width=width)
    return None


def preset_control(preset, values, on_choose):
    """A preset as joined buttons; its recommended option carries a star."""
    current = model.preset_name(preset, values)
    names = list(model.preset_targets(preset))
    return Segmented([(name, name) for name in names], current if current != "Custom" else None, on_choose,
                     recommended=model.preset_recommended(preset))


def preset_line(preset, values):
    """(line, muted line) under a preset: "Selected: <what the picked option does>" (or that it is Custom),
    and the other options' short forms where their names don't say it."""
    selected, others = model.preset_summary(preset, values)
    if model.preset_name(preset, values) == "Custom":
        return (f"Custom: some of its settings were changed in {app.VR_MENU}. Pick an option to use it again.",
                " · ".join(f"{option['label']} — {option['short']}" for option in model.PRESET_DEFS[preset]["options"]
                           if option.get("short")))
    return (f"Selected: {selected}" if selected else "", others)


def graphics_pick_line():
    """What the recommended graphics preset rests on, said wherever the preset is: setup, Settings, dialog."""
    _, gpu = model.graphics_recommendation()
    return f"★ for your {gpu}." if gpu else "We couldn't read your graphics card, so Balanced is recommended."


def setting_help(setting, values, skip_help=""):
    """(line, muted line) for a setting, the same on first-time setup, Settings and dialogs: a choice whose
    options each have a line says "Selected: <line>" and, where names don't explain themselves, the other
    options' short forms; any other setting says its help."""
    selected, others = model.option_summary(setting, values[setting.key])
    if selected:
        return f"Selected: {selected}", others
    line = " ".join(part for part in (setting.help if setting.help != skip_help else "",
                                      model.choice_help(setting, values[setting.key])) if part)
    return line, ""


def setting_row(setting, values, on_change, running=False, extra_help=""):
    """The one row for a setting on every page: name, two lines at most, its control."""
    control = setting_control(setting, values[setting.key], on_change)
    control.setEnabled(not running)
    line, muted = setting_help(setting, values)
    return SettingRow(setting.label, line, control, note=" ".join(p for p in (muted, extra_help) if p) or None), control


def preset_row(preset, values, on_choose, running=False, extra_help=""):
    """The one row for a preset on every page: name, two lines at most, its joined buttons."""
    control = preset_control(preset, values, on_choose)
    control.setEnabled(not running)
    line, muted = preset_line(preset, values)
    return (SettingRow(model.PRESET_DEFS[preset]["label"], line, control,
                       note=" ".join(p for p in (muted, extra_help) if p) or None), control)


# ----- onboarding ---------------------------------------------------------------------
class WelcomePage(Page):
    nav = "welcome"

    def __init__(self, window):
        super().__init__(window, "Welcome to KF2-VR", "Two quick steps, then you're ready to play.")
        self.checked = False

    def build(self):
        state = self.state
        found = state.installs()
        install, problem = state.resolve_game()
        # With both stores found and nothing chosen yet, Steam (recommended) starts selected;
        # it is saved when the player presses Next.
        steam = next((item for item in found if item.store == "steam"), None)
        self.preselected = steam if problem == "choose" else None
        self.add(section("Your game", top=T.S2))
        if len(found) > 1:
            self.add(label("Pick the copy of Killing Floor 2 to play.", "body", wrap=True))
            self.add(store_cards(found, install or self.preselected, self.choose))
        elif install:
            self.add(store_cards([install], install, self.choose))
        else:
            box = Callout("warn", "Killing Floor 2 wasn't found", app.GAME_MISSING,
                          actions=missing_game_actions(self.window_, self.check_again))
            if self.checked:
                box.body.addWidget(label("Checked just now: still not found.", "muted"))
            self.add(box)
        chosen = install or self.preselected
        if chosen is not None and chosen.store == "epic" and len(found) > 1:
            self.add(Callout("info", "", app.EPIC_LIMITS))
        self.add(section("Your headset"))
        ready, runtime = state.headset()
        if ready:
            self.add(status_row(True, f"Ready: {app.runtime_name(runtime)}", app.HEADSET_READY))
        else:
            self.add(status_row(False, "No headset app is running", app.HEADSET_MISSING))
            again = hbox(Button("Check again", self.check_again, size="sm"),
                         label("Checked just now" if self.checked else "", "muted"), None, margins=(34, T.S1, 0, 0))
            self.add_layout(again)
        # First-time setup can't finish without a game: Next waits for one.
        self.set_footer(primary=self.next_step, primary_text="Next",
                        enabled=install is not None or self.preselected is not None,
                        reason="Find your game first" if problem == "missing" else "Choose a copy of the game first")

    def check_again(self):
        self.state.forget()
        self.checked = True
        self.rebuild()

    def choose(self, install):
        self.state.use_install(install)
        self.window_.refresh_art()
        self.rebuild()

    def next_step(self):
        if self.preselected is not None:
            self.state.use_install(self.preselected)
        self.window_.show_page("first-time")




class FirstTimePage(Page):
    nav = "first-time"

    def __init__(self, window):
        setup = model.FIRST_TIME_SETUP
        super().__init__(window, setup["label"], setup["help"])
        self.origin = None

    def prepare(self, origin=None, **_):
        self.origin = origin
        # What this visit can put back on Cancel (a re-run from Game & headset only).
        self.snapshot = None if self.state.onboarding else (dict(model.load(self.state.saved)),
                                                            model.preset_name("graphics_preset",
                                                                              model.load(self.state.saved)))

    def cancel(self):
        if getattr(self, "snapshot", None):
            before, graphics = self.snapshot
            now = model.load(self.state.saved)
            changed = {key: value for key, value in before.items() if str(now.get(key)) != str(value)}
            if changed:
                self.state.persist(changed)
            if graphics != "Custom" and model.preset_name("graphics_preset", model.load(self.state.saved)) != graphics:
                self.state.apply_preset("graphics_preset", graphics)
        self.state.setup_touched = set()
        self.window_.show_page(self.origin or "setup")

    def build(self):
        state = self.state
        state.settings_values = model.load(state.saved)
        values = state.settings_values
        self.running = running = state.session_running()
        setup = model.FIRST_TIME_SETUP
        if state.onboarding:
            self.set_title(setup["label"], setup["help"])
        else:
            self.set_title(setup["label"], "Change any of these; Cancel puts back what you change here.")
        if running:
            self.add(Callout("warn", "A game is running",
                             f"Change these in {app.VR_MENU}; they're read-only here until the game closes."))
        cards = {card["id"]: card for card in model.FIRST_TIME_SETUP["cards"]}
        # The same rows as Settings (name, every option's line, control), in one card.
        panel = Panel()
        for card in model.FIRST_TIME_SETUP["cards"]:
            if not model.card_applies(card, values):
                continue
            if "preset" in card:
                extra = graphics_pick_line() if card["preset"] == "graphics_preset" else ""
                panel.add(preset_row(card["preset"], values,
                                     lambda name, card=card: self.saved(
                                         state.choose_card_preset(card["id"], card["preset"], name)),
                                     running, extra)[0])
                continue
            for key in [card["setting"]] if "setting" in card else card.get("settings", []):
                panel.add(setting_row(model.BY_KEY[key], values,
                                      lambda stored, key=key, card=card["id"]: self.saved(
                                          state.choose_card_setting(card, key, stored)), running)[0])
        self.add(panel)
        extra = []
        if state.unanswered_differing() and not running:
            rest = Button("Fill in the rest with recommended choices", self.recommended)
            rest.setToolTip("Your hand and seated choices never change.")
            extra.append(rest)
        if state.onboarding:
            self.set_footer(back=self.go_back_to, primary=self.done, primary_text="Finish setup",
                            enabled=not running, reason="Locked while a game runs", extra=extra)
        else:
            # Run again from Game & headset: Cancel puts back what this visit changed; Done keeps it.
            self.set_footer(back=self.cancel, back_text="Cancel", primary=self.done, primary_text="Done",
                            enabled=not running, reason="Locked while a game runs", extra=extra)

    def saved(self, result):
        ok, problem = result
        if not ok:
            self.window_.save_failed(problem)
        self.rebuild(keep_scroll=True)

    def recommended(self):
        names = [card["label"] for card in self.state.unanswered_differing()]
        if not names or not self.window_.ask("Fill in the rest?",
                                             "This sets " + ", ".join(names) + " to the recommended choice.",
                                             yes="Fill in the rest"):
            return
        self.saved(self.state.use_recommended())

    def go_back_to(self):
        self.window_.show_page("welcome" if self.state.onboarding else self.origin or "setup")

    def done(self):
        onboarding = self.state.onboarding
        self.state.complete_setup()
        if onboarding or not self.origin:
            self.window_.show_page("play", welcome=onboarding)
        else:
            self.window_.show_page(self.origin)


# ----- play ----------------------------------------------------------------------------
class PlayPage(Page):
    nav = "Play"

    def __init__(self, window):
        super().__init__(window, "Play", "")
        self.welcome = False

    def prepare(self, welcome=False, **_):
        self.welcome = welcome or self.welcome

    def build(self):
        state = self.state
        state.onboarding = False
        state.refresh_player_preferences()
        note = state.upgrade_note_pending()
        epic = state.store == "epic"
        install, problem = state.resolve_game()
        if self.welcome and install is not None and state.vr:
            self.add(Callout("ok", "You're set",
                             f"Fine-tune feel and fit in {app.VR_MENU}. " + app.HEADSET_MENU,
                             dismiss=self.dismiss_welcome))
            self.column.addSpacing(T.S2)  # the banner is its own group, not part of the status row
        notice = self.window_.update_notice
        if notice:
            tag, url = notice
            self.add(Callout("ok", f"KF2-VR {tag} is out", "Download it from the release page and extract it into a new folder.",
                             actions=(("Open release page", lambda: QDesktopServices.openUrl(QUrl(url)), "secondary"),)))
        if note:
            self.add(Callout("info", "Settings were reorganized",
                             "Your choices were kept. Reload styles are now Button, Manual and Realistic.",
                             actions=(("Review settings", lambda: (state.dismiss_upgrade_note(),
                                                                   self.window_.show_page("settings")), "secondary"),),
                             dismiss=lambda: (state.dismiss_upgrade_note(), self.rebuild())))
        # Status: game, headset and how you play.
        tiles = FlowGrid(min_column=200, max_columns=3)
        game_value = app.STORE_NAMES[install.store] if install \
            else "Choose a copy" if problem == "choose" else "Not found"
        tiles.add(self.tile("Game", "ok" if install else "warn", game_value, "game"))
        ready, runtime = state.headset()
        if state.vr:
            tiles.add(self.tile("Headset", "ok" if ready else "warn",
                                app.runtime_name(runtime) if ready else "Start your headset app", "headset"))
        else:
            tiles.add(self.tile("Headset", "off", "Not needed on desktop", None))
        mode = Card(padding=(T.S4, T.S3, T.S4, T.S3))
        mode.add(label("PLAY IN", "overline"))
        # "Play in VR | Desktop": short enough that the three status cards stay on one row at 900 px.
        choice = Segmented(((True, "VR"), (False, "Desktop")), state.vr, self.choose_mode,
                           tips={True: "Play in your headset with tracked hands.",
                                 False: "Play KF2-VR on your monitor, without a headset."})
        if epic:
            choice.buttons[False].setEnabled(False)
        mode.add(choice)
        if epic:
            mode.add(label("Epic plays in VR only.", "muted", wrap=True))
        elif not state.vr:
            mode.add(label("On your monitor, without a headset.", "muted", wrap=True))
        mode.layout_.addStretch(1)
        tiles.add(mode)
        self.add(tiles)
        if problem == "choose":
            box = Callout("warn", "Choose your game", "Pick the copy of Killing Floor 2 to play.")
            box.body.addWidget(store_cards(state.installs(), None, self.choose_install))
            self.add(box)
        elif problem == "missing":
            self.add(Callout("warn", "Killing Floor 2 wasn't found", app.GAME_MISSING,
                             actions=missing_game_actions(self.window_, lambda: (state.forget(), self.rebuild()))))
        running = state.session_running()
        why = "A game is already running" if running else "" if install else "Choose your game first"
        kind = state.last_kind()
        again = state.played_before() and not epic
        self.set_title("Play", "Play again in one click, or choose another match." if again else
                       "Quick start a solo match in one click, or choose another match.")
        self.column.addSpacing(T.S3)  # the status row and Quick start are separate groups
        import launcher_art
        hero = HeroFrame(launcher_art.wallpaper(getattr(state, "hero_game", None)))
        place, *rest = state.match_summary(kind).split("  ·  ")
        # Short windows (900x650, 1000x680) get a compact Quick start so Solo, Host and Join stay in view.
        compact = self.window_.height() < 760
        self.built_compact = compact
        title = label(place, "title")
        if compact:
            title.setStyleSheet(f"font-size: {T.H2 + 5}px;")
        text = vbox(label("PLAY AGAIN" if again else "QUICK START", "kicker"), title,
                    label("  ·  ".join(["Solo" if kind == "solo" else "Hosted"] + rest), "body"),
                    label(state.graphics_summary(), "muted"), spacing=T.S1 + 1)
        play = Button("Play solo" if kind == "solo" else "Host game", self.window_.quick_play, kind="primary", size="lg")
        play.setEnabled(not why)
        play.setMinimumWidth(180)
        action = vbox(play, spacing=T.S1)
        if why:
            action.addWidget(label(why, "muted"))
        layout = vbox(SplitRow(holder(text), holder(action), below=560),
                      margins=(T.S5, T.S3, T.S5, T.S3) if compact else (T.S6, T.S5, T.S6, T.S5))
        hero.setLayout(layout)
        self.add(hero)
        # The VAC line right under Quick start, where it is seen before playing (also at 900x650).
        from friends import launch_notices
        notices = launch_notices(state.store)
        if notices:
            note = hbox(spacing=T.S2, margins=(2, T.S2, 0, 0))
            note.addWidget(Mark("waiting", "i", 18), 0, Qt.AlignmentFlag.AlignTop)
            note.addWidget(label(" ".join(notices), "body", wrap=True), 1)
            self.add_layout(note)
        self._primary = self.window_.quick_play if not why else None
        self.primary_button = play
        self.add(section("Or choose a match"))
        cards = FlowGrid(min_column=200, max_columns=3)
        modes = (("Solo match", "Pick a map, difficulty and length.", lambda: self.window_.open_match("solo"), None),
                 ("Host a game", "Send friends a code to join your game.",
                  lambda: self.window_.open_match("host"), "Needs the Steam copy" if epic else None),
                 ("Join a friend", "Paste the code a friend sent you.", self.window_.open_join,
                  "Needs the Steam copy" if epic else None))
        for index, (title, line, command, blocked) in enumerate(modes):
            reason = blocked or why or None
            card = ArrowCard(clickable=not reason, padding=(T.S5, T.S4, T.S8 + 8, T.S4))
            heading = card.add(label(title, "h2"))
            if reason:
                heading.setStyleSheet(f"color: {T.TEXT_3};")
            card.add(label(line, "help", wrap=True))
            card.layout_.addStretch(1)
            if reason:
                card.set_disabled_look(True)
                card.add(label(reason, "muted"))
            else:
                card.clicked.connect(command)
            cards.add(card)
        self.add(cards)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        # Crossing the short-window size swaps the Quick start card between compact and full.
        if getattr(self, "built_compact", None) is not None and (self.window_.height() < 760) != self.built_compact:
            self.built_compact = None
            QTimer.singleShot(0, lambda: self.rebuild(keep_scroll=True))

    def tile(self, title, state, value, target):
        """A status tile; it opens its own part of Game & headset (target None: nothing to open)."""
        card = ArrowCard(clickable=target is not None, padding=(T.S4, T.S3, T.S8 + 4, T.S3))
        card.add(label(title.upper(), "overline"))
        line = hbox(Mark(state, size=20), label(value, "h3", wrap=True), spacing=T.S2)
        line.setStretch(1, 1)
        card.layout_.addLayout(line)
        card.layout_.addStretch(1)
        if target is not None:
            card.clicked.connect(lambda: self.window_.show_page("setup", focus=target))
        return card

    def choose_mode(self, value):
        self.state.vr = bool(value)
        self.rebuild(keep_scroll=True)

    def choose_install(self, install):
        self.state.use_install(install)
        self.window_.refresh_art()
        self.rebuild()

    def dismiss_welcome(self):
        self.welcome = False
        self.rebuild()


class MatchPage(Page):
    """The Solo or Host form."""
    nav = "Play"

    def __init__(self, window):
        super().__init__(window, "Solo match")
        self.kind, self.game, self.maps = "solo", None, []
        self.form = {}

    def prepare(self, kind="solo", game=None, maps=(), **_):
        self.built_for = (kind, game, list(maps), self.state.vr, self.state.store)
        self.kind, self.game = kind, game
        self.choices = app.map_choices(maps, self.state.stock_maps(game))
        self.maps = [stored for stored, _ in self.choices if not isinstance(stored, Heading)]
        self.form = self.state.match_defaults(kind, self.maps)
        self.errors = {}
        self.how_open = False
        self.folds = {"spawns"} if self.state.spawns_changed(self.form) else set()

    def build(self):
        state, solo, form = self.state, self.kind == "solo", self.form
        epic = state.store == "epic"
        self.set_title("Solo match" if solo else "Host a game",
                       "Pick your match, then start." if solo else "Friends join with a code you send them.")
        if epic:
            self.add(Callout("info", "", "Epic opens the game's own menu: choose the map, difficulty and length there."))
        self.match_panel()
        if not solo:
            # Everything about the server in one section: the one notice (the first download), then its rows.
            self.add(section("Server"))
            if not state.server_installed():
                self.add(Callout("warn", "First time hosting: a 9 GB download",
                                 "The first time you press Start hosting, KF2-VR downloads the free Killing Floor 2 "
                                 "server from Steam into the game server folder below. Only the host needs it."))
            panel = Panel()
            self.host_fields = {}
            for key, title, hint, secret in (("server_name", "Server name", "What friends see when they join.", False),
                                             ("password", "Password", "Leave it blank to let anyone with the code join.", True)):
                field = TextField(form.get(key, ""), "Optional" if secret else "", secret=secret, width=T.CONTROL_WIDTH + 40)
                row = SettingRow(title, hint, field)
                self.host_fields[key] = (field, row, hint)
                field.textChanged.connect(lambda text, key=key: (self.form.__setitem__(key, text), self.check_host()))
                panel.add(row)
            panel.add(self.server_folder_row())
            panel.add(self.ports_row())
            self.add(panel)
            self.add(section("Players"))
            panel = Panel()
            panel.add(self.switch_row("zed_grabs", model.BY_KEY["bZedGrabEnabled"].label, "Let VR players grab and throw Zeds."))
            panel.add(self.switch_row("gravity_grab", "Gravity grab", "Let VR players pull guns and pickups to their hand."))
            availability = form.get("availability")
            panel.add(self.switch_row("workshop_desktop", "Desktop players can join", {
                True: "Friends without a headset can join too.",
                None: "Friends without a headset can join if they have this KF2-VR version.",
                False: "Friends without a headset need the KF2-VR download."}[availability],
                enabled=availability is not False))
            self.add(panel)
        self.spawns(solo)
        if not solo:
            self.mods_section()
        if state.developer:
            self.developer_section(solo)
        no_xp = solo and state.spawns_changed(form)
        self.set_footer(back=lambda: self.window_.show_page("play"), primary=self.start,
                        primary_text="Start solo match" if solo else "Start hosting")
        if no_xp:
            self.reason.setText("No XP this match")
            set_tone(self.reason, "warn")
        if not solo:
            self.check_host()

    def check_host(self):
        """Server name and password are checked as they are typed: a problem shows under its field and holds
        Start hosting back, with the reason beside it."""
        fields = getattr(self, "host_fields", {})
        try:
            problems = self.state.host_problems(self.form)
        except RuntimeError:
            return
        for key, (field, row, hint) in fields.items():
            problem = problems.get(key, "")
            try:
                field.set_invalid(bool(problem))
                row.help.setText(problem or hint)
                set_tone(row.help, "warn" if problem else None)
            except RuntimeError:
                return  # a field of a page being rebuilt
        if self.primary_button is not None and self.map_chosen():
            bad = next((key for key in ("server_name", "password") if problems.get(key)), None)
            self.allow(bad is None, {"server_name": "Check the server name", "password": "Check the password"}.get(bad, ""))

    def match_panel(self):
        self.add(section("Match", top=T.S4))
        panel = Panel()
        maps = Dropdown(self.choices, self.form.get("map"), lambda value: self.pick("map", value),
                        width=T.CONTROL_WIDTH + 40, searchable=True)
        map_row = SettingRow("Map", f"{len(self.maps)} maps. Type a name to search.", maps)
        maps.searching.connect(lambda text, found, row=map_row: self.map_typed(row, text, found))
        maps.reverted.connect(lambda typed, kept, row=map_row: self.map_kept(row, typed, kept))
        self.map_box = maps
        panel.add(map_row)
        panel.add(SettingRow("Difficulty", "", self.dropdown("difficulty", app.DIFFICULTY_LABELS)))
        panel.add(SettingRow("Match length", "", self.dropdown("game_length", app.LENGTH_LABELS)))
        self.graphics = panel.add(graphics_row(self, self.refresh_graphics))
        self.add(panel)

    def refresh_graphics(self):
        """Graphics may change in Settings or the dialog; only their row needs redrawing."""
        index = self.graphics.parentWidget().layout().indexOf(self.graphics)
        fresh = graphics_row(self, self.refresh_graphics)
        self.graphics.parentWidget().layout().insertWidget(index, fresh)
        self.graphics.hide()
        self.graphics.deleteLater()
        self.graphics = fresh

    def pick(self, key, value, rebuild=False):
        """Every choice on the form is remembered at once, like the graphics, and Quick start uses it."""
        self.form[key] = value
        self.state.remember_match(self.kind, self.form)
        if rebuild:
            self.rebuild(keep_scroll=True)

    def reuse(self, kind="solo", game=None, maps=(), **_):
        """Opening the same form again shows it as it was left; only the graphics line is refreshed."""
        if (kind, game, list(maps), self.state.vr, self.state.store) != getattr(self, "built_for", None):
            return False
        self.refresh_graphics()
        return True

    def map_typed(self, row, text, found):
        """While the map box holds text that isn't a map, say so and hold Start back."""
        typed = text.strip()
        box = getattr(self, "map_box", None)
        matches = [name for name in box.names() if typed.casefold() in name.casefold()] if box is not None and typed else []
        if not found:
            hint = f"No map matches “{typed}”."
        elif typed and box is not None and typed.casefold() != box.chosen_text().casefold():
            hint = (f"{len(matches)} map{'s' if len(matches) != 1 else ''} match “{typed}”. Pick one from the list.")
        else:
            hint = f"{len(self.maps)} maps. Type a name to search."
        row.help.setText(hint)
        set_tone(row.help, None if found else "warn")
        chosen = self.map_chosen()
        self.allow(chosen, "Pick a map from the list")
        if chosen and self.kind != "solo":
            self.check_host()
        if chosen and self.reason is not None and self.kind == "solo" and self.state.spawns_changed(self.form):
            self.reason.setText("No XP this match")
            set_tone(self.reason, "warn")

    def map_kept(self, row, typed, kept):
        """Leaving the box with a name that isn't a map keeps the chosen one, and says so."""
        row.help.setText(f"No map is called “{typed}”, so {kept} stays chosen.")
        set_tone(row.help, "warn")

    def fold(self, key, title, summary):
        fold = Accordion(title, summary, opened=key in self.folds)
        fold.toggled.connect(lambda on, key=key: self.flip_fold(key, on))
        self.add(fold)
        return fold

    def flip_fold(self, key, on):
        """Redraw with the fold open or closed, so its rows are laid out at their real width."""
        self.folds.add(key) if on else self.folds.discard(key)
        self.rebuild(keep_scroll=True)

    def spawns(self, solo):
        """Zed spawns, folded away until changed; a Solo change says at once that the match earns no XP."""
        changed = self.state.spawns_changed(self.form)
        self.add(section("Optional"))
        fold = self.fold("spawns", "Zed spawns", "Changed" if changed else "Standard")
        panel = Panel()
        for key, title, _ in app.SPAWN_FIELDS:
            labels, _ = self.form["spawn_choices"][key]
            panel.add(SettingRow(title, "", self.dropdown(key, labels, rebuild=True)))
        fold.body_layout.addWidget(panel)
        if solo and changed:
            # The XP consequence only when it applies, and right where it was caused.
            self.add(Callout("warn", "This Solo match won't earn XP",
                             app.SOLO_XP + " Set all three back to Standard to earn XP again."))

    def server_folder_row(self):
        """Where the game server goes, with the free space there and a way to put it on another drive."""
        state = self.state
        installed = state.server_installed()
        drive, free = state.server_space()
        drive = drive.rstrip(".")
        # A zero-width space after each separator lets a long path wrap at a folder break.
        root = str(state.saved.server_root).replace("\\", "\\\u200b")
        if installed:
            where, tone = "Installed here", None
        elif free is None:
            where, tone = f"The server needs about 32 GB on {drive}", None
        elif free < 35:
            where, tone = f"Only {free:.0f} GB free on {drive}; the server needs about 32 GB. Choose another drive", "warn"
        else:
            where, tone = f"KF2-VR keeps it on your game's drive; {free:.0f} GB free on {drive}", None
        change = Button("Change folder…", lambda: self.window_.pick_server_folder(lambda: self.rebuild(keep_scroll=True)),
                        size="sm")
        change.setEnabled(not state.session_running())
        row = SettingRow("Game server folder", f"{root}\n{where}", change)
        if tone:
            set_tone(row.help, tone)
        return row

    def ports_row(self):
        """Port forwarding, as a row of the Server card: the how-to opens in place."""
        how = Button("Hide the steps" if self.how_open else "How to do it", None, size="sm")
        row = SettingRow("Friends on another network", "Friends on your home network can join right away; others may "
                         "need port forwarding.", how,
                         note="In your router, forward UDP ports 7777 and 27015 to this PC, and allow the game server "
                              "through Windows Firewall if asked.")
        row.note.setVisible(self.how_open)
        how.clicked.connect(lambda: self.flip_how(row.note, how))
        return row

    def flip_how(self, detail, how):
        self.how_open = not self.how_open
        detail.setVisible(self.how_open)
        how.setText("Hide the steps" if self.how_open else "How to do it")

    def map_chosen(self):
        """Whether the map box names a map (not half a search); the box of this build, never one being deleted."""
        box = getattr(self, "map_box", None)
        try:
            return box is None or box.lineEdit().text().strip().casefold() == box.chosen_text().casefold()
        except RuntimeError:
            return True

    def dropdown(self, key, options, rebuild=False):
        return Dropdown(options, self.form.get(key), lambda value: self.pick(key, value, rebuild),
                        width=T.CONTROL_WIDTH + 40)

    def switch_row(self, key, title, text, enabled=True):
        control = SwitchControl(bool(self.form.get(key)), lambda on, key=key: self.pick(key, on))
        control.setEnabled(enabled)
        return SettingRow(title, text, control)

    def mods_section(self):
        from workshop_loadout import MODS
        form = self.form
        needed = self.state.patch_needed(form)
        mods = set(form.get("mods", ()))
        loaded = len([key for key in MODS if key != "ukfp" and key in mods]) + (1 if needed or "ukfp" in mods else 0)
        fold = self.fold("mods", "Mods", f"{loaded} will load" if loaded else "None")
        panel = Panel()
        for key, (name, _, _) in MODS.items():
            on = key in mods or (key == "ukfp" and bool(needed))
            control = SwitchControl(on, lambda value, key=key: self.toggle_mod(key, value))
            locked = key == "ukfp" and bool(needed)
            control.setEnabled(not locked)
            if key in app.MOD_PAGES:
                page = Button("Workshop page", lambda url=app.MOD_PAGES[key]: QDesktopServices.openUrl(QUrl(url)), kind="link")
                page.setIcon(glyph("external", T.RED_TEXT, 12))
                control = holder(hbox(page, control, spacing=T.S4))
            # Every mod: a plain name, what it does, and its real Workshop name in small type under it.
            text = chr(10).join(part for part in (app.MOD_HELP.get(key, ""), f"Workshop mod: {name}") if part)
            row = SettingRow(app.MOD_NAMES.get(key, name), text, control, note=needed if locked else None)
            panel.add(row)
        fold.body_layout.addWidget(panel)

    def toggle_mod(self, key, on):
        mods = set(self.form.get("mods", ()))
        mods.add(key) if on else mods.discard(key)
        self.folds.add("mods")
        self.pick("mods", sorted(mods), rebuild=True)

    def developer_section(self, solo):
        state = self.state
        self.add(section("Developer (this launch only)"))
        panel = Panel()
        live = state.vr_live()
        for attribute, title, text in (("record_motion", "Replay recording", "Player motion and input."),
                                       ("highlight_events", "Highlight event logging", "Hits, kills and F9 video sync."),
                                       ("frame_timings", "Frame timings", "Written to native.log.")):
            control = SwitchControl(getattr(state, attribute), lambda on, attribute=attribute: setattr(state, attribute, on))
            control.setEnabled(live)
            panel.add(SettingRow(title, text, control))
        control = SwitchControl(self.form.get("local_test_control"), lambda on: self.form.__setitem__("local_test_control", on))
        control.setEnabled(solo and live)
        panel.add(SettingRow("Local agent test control", "Unranked; allows game console commands. Solo VR only. Not saved.",
                             control))
        control = SwitchControl(self.form.get("test_mode"), lambda on: self.form.__setitem__("test_mode", on))
        panel.add(SettingRow("Test mode", "Change perk any time and get every weapon of that perk. Unranked. Not saved.",
                             control))
        self.add(panel)

    def start(self):
        if not self.map_chosen():
            return  # Start is held back until the map box names a map
        try:
            arguments = self.state.match_arguments(self.kind, self.game, self.form)
        except PermissionError as error:
            self.window_.alert("Solo VR required", str(error))
            return
        except ValueError as error:
            self.errors = error.args[0]
            self.rebuild(keep_scroll=True)
            return
        self.errors = {}
        self.window_.run(arguments, "Solo match" if self.kind == "solo" else "Hosting")


class JoinPage(Page):
    nav = "Play"

    def __init__(self, window):
        super().__init__(window, "Join a friend", "Join with the code your friend sent, or with their address.")
        self.method, self.game = "code", None
        self.values = {"code": "", "address": "", "password": ""}

    def prepare(self, game=None, **_):
        self.game = game
        self.method = "code"
        self.values = {"code": "", "address": "", "password": ""}

    def field_block(self, title, hint, field, extra=None, key=None):
        """A field with its name and hint above it, and its own problem line under it; both methods look alike."""
        row = hbox(spacing=T.S1)
        row.addWidget(field, 1)
        if extra is not None:
            row.addWidget(extra)
        box = holder(row)
        row = hbox(spacing=0)
        row.addWidget(box, 1)
        row.addStretch(0)
        problem = label("", "help", "warn", wrap=True)
        problem.hide()
        self.problems[key or title] = problem
        parts = [label(title, "h3")] + ([label(hint, "help", wrap=True)] if hint else []) + [row, problem]
        return holder(vbox(*parts, spacing=T.S1 + 2, margins=(T.S5, T.S4, T.S5, T.S4)))

    def build(self):
        self.problems = {}
        self.pasted = False
        self.add(section("Join with", top=T.S2))
        self.add(Segmented((("code", "Join code"), ("address", "Address")), self.method, self.choose))
        panel = Panel()
        if self.method == "code":
            field = TextField(self.values["code"], "The whole code from their message", clearable=True)
            field.textChanged.connect(lambda text: self.edit("code", text))
            field.editingFinished.connect(lambda: self.check(finished=True))
            field.returnPressed.connect(self.go_primary)
            panel.add(self.field_block("Your friend's code", "", field,
                                       Button("Paste", self.paste), key="code"))
            self.field = field
        else:
            for key, title, hint, secret, placeholder in (
                    ("address", "Your friend's address", "Their IP address or computer name, and a port only if they gave one.",
                     False,
                     "for example 203.0.113.7"),
                    ("password", "Password", "Leave it blank if their game has none.", True, "Optional")):
                field = TextField(self.values[key], placeholder, secret=secret, clearable=not secret)
                field.textChanged.connect(lambda text, key=key: self.edit(key, text))
                field.returnPressed.connect(self.go_primary)
                panel.add(self.field_block(title, hint, field, key=key))
                if key == "address":
                    self.field = field
        self.add(panel)
        # The graphics every match uses: its own card, not part of the code or address.
        graphics = Panel()
        graphics.add(graphics_row(self, lambda: self.rebuild(keep_scroll=True)))
        self.add(graphics)
        self.set_footer(back=lambda: self.window_.show_page("play"), primary=self.start, primary_text="Join", enabled=False)
        self.check()
        QTimer.singleShot(0, self.field.setFocus)

    def choose(self, method):
        self.method = method
        self.rebuild()

    def edit(self, key, text):
        self.values[key] = text
        self.check()

    def say(self, text, tone=None, key="code"):
        line = self.problems.get(key)
        if line is None:
            return  # a field from the other join method, already gone
        line.setText(text)
        line.setVisible(bool(text))
        set_tone(line, tone)

    def check(self, finished=False):
        """What's wrong goes under its field, for code and address alike; the footer says what's still missing."""
        state = self.state
        if not hasattr(self, "problems") or (self.method == "code") != ("code" in self.problems):
            return  # the page is being rebuilt for the other method
        if self.method == "code":
            code = self.values["code"].strip()
            kind, text = state.join_code_state(code, state.build)
            if kind == "ok":
                self.say("✓  " + text, "ok")
            elif kind == "bad":
                self.say(text, "warn")  # said under the field, as an address problem is
            else:
                self.say("")
            self.allow(kind == "ok", "Add your friend's code first" if kind == "empty" else "Check the code")
        else:
            address = self.values["address"].strip()
            problems = state.address_problems(self.values["address"], self.values["password"])
            self.say(problems.get("address", "") if address else "", "warn", key="address")
            self.say(problems.get("password", ""), "warn", key="password")
            self.allow(bool(address) and not problems, "Enter your friend's address first" if not address
                       else "Check the address" if "address" in problems else "Check the password")

    def paste(self):
        text = QGuiApplication.clipboard().text().strip()
        if not text:
            self.say("Nothing is copied yet.", "warn")
            return
        self.pasted = True
        self.field.setText(text)

    def start(self):
        arguments = self.state.join_arguments(self.game, self.method, **self.values)
        if arguments:
            self.window_.run(arguments, "Joining")


# ----- session ---------------------------------------------------------------------------
class StepStrip(QWidget):
    def __init__(self):
        super().__init__()
        self.layout_ = hbox(spacing=0)
        self.setLayout(self.layout_)

    def show_steps(self, steps):
        """Numbered marks joined by a line, each with its step written underneath."""
        clear(self.layout_)
        for index, (step, state) in enumerate(steps):
            column = QWidget()
            column.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
            top = hbox(spacing=0)
            left, right = QFrame(), QFrame()
            for line, lit in ((left, index and state in ("done", "active")), (right, state == "done")):
                line.setFixedHeight(2)
                line.setStyleSheet(f"background: {T.GREEN if lit else T.LINE_STRONG};")
            # The first and last steps keep the line only on their inner side.
            left.setStyleSheet(left.styleSheet() if index else "background: transparent;")
            right.setStyleSheet(right.styleSheet() if index < len(steps) - 1 else "background: transparent;")
            top.addWidget(left, 1)
            top.addWidget(Mark(state, "" if state == "done" else str(index + 1), 26))
            top.addWidget(right, 1)
            text = label(app.events.PHASE_TEXT[step], "help" if state == "waiting" else "h3", wrap=True)
            text.setAlignment(Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignTop)
            if state == "waiting":
                text.setStyleSheet(f"color: {T.TEXT_3};")
            column.setLayout(vbox(top, text, spacing=T.S2))
            self.layout_.addWidget(column, 1)


class SessionPage(Page):
    nav = "Session"

    def __init__(self, window):
        super().__init__(window, "Session", scroll=True)
        self.details_open = False

    def build(self):
        session = self.state.session
        self.set_title(session.title, "In VR" if self.state.vr else "On desktop")
        self.steps = StepStrip()
        self.add(self.steps)
        self.status = label(session.guidance(), "h2", wrap=True)
        self.status.setContentsMargins(0, T.S5, 0, T.S1)
        self.add(self.status)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setTextVisible(False)
        self.add(self.progress)
        self.problem = label("", "body", wrap=True)
        self.problem.hide()
        self.add(self.problem)
        self.code_holder = vbox(spacing=T.S2)
        self.add_layout(self.code_holder)
        self.details_button = Button("Show details", self.flip_details, size="sm")
        self.add(self.details_button)
        self.details = QPlainTextEdit()
        self.details.setReadOnly(True)
        self.details.setMinimumHeight(220)
        self.details.setVisible(self.details_open)
        self.add(self.details)
        self.shown_code = self.shown_epic = False
        self.update_view({"phase", "join_code", "epic_options"} | ({"finished"} if session.finished else set()))

    def flip_details(self):
        self.details_open = not self.details_open
        self.details.setVisible(self.details_open)
        self.details_button.setText("Hide details" if self.details_open else "Show details")
        self.refresh_log()

    def refresh_log(self):
        if self.details_open:
            text = self.state.session.log_text()
            if text != self.details.toPlainText():
                self.details.setPlainText(text)
                self.details.verticalScrollBar().setValue(self.details.verticalScrollBar().maximum())

    def update_view(self, changed):
        session = self.state.session
        self.steps.show_steps(session.steps())
        if "phase" in changed and not session.finished:
            self.status.setText(session.guidance())
        if "join_code" in changed and session.join_code and not self.shown_code:
            self.shown_code = True
            self.show_join_code(None if session.join_code == "none" else session.join_code)
        if "epic_options" in changed and session.epic_options and not self.shown_epic:
            self.shown_epic = True
            self.show_epic_options()
        percent = session.download_percent()
        if percent is not None:
            self.progress.setRange(0, 100)
            self.progress.setValue(int(percent))
        self.refresh_log()
        if session.finished:
            self.finish()

    def show_join_code(self, code):
        box = QFrame()
        box.setObjectName("CodeBox")
        lines = vbox(label("CODE FOR YOUR FRIENDS", "kicker"),
                     label("Send it privately: it includes your game's password.", "help"),
                     spacing=T.S1 + 2, margins=(T.S5, T.S4, T.S5, T.S4))
        if not code:
            lines.addWidget(label("KF2-VR couldn't find your internet address, so there's no code this time. "
                                  f"Press {app.REPORT_BUTTON} on the Help page.", "body", wrap=True))
        else:
            field = QLineEdit(code)
            field.setReadOnly(True)
            field.setStyleSheet('font-family: "Cascadia Mono", "Consolas"; font-size: 14px;')
            copied = label("", "help", "ok")
            copy = Button("Copy code", lambda: (QGuiApplication.clipboard().setText(code),
                                                copied.setText("Copied. Send it to your friends in a private message.")),
                          kind="primary", size="sm")
            lines.addWidget(field)
            lines.addLayout(hbox(copy, copied, None, spacing=T.S3))
            lines.addWidget(label("Friends on another network also need UDP ports 7777 and 27015 forwarded to this PC.",
                                  "muted", wrap=True))
        box.setLayout(lines)
        self.code_holder.addWidget(box)

    def show_epic_options(self):
        session = self.state.session
        self.status.setText("Copy the line below into Epic > Library > Killing Floor 2 > Manage > Launch Options, "
                            "turn the switch on, and press Launch in Epic within five minutes.")
        text = QPlainTextEdit(session.epic_options)
        text.setReadOnly(True)
        text.setFixedHeight(90)
        self.epic_text = text
        self.code_holder.addWidget(text)
        copy = Button("Copy launch options", lambda: QGuiApplication.clipboard().setText(session.epic_options),
                      kind="primary", size="sm")
        self.code_holder.addLayout(hbox(copy, None))
        self.code_holder.addWidget(label("Save your old Launch Options first, keep this window open, and put them back "
                                         "after you quit.", "help", "warn", wrap=True))

    def finish(self):
        session = self.state.session
        self.progress.setRange(0, 100)
        self.progress.setValue(100)
        # A finished host's code no longer works; don't leave it up to be shared.
        clear(self.code_holder)
        if session.succeeded:
            self.status.setText("Done. In Epic, put your previous Launch Options back before you play normally."
                                if session.epic_options else "All done. Killing Floor 2 is back to normal.")
            set_tone(self.status, "ok")
            self.set_footer(primary=lambda: self.window_.show_page("play"), primary_text="Back to Play")
        else:
            self.progress.hide()
            self.status.setText("Something went wrong")
            set_tone(self.status, "error")
            text = session.problem()
            if app.REPORT_BUTTON.lower() not in text.lower():
                text += f" If it keeps happening, press {app.REPORT_BUTTON}."
            self.problem.setText(text)
            self.problem.show()
            self.set_footer(back=lambda: self.window_.show_page("play"), primary=self.window_.send_logs,
                            primary_text=app.REPORT_BUTTON)


# ----- setup and help ----------------------------------------------------------------------
class SetupPage(Page):
    nav = app.SETUP_NAV

    def __init__(self, window):
        super().__init__(window, app.SETUP_NAV, "Your copy of the game and your headset, plus first-time setup, updates "
                         "and resets.")
        self.checked = False
        self.focus = None

    def prepare(self, focus=None, **_):
        self.focus = focus

    def rebuild(self, keep_scroll=False):
        super().rebuild(keep_scroll)
        anchor = self.anchors.get(self.focus) if self.focus else None
        self.focus = None
        if anchor is not None and self.scroller is not None:
            # Opened from a Play tile: that part starts at the top of the page.
            bar = self.scroller.verticalScrollBar()
            QTimer.singleShot(0, lambda: bar.setValue(max(0, anchor.mapTo(self.scroller.widget(), anchor.rect().topLeft()).y() - T.S2)))

    def build(self):
        state = self.state
        running = state.session_running()
        # During the first launch first-time setup is a step in the sidebar, not a section here.
        # During the first launch only what applies yet: the game copy and the headset check.
        self.set_title(app.SETUP_NAV, "Your copy of the game and your headset." if state.onboarding
                       else "Your copy of the game and your headset, plus first-time setup, updates and resets.")
        self.anchors = {}
        self.anchors["game"] = self.add(section("Game", top=T.S2))
        found = state.installs()
        install, problem = state.resolve_game()
        if len(found) > 1:
            self.add(store_cards(found, install, self.choose))
        elif install:
            self.add(status_row(True, f"Killing Floor 2 on {app.STORE_NAMES[install.store]}"
                                + (" (experimental: Solo in VR only)" if install.store == "epic" else ""), str(install.root)))
        else:
            self.add(Callout("warn", "Killing Floor 2 wasn't found", app.GAME_MISSING,
                             actions=missing_game_actions(self.window_, self.check_again)))
        if install is not None or len(found) > 1:
            self.add_layout(hbox(Button(app.OTHER_FOLDER, lambda: self.window_.pick_game_folder(self.rebuild),
                                        size="sm"), None, margins=(0, T.S2, 0, 0)))
        if install is not None and install.store == "epic":
            self.add(Callout("info", "", app.EPIC_LIMITS))
        self.anchors["headset"] = self.add(section("Headset"))
        ready, runtime = state.headset()
        panel = Panel()
        # One Check again per page: with the game missing, the game card's Check again looks for both.
        again = holder(hbox(label("Checked just now" if self.checked else "", "muted"),
                            Button("Check again", self.check_again, size="sm"), spacing=T.S3)) \
            if install is not None or len(found) > 1 else None
        panel.add(SettingRow(f"Ready: {app.runtime_name(runtime)}" if ready else "No headset app is running",
                             app.HEADSET_READY if ready else app.HEADSET_MISSING, again))
        if not state.onboarding:
            # Voice chat goes through the headset's mic: its one setting sits here, not on a Settings tab.
            state.refresh_player_preferences()
            panel.add(setting_row(model.BY_KEY["LastMicMode"], state.settings_values,
                                  lambda chosen: self.persist({"LastMicMode": chosen}), running)[0])
        self.add(panel)
        if state.onboarding:
            return
        if not state.onboarding:
            # Offered again only once it has run: during the first launch the steps in the sidebar lead to it.
            self.add(section("First-time setup"))
            panel = Panel()
            # Re-running setup leaves every choice as it is until you pick another.
            start = Button("Open", lambda: (setattr(state, "setup_touched", set()),
                                            self.window_.show_page("first-time", origin="setup")), size="sm")
            start.setEnabled(not running)
            panel.add(SettingRow("Run first-time setup again",
                                 "Hand, seated mode, movement, turning, reloads and graphics on one page.", start))
            self.add(panel)
        self.add(section("Updates"))
        panel = Panel()
        panel.add(SettingRow("Check for updates", "Tells you when a newer KF2-VR is out; nothing installs by itself.",
                             SwitchControl(state.update_check_enabled(), state.set_update_check)))
        status, tone = self.window_.update_status_text()
        now = Button("Check now", lambda: self.window_.check_updates_now(), size="sm")
        now.setEnabled(not self.window_.update_checking)
        row = SettingRow(f"You have KF2-VR {app.version_text(state.version)}", status, now)
        set_tone(row.help, tone)
        panel.add(row)
        self.add(panel)
        self.add(section("Reset"))
        panel = Panel()
        reset = Button("Reset…", self.reset, kind="danger", size="sm")
        reset.setEnabled(not running)
        panel.add(SettingRow("Reset all settings", "Puts every setting back to its default. Kept: your calibration, "
                             "saved matches, game copy and host details.", reset))
        self.add(panel)
        if state.developer:
            self.add(section("Developer"))
            panel = Panel()
            panel.add(SettingRow("Developer tools", "Recording, highlight logging and frame timings for this launch.",
                                 Button("Open", lambda: self.window_.show_page("developer"), size="sm")))
            self.add(panel)

    def persist(self, edits):
        ok, problem = self.state.persist(edits)
        if not ok:
            self.window_.save_failed(problem)
        self.rebuild(keep_scroll=True)

    def check_again(self):
        self.state.forget()
        self.checked = True
        self.rebuild(keep_scroll=True)

    def choose(self, install):
        self.state.use_install(install)
        self.window_.refresh_art()
        self.rebuild(keep_scroll=True)

    def reset(self):
        if self.state.session_running() or not self.window_.ask(
                "Reset all settings?", "This puts every setting back to its default.", yes="Reset",
                danger=True, detail=self.state.reset_note()):
            return
        ok, problem = self.state.reset()
        if not ok:
            self.window_.save_failed(problem)
        else:
            self.window_.saved_feedback()
        self.rebuild(keep_scroll=True)


class DeveloperPage(Page):
    nav = app.SETUP_NAV

    def __init__(self, window):
        super().__init__(window, "Developer", "This launch only.")

    def build(self):
        state = self.state
        panel = Panel()
        for attribute, title, text in (("record_motion", "Replay recording", "Player motion and input."),
                                       ("highlight_events", "Highlight event logging", "Hits, kills and F9 video sync."),
                                       ("frame_timings", "Frame timings", "Written to native.log.")):
            panel.add(SettingRow(title, text, SwitchControl(getattr(state, attribute),
                                                            lambda on, attribute=attribute: setattr(state, attribute, on))))
        self.add(panel)
        self.add(label("VR only. Local files; no video, audio or automatic sharing. Never saved: every new window starts "
                       "with these off. Local agent test control is on the Solo page.", "muted", wrap=True))
        if state.context.workspace:
            self.add(section("Checkout"))
            self.add(label(f"Workspace: {state.context.workspace}\nSelected build: {state.build}"
                           + ("\nThis build is older than the source (allowed for this window)." if state.context.stale else ""),
                           "muted", wrap=True, selectable=True))
        self.set_footer(back=lambda: self.window_.show_page("setup"))


class HelpPage(Page):
    nav = "Help"

    def __init__(self, window):
        super().__init__(window, "Help", "Getting started, playing with friends, and what to do when something goes wrong.")

    def build(self):
        state = self.state
        self.add(section("Getting started", top=T.S2))
        steps = Panel()
        for index, text in enumerate((
                "Start your headset's PC app: SteamVR, Quest Link or Virtual Desktop.",
                "Press Play solo, or choose a match. (Play opens once first-time setup is done.)" if state.onboarding
                else "On the Play page, press Play solo or choose a match.",
                f"In the game, open {app.VR_MENU} to tune feel and fit. " + app.HEADSET_MENU), 1):
            row = hbox(spacing=T.S3, margins=(T.S5, T.S3 + 2, T.S5, T.S3 + 2))
            row.addWidget(Mark("waiting", str(index), 22), 0, Qt.AlignmentFlag.AlignTop)
            row.addWidget(label(text, "body", wrap=True), 1)
            steps.add(holder(row))
        self.add(steps)
        # Every Help section is a card, like the others on this page.
        for title, text in (("The in-game VR menu", "It has the same comfort, hands and graphics settings as Settings "
                             "here, plus snap angle, turn speed, height and hand fit."),
                            ("Playing with friends", "Host a game and send friends its code; they press Join a friend "
                             "and paste it. You all need the same KF2-VR version.")):
            self.add(section(title))
            card = Panel()
            card.add(holder(vbox(label(text, "body", wrap=True), margins=(T.S5, T.S4, T.S5, T.S4))))
            self.add(card)
        self.add(section("If something goes wrong"))
        panel = Panel()
        for title, text in (
                ("The game opens on the monitor, not in the headset",
                 f"Start your headset app before you press Play. {app.SETUP_NAV} shows the headset app KF2-VR found; "
                 "press Check again there after starting it."),
                ("Friends can't join", "You all need the same KF2-VR version. Friends on another network may need "
                 "port forwarding: Host a game says how."),
                ("The game won't start after a crash", "Use Repair below, then press Play again.")):
            panel.add(SettingRow(title, text, None))
        self.add(panel)
        self.add(section("Repair and bug reports"))
        panel = Panel()
        for title, text, button, command, kind in (
                ("Repair after a crash", "If the game crashed or was closed from Task Manager, this puts Killing "
                 "Floor 2 back to normal and keeps your settings. Close the game first.", "Repair",
                 self.window_.recover, "secondary"),
                (app.REPORT_BUTTON, "Asks where to save, then saves a ZIP of your logs with personal details removed and "
                 "opens its folder.",
                 "Save logs", self.window_.send_logs, "secondary"),
                ("Report a bug", "Opens the KF2-VR thread on the Flat2VR Discord; attach your logs and say what happened.",
                 "Report a bug", lambda: QDesktopServices.openUrl(QUrl(app.ISSUES_URL)), "secondary"),
                ("Logs folder", "The raw logs on this PC; they aren't anonymized, so keep them private.", "Open folder",
                 self.window_.open_logs, "secondary")):
            action = Button(button, command, kind=kind, size="sm")
            action.setFixedWidth(150)
            if title == "Report a bug":
                action.setIcon(glyph("external", T.TEXT, 14))
            panel.add(SettingRow(title, text, action))
        self.add(panel)
        self.add(section("About"))
        about = Panel()
        lines = vbox(label(f"KF2-VR {app.version_text(state.version)}", "h3"), label(app.CREDITS, "body"),
                     label("Epic Games support is experimental: Solo in VR only.", "help"),
                     label(app.DISCLAIMER, "muted", wrap=True), spacing=T.S1 + 2, margins=(T.S5, T.S4, T.S5, T.S4))
        if state.developer:
            lines.addWidget(label("Build " + state.build, "muted", selectable=True))
        about.add(holder(lines))
        self.add(about)



# ----- dialogs ------------------------------------------------------------------------------
class GraphicsDialog(Dialog):
    """Graphics preset, render scale and DLSS, changed without leaving a match form; the same controls as Settings."""

    def __init__(self, window):
        super().__init__(window, "Graphics", "These apply to every match, and save as you choose. More options are in "
                         "Settings › Graphics & HUD.",
                         (("Done", True, "primary"),), width=820)
        self.window_ = window
        self.state = window.state
        self.holder = vbox(spacing=0)
        self.extra.addLayout(self.holder)
        self.fill()

    def fill(self):
        clear(self.holder)
        state = self.state
        values = state.settings_values
        running = state.session_running()
        panel = Panel()
        # The same rows as Settings and first-time setup.
        panel.add(preset_row("graphics_preset", values, self.choose_preset, running, graphics_pick_line())[0])
        for key in ("eye_render_percent", "dlss"):
            panel.add(setting_row(model.BY_KEY[key], values, lambda value, key=key: self.save({key: value}), running)[0])
        self.holder.addWidget(panel)
        self.fit()

    def choose_preset(self, name):
        lines = self.state.preset_change_lines("graphics_preset", name)
        if lines and not self.window_.ask(f"Use Graphics preset: {name}?", "This replaces the values you changed by hand.",
                                          yes=f"Use {name}", detail="\n".join(lines[:8])):
            self.fill()
            return
        ok, problem = self.state.apply_preset("graphics_preset", name)
        if not ok:
            self.window_.save_failed(problem)
        self.fill()

    def save(self, edits):
        ok, problem = self.state.persist(edits)
        if not ok:
            self.window_.save_failed(problem)
        self.fill()

    def fit(self):
        self.setMinimumHeight(0)
        self.setMaximumHeight(16777215)
        super().fit()


class ControlsDialog(Dialog):
    """What each controller button does with the current settings."""

    def __init__(self, window):
        values = window.state.settings_values
        dominant = int(values["PreferredWeaponHand"])
        movement = int(values["MovementHand"])
        grip = model.preset_name("grip_mode", values)
        reload_mode = model.preset_name("reload_mode", values)
        super().__init__(window, "Your controls",
                         f"With your current settings: {'left' if dominant == 0 else 'right'}-handed, grip mode {grip}, "
                         f"reload mode {reload_mode}.", (("Done", True, "primary"),), width=720)
        # A card per hand (what only that hand does: its stick per the movement hand, the menu button on the
        # left), then what both hands do; one name column, so all three line up.
        for hand in (0, 1):
            card = Card(padding=(T.S4, T.S3, T.S4, T.S3))
            head = "LEFT HAND" if hand == 0 else "RIGHT HAND"
            card.add(label(head + ("  ·  GUN HAND" if hand == dominant else "  ·  MOVEMENT HAND" if hand == movement
                                   else ""), "kicker"))
            stick = ("Move. Click it to sprint." if hand == movement else
                     "Turn." + (" Pull down to crouch." if values["bStickCrouch"] else ""))
            card.layout_.addLayout(self.row("Stick", stick))
            if hand == 0:
                card.layout_.addLayout(self.row("Menu button", f"Open {app.VR_MENU}."))
            self.extra.addWidget(card)
        if reload_mode == "Button":
            reload_text = "Reload the gun in that hand."
        elif reload_mode == "Realistic":
            reload_text = "Eject the mag from the gun in that hand; you rack it yourself."
        else:
            reload_text = "Eject the mag from the gun in that hand; an empty trigger also starts a reload."
        both = Card(padding=(T.S4, T.S3, T.S4, T.S3))
        both.add(label("BOTH HANDS", "kicker"))
        for name, text in (("Trigger", "Fire the gun in that hand, or pick a menu item."),
                           ("Grip", "Grab gear or brace a gun; at your chest, take a grenade and let go to throw."
                            + (" Point an open hand at a pickup and flick to pull it to you." if values["bDisableGravityPull"] else "")),
                           ("Lower button", reload_text + " Hold it to change fire mode. (X or A on Quest.)"),
                           ("Upper button", "Open that hand's weapon wheel. (Y or B on Quest.)"),
                           ("Both sticks", f"Press and hold both to open {app.VR_MENU}.")):
            both.layout_.addLayout(self.row(name, text))
        self.extra.addWidget(both)

    @staticmethod
    def row(name, text):
        key = label(name, "h3")
        key.setFixedWidth(120)
        return hbox(key, label(text, "body", wrap=True), spacing=T.S3, margins=(0, 3, 0, 3))

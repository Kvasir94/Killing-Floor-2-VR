"""Settings: one tab per category, presets and everyday rows first, then Customize groups, and search.

Every row comes from tools/settings-definition.json and saves as soon as it changes. Rows that
don't apply are hidden; a hidden preset or group leaves one line saying when it shows, and
search still finds hidden rows, greyed with what turns them on (Rulings 2026-11-04). Each
setting uses the same control here as on first-time setup and in the dialogs (setting_control).
"""
import re

from PySide6.QtCore import QTimer, Qt
from PySide6.QtWidgets import QPushButton, QSizePolicy

import launcher_app as app
import launcher_settings as model
import launcher_ui_theme as T
from launcher_ui_pages import (ControlsDialog, graphics_pick_line, preset_control, preset_line, setting_control,
                               setting_help)
from launcher_ui_widgets import (SplitRow, Button, Callout, Page, Panel, SettingRow, Stepper, TextField, hbox, holder,
                                 label, section, set_tone, vbox)

# Help shared by this many rows of a group is said once for the group instead.
SHARED_HELP = 3


def pick_text(when):
    """ "with teleport movement" -> "teleport movement"; "with the laser sight on" -> "the laser sight on"."""
    return when.removeprefix("with ").strip() or "other options"


# Words players use for what only the in-game VR menu can do; search points them to its page.
HANDS_FIT = ("Hands & Weapons", "Calibrate hands, gun, pouch, grenade")
MENU_FIT = ("Graphics & HUD", "Calibrate menu position")
HEADSET_TOPICS = (("hand fit", "Hand and gun fit", HANDS_FIT), ("fit", "Hand and gun fit", HANDS_FIT),
                  ("calibrat", "Calibrate height", ("Comfort", "")), ("calibrat", "Calibrate hands, gun, pouch, grenade", HANDS_FIT),
                  ("calibrat", "Calibrate menu, watch & ammo counter", MENU_FIT),
                  ("height", "Calibrate height", ("Comfort", "")), ("snap", "Snap angle", ("Comfort", "")),
                  ("turn speed", "Turn speed", ("Comfort", "")), ("menu position", "Menu position", MENU_FIT),
                  ("watch", "Watch position", MENU_FIT))


# Audio's one launcher row (Microphone) is about the headset's mic: it sits with the headset check on
# Game & headset, not on a tab of its own (the in-game VR menu keeps its Audio page).
ELSEWHERE_PAGE = {"Audio": (app.SETUP_NAV, "Headset")}
TABS = tuple(tab for tab in model.TABS if tab not in ELSEWHERE_PAGE)
ESSENTIALS = "Essentials"


def tab_of(category):
    return category if category in TABS else TABS[0]


def shown_tab(entry):
    """The launcher tab a definition row shows on: its own category's, unless it sits beside a related row."""
    return entry.get("launcher_tab") or entry["category"]


def tab_rows(tab):
    """The definition's rows for a launcher tab, in the definition's order. A group with a single launcher
    row (Stick crouch, Melee hit stop) joins the tab's Essentials: a group heading over one row reads as
    unfinished. Groups whose rows show only with another option (Teleport) keep their heading."""
    rows = [entry for entry in model.PAGE_ROWS if shown_tab(entry) == tab]
    sizes = {}
    for entry in rows:
        if entry.get("depth") == "customize" and entry.get("group"):
            sizes[entry["group"]] = sizes.get(entry["group"], 0) + 1
    return [dict(entry, depth="everyday", group="") if sizes.get(entry.get("group")) == 1
            and not entry.get("requires") else entry for entry in rows]




def when_text(reason):
    """ "Only with teleport movement" or "show with Manual reloads" -> "with teleport movement"."""
    return re.sub(r"^(show|shows|only)\s+", "", reason or "", flags=re.I) or "with other choices"


class SettingsPage(Page):
    nav = "Settings"

    def __init__(self, window):
        super().__init__(window, "Settings", "Changes save automatically. ★ marks our recommendation.")
        # A returning player comes back to the tab they left (launcher.json settings_tab).
        remembered = app._preferences().get("settings_tab")
        self.tab = remembered if remembered in TABS else TABS[0]
        self.query = ""
        tabs = hbox(spacing=0)
        self.tabs = {}
        for category in TABS:
            button = QPushButton(category.replace("&", "&&"))
            button.setProperty("tab", "true")
            button.setCheckable(True)
            button.setCursor(Qt.CursorShape.PointingHandCursor)
            button.setFocusPolicy(Qt.FocusPolicy.TabFocus)
            button.clicked.connect(lambda checked=False, category=category: self.show_tab(category))
            tabs.addWidget(button)
            self.tabs[category] = button
        tabs.addStretch(1)
        self.search = TextField("", "Search settings", clearable=True, search=True)
        self.search.setMinimumWidth(200)
        self.search.setMaximumWidth(280)
        self.search.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.search.textChanged.connect(self.searched)
        self.search.returnPressed.connect(lambda: self.rebuild())
        # Tabs and search share one row while both fit (900 px windows too); only narrower stacks them.
        strip = holder(tabs)
        bar = hbox(SplitRow(strip, self.search, below=strip.sizeHint().width() + 200 + T.S4 + 4, spacing=T.S4),
                   spacing=0)
        self.saved_label = label("", "help", "ok")
        self.title_row.addWidget(self.saved_label, 0, Qt.AlignmentFlag.AlignBottom)
        self.header_extra.addSpacing(T.S4)
        self.header_extra.addLayout(bar)
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.setInterval(160)
        self._timer.timeout.connect(lambda: self.rebuild())
        self._fade = QTimer(self)
        self._fade.setSingleShot(True)
        self._fade.timeout.connect(lambda: self.saved_label.setText(""))
        self.focus_key = None

    def prepare(self, tab=None, **_):
        if tab_of(tab) in TABS:
            self.tab = tab_of(tab)
        if self.search.text():
            self.search.blockSignals(True)
            self.search.clear()
            self.search.blockSignals(False)
            self.query = ""

    # ----- navigation -------------------------------------------------------------
    def show_tab(self, category):
        if category != self.tab:
            app._update_preferences({"settings_tab": category})
        self.tab = category
        self.saved_label.setText("")
        if self.search.text():
            self.search.blockSignals(True)
            self.search.clear()
            self.search.blockSignals(False)
        self.query = ""
        self.rebuild()

    def searched(self, text):
        self.query = text.strip()
        self._timer.start()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape and self.search.text():
            self.search.clear()
            return
        super().keyPressEvent(event)

    # ----- saving -------------------------------------------------------------------
    def flash(self, text="✓  Saved", tone="ok"):
        self.saved_label.setText(text)
        set_tone(self.saved_label, tone)
        self._fade.start(2600)

    def commit(self, edits, key=None, rebuild=True):
        state = self.state
        ok, problem = state.persist(state.with_mirroring(edits))
        if not ok:
            self.flash("Locked while a game runs" if problem == "running" else "Not saved", "warn")
            if problem != "running":
                self.window_.alert("Couldn't save settings", problem)
            self.rebuild(keep_scroll=True)
            return False
        self.flash()
        if rebuild:
            self.focus_key = key
            self.rebuild(keep_scroll=True)
        return True

    def choose_preset(self, preset, name):
        if name not in model.preset_targets(preset) or model.preset_name(preset, self.state.settings_values) == name:
            return
        lines = self.state.preset_change_lines(preset, name)
        if lines and not self.window_.ask(f"Use {model.PRESET_DEFS[preset]['label']}: {name}?",
                                          "This replaces the values you changed by hand.", yes=f"Use {name}",
                                          detail="\n".join(lines[:8] + ([f"and {len(lines) - 8} more"] if len(lines) > 8 else []))):
            self.rebuild(keep_scroll=True)
            return
        ok, problem = self.state.apply_preset(preset, name)
        if ok:
            self.flash()
        else:
            self.flash("Not saved", "warn")
            if problem != "running":
                self.window_.alert("Couldn't save settings", problem)
        self.focus_key = "preset:" + preset
        self.rebuild(keep_scroll=True)

    def reset(self):
        category = self.tab
        if self.state.session_running() or not self.window_.ask(
                f"Reset {category}?", f"This puts {category} back to the defaults.", yes="Reset", danger=True,
                detail=self.state.reset_note(category) or None):
            return
        # The tab's rows as shown: Movement hand resets with Hands & Weapons, where it sits.
        keys = {entry["key"] for entry in model.DEFINITION["settings"]
                if entry.get("key") in model.BY_KEY and shown_tab(entry) == category}
        ok, problem = self.state.persist({key: value for key, value in model.defaults().items() if key in keys})
        self.flash() if ok else self.flash("Not saved", "warn")
        self.rebuild(keep_scroll=True)

    # ----- page ---------------------------------------------------------------------
    def rebuild(self, keep_scroll=False):
        """A pick that reveals a group (Teleport, Manual reloads) scrolls it into view, so the change shows
        where the player is looking instead of at the foot of the page."""
        before = (self.tab, self.query, set(getattr(self, "group_headings", {})))
        super().rebuild(keep_scroll)
        tab, query, groups = before
        new = [group for group in self.group_headings if group not in groups]
        if keep_scroll and groups and new and tab == self.tab and not query and not self.query and self.scroller:
            heading = self.group_headings[new[0]]
            QTimer.singleShot(0, lambda: self.reveal(heading))

    def reveal(self, heading):
        try:
            self.scroller.ensureWidgetVisible(heading, 0, 220)
        except RuntimeError:
            pass  # rebuilt again before the scroll

    def build(self):
        state = self.state
        state.refresh_player_preferences()
        self.controls = {}
        self.group_headings = {}
        for category, button in self.tabs.items():
            button.setChecked(category == self.tab and not self.query)
        running = state.session_running()
        self.running = running
        if running:
            self.add(Callout("warn", "A game is running",
                             f"Change settings in {app.VR_MENU}; they're read-only here until the game closes."))
        if self.query:
            self.build_search(self.query)
        else:
            self.build_tab(self.tab)
        if self.focus_key in self.controls:
            QTimer.singleShot(0, self.controls[self.focus_key].setFocus)
        self.focus_key = None

    def build_tab(self, category):
        # The tab's own description is its name; the page starts with its rows. Reset sits at the foot.
        rows = tab_rows(category)
        # Every group of rows has a heading, the first one included.
        heading = label(ESSENTIALS.upper(), "overline")
        heading.setContentsMargins(2, T.S1, 0, T.S1)
        self.add(heading)
        self.essentials_heading = heading
        panel = self.render_rows(Panel(), [entry for entry in rows if entry["depth"] == "everyday"])
        self.add(panel)
        customize = [entry for entry in rows if entry["depth"] == "customize"]
        hidden = [entry for entry in rows if entry.get("kind") == "preset" and not self.entry_shown(entry)]
        if customize or hidden:
            self.customize(category, customize, hidden)
        if not self.group_headings:
            # A lone ESSENTIALS heading names nothing: only shown beside other groups.
            heading.hide()
        self.elsewhere(category)
        # The tab's actions, once, at its foot: what the buttons do (Hands & Weapons) and Reset.
        actions = hbox(spacing=T.S3, margins=(0, T.S4, 0, 0))
        if category == "Hands & Weapons":
            actions.addWidget(Button("View your controls", lambda: ControlsDialog(self.window_).run(), size="sm"))
        actions.addStretch(1)
        reset = Button(f"Reset {category}…", self.reset, size="sm")
        reset.setEnabled(not self.running)
        actions.addWidget(reset)
        self.add_layout(actions)

    def customize(self, category, entries, hidden_presets=()):
        groups = list(dict.fromkeys(entry.get("group") for entry in entries if entry.get("group")))
        # Presets and whole groups that don't apply leave one line per reason saying when they show (R54).
        waiting = {}
        for entry in hidden_presets:
            definition = model.PRESET_DEFS[entry["preset"]]
            waiting.setdefault(when_text(definition.get("requires_reason", "")), []).append(definition["label"])
        for group in groups:
            members = [entry for entry in entries if entry.get("group") == group]
            if not any(self.entry_shown(entry) for entry in members):
                first = next((item for item in members if item.get("key") in model.BY_KEY), None)
                reason = model.requirement_text(model.BY_KEY[first["key"]], self.state.settings_values) if first else ""
                name = group[:-1] if group.endswith("s") and not group.endswith("ss") else group
                waiting.setdefault(when_text(reason), []).append(f"{name.lower()} settings")
        self.waiting = waiting
        for group in groups:
            members = [entry for entry in entries if entry.get("group") == group]
            shown = [entry for entry in members if self.entry_shown(entry)]
            if shown:
                summary = f"{len(shown)} setting{'s' if len(shown) != 1 else ''}"
            else:
                # A whole group that doesn't apply says once when it does (R54).
                first = next((item for item in members if item.get("key") in model.BY_KEY), None)
                summary = model.requirement_text(model.BY_KEY[first["key"]], self.state.settings_values) if first else ""
            if not shown:
                continue  # said above, in the one line for its reason
            heading = label(group.upper(), "overline")
            heading.setContentsMargins(2, T.S3, 0, T.S1)
            self.add(heading)
            self.group_headings[group] = heading
            shared = self.shared_help(shown)
            note = " ".join(text for text in (model.GROUP_NOTES.get(group, ""), self.group_note(shown), shared) if text)
            if note:
                hint = label(note, "muted", wrap=True)
                hint.setContentsMargins(2, 0, 0, T.S1)
                self.add(hint)
            self.add(self.render_rows(Panel(), members, skip_help=shared))

    def shared_help(self, members):
        """Help that most rows of a group repeat, said once at the top instead."""
        texts = [model.BY_KEY[item["key"]].help for item in members if item.get("key") in model.BY_KEY]
        common = max(set(texts), key=texts.count) if texts else ""
        return common if texts.count(common) >= SHARED_HELP else ""

    def group_note(self, members):
        """Which preset picks these values, said once at the top of the group in plain words."""
        owners = [model.BY_KEY[item["key"]].owner for item in members if item.get("key") in model.BY_KEY]
        presets = {owner for owner in owners if owner in model.PRESET_DEFS}
        if len(presets) != 1:
            return ""
        preset = presets.pop()
        share = "these" if all(owner == preset for owner in owners) else "some of these"
        name = " ".join(word if word.isupper() else word.lower() for word in model.PRESET_DEFS[preset]["label"].split())
        return f"Set by the {name}; changing one makes it Custom."

    def elsewhere(self, category):
        """One closing line on where the rest of this tab lives; search finds any of those settings by name."""
        headset = any(s.headset_only and s.tab == category and s.where == "headset" for s in model.SETTINGS)
        game = any(s.headset_only and s.tab == category and s.where == "game" for s in model.SETTINGS)
        parts = []
        if headset:
            parts.append(f"{app.VR_MENU} ({model.menu_path(category)})")
        if game:
            parts.append("Killing Floor 2's own Options menu")
        if parts:
            line = label("More settings are in " + " and in ".join(parts) + ".", "muted", wrap=True)
            line.setContentsMargins(2, T.S5, 0, 0)
            self.add(line)

    # ----- search -------------------------------------------------------------------
    def build_search(self, query):
        presets = model.preset_search(query)
        entries = model.search(query)
        # Headset-only gore limits and lifetimes stay out of the launcher entirely; body physics points to its page.
        others = [s for s in model.search_elsewhere(query)
                  if not (s.store == "graphics" and s.where == "headset" and not s.menu)]
        words = query.casefold().split()
        calibrations = list(dict.fromkeys((s.tab, s.group) for s in model.SETTINGS
                                          if s.headset_only and s.calibration and s.group
                                          and all(word in (s.label + " " + s.group).casefold() for word in words)))
        lowered = query.casefold()
        topics = list(dict.fromkeys((name, page) for word, name, page in HEADSET_TOPICS if word in lowered))
        shown_names = {s.label for s in others} | {group for _, group in calibrations}
        topics = [(name, page) for name, page in topics if name not in shown_names]
        values = self.state.settings_values
        if not (presets or entries or others or calibrations or topics):
            self.add(label(f"No settings match “{query}”.", "h2"))
            self.add(label("Try another word, such as reload, turn or shadows.", "help"))
            return
        title = label("", "h2")
        self.add(title)
        groups, waiting = {}, {}
        for preset in presets:
            if model.preset_applies(preset, values):
                groups.setdefault(model.PRESET_DEFS[preset]["category"] + "  ›  " + ESSENTIALS, []).append(
                    {"kind": "preset", "preset": preset})
            else:
                waiting.setdefault(model.PRESET_DEFS[preset].get("requires_reason", ""), []).append(
                    model.PRESET_DEFS[preset]["label"])
        for setting in entries:
            if not model.visible(setting, values):
                waiting.setdefault(model.requirement_text(setting, values), []).append(setting.label)
                continue
            tab, group = ELSEWHERE_PAGE.get(setting.tab, (setting.launcher_tab or setting.tab, setting.group))
            # Every heading names tab and group; rows without a group are the tab's Essentials.
            heading = tab + "  ›  " + (group or ESSENTIALS)
            groups.setdefault(heading, []).append({"key": setting.key})
        shown = 0
        for heading, items in groups.items():
            self.add(section(heading, top=T.S5))
            self.add(self.render_rows(Panel(), items))
            shown += len(items)
        for reason, names in waiting.items():
            joined = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
            line = label(f"{joined} {'appears' if len(names) == 1 else 'appear'} when you choose "
                         f"{pick_text(when_text(reason))}.", "muted", wrap=True)
            line.setContentsMargins(2, T.S3, 0, 0)
            self.add(line)
        # What the launcher leaves out, as plain information (not rows to press): one line per in-game VR
        # menu page that holds several matches ("More reload switches are in ..."), else each setting and where.
        def page_of(setting):
            category, _, group = (setting.menu or f"{setting.tab}/{setting.group}").partition("/")
            return category, group
        # Several matches on one page (a VR menu page, or a group of KF2's own Options) are one line.
        def key_of(setting):
            return ("game", setting.group) if setting.where == "game" else ("menu",) + page_of(setting)
        pages = {}
        for setting in others:
            pages.setdefault(key_of(setting), []).append(setting)
        crowded = {key for key, members in pages.items() if len(members) > 1 and key[-1]}
        lines = []
        for setting in others:
            key = key_of(setting)
            if key in crowded:
                if key[0] == "game":
                    line = f"More {setting.group.lower()} settings are in Killing Floor 2's own Options menu."
                else:
                    name = model.menu_path(*key[1:]).split(" › ")[-1]
                    name = (name[:-1] if name.endswith("s") and " " not in name else name).lower()
                    line = f"More {name} switches are in {app.VR_MENU}: {model.menu_path(*key[1:])}."
                if line not in lines:
                    lines.append(line)
            else:
                where = app.where_text(setting)
                lines.append(f"{setting.label}: {where[0].lower()}{where[1:]}.")
        lines += [f"{group}: in {app.VR_MENU}, {model.menu_path(tab, group)}." for tab, group in calibrations]
        lines += [f"{name}: in {app.VR_MENU}, {model.menu_path(*page)}." for name, page in topics]
        # The count is of rows that can be changed here; "Set elsewhere" lines are pointers, not results.
        title.setText(f"{shown} result{'s' if shown != 1 else ''} for “{query}”" if shown
                      else f"“{query}” is set outside the launcher")
        if lines:
            self.add(section("Set elsewhere", top=T.S5))
            for text in lines:
                line = label(text, "help", wrap=True)
                line.setContentsMargins(2, 0, 0, T.S2)
                self.add(line)


    # ----- rows ---------------------------------------------------------------------
    def entry_shown(self, entry):
        values = self.state.settings_values
        if entry.get("kind") == "preset":
            return model.preset_applies(entry["preset"], values)
        if entry.get("kind") in ("headset", "action"):
            return False
        return model.visible(model.BY_KEY[entry["key"]], values)

    def render_rows(self, panel, entries, search=False, skip_help=""):
        for entry in entries:
            kind = entry.get("kind")
            # Ammo rules stays in the same card, a titled row right under Reload mode (never a second card).
            if kind == "preset":
                self.preset_row(panel, entry["preset"])
            elif kind in ("headset", "action"):
                continue
            else:
                self.setting_row(panel, model.BY_KEY[entry["key"]], search, skip_help)
        return panel

    def preset_row(self, panel, preset):
        """A preset: its options as joined buttons, or Custom (closest to an option) with a way back to it (R51)."""
        definition = model.PRESET_DEFS[preset]
        values = self.state.settings_values
        if not model.preset_applies(preset, values):
            # Settings that don't apply are hidden (Kvasir94, 11-04); its Customize group says once when it shows.
            return
        control = preset_control(preset, values, lambda name, preset=preset: self.choose_preset(preset, name))
        control.setEnabled(not self.running)
        self.controls["preset:" + preset] = control
        cell = vbox(control, spacing=T.S1)
        if model.preset_name(preset, values) == "Custom" and not self.running:
            basis = model.preset_basis(preset, values)
            cell.addWidget(Button(f"Back to {basis}", lambda: self.choose_preset(preset, basis), size="sm"), 0,
                           Qt.AlignmentFlag.AlignRight)
        line, muted = preset_line(preset, values)
        if preset == "graphics_preset":
            muted = " ".join(part for part in (muted, graphics_pick_line()) if part)
        panel.add(SettingRow(definition["label"], line, holder(cell), note=muted or None))

    def setting_row(self, panel, setting, search=False, skip_help=""):
        state = self.state
        values = state.settings_values
        applicable = model.visible(setting, values)
        if not applicable and not search:
            # Settings that don't apply are hidden, not greyed (Kvasir94, 11-04);
            # search still finds them, greyed with what turns them on.
            return
        first, muted = setting_help(setting, values, skip_help)
        lines = [first]
        if setting.server_governed and not setting.help.startswith("Solo only") and lines[0]:
            lines.append(model.SERVER_NOTE + ".")
        # The group heading already says "Experimental"; rows elsewhere carry the tag themselves.
        tag, tone = ("Experimental", "warn") if setting.experimental and "Experimental" not in setting.group else (None, None)
        if setting.owner in model.PRESET_DEFS and model.preset_name(setting.owner, values) == "Custom" \
                and model.changed_from_style(setting, values, state.defaults()):
            tag, tone = "Changed", None
        help_text = " ".join(line for line in lines if line)
        if not applicable:
            reason = label(model.requirement_text(setting, values), "muted")
            panel.add(SettingRow(setting.label, help_text, reason, tag=tag, tag_tone=tone, dim=True))
            return
        key = setting.key
        control = setting_control(setting, values[key], lambda chosen: self.commit({key: chosen}, key))
        if control is None:
            control = Stepper(model.number_display(setting, values[key]), setting.minimum, setting.maximum,
                              setting.increment, setting.unit)
            control.committed.connect(lambda text, stepper=control: self.number(setting, stepper, text))
        control.setEnabled(not self.running)
        self.controls[key] = control
        panel.add(SettingRow(setting.label, help_text, control, tag=tag, tag_tone=tone,
                             note=muted or None))

    def number(self, setting, stepper, text):
        """A typed number saves once valid; an invalid one never replaces the last saved value."""
        try:
            proposed = model.number_value(setting, text)
        except ValueError:
            stepper.field.setProperty("invalid", "true")
            stepper.field.style().polish(stepper.field)
            stepper.setToolTip(f"Enter {setting.minimum:g}–{setting.maximum:g} {setting.unit}".strip())
            return
        stepper.field.setProperty("invalid", "false")
        stepper.field.style().polish(stepper.field)
        if proposed != self.state.settings_values[setting.key]:
            self.commit({setting.key: proposed}, setting.key, rebuild=False)
        stepper.set_text(model.number_display(setting, self.state.settings_values[setting.key]))

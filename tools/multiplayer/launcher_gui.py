"""Player window: first-run setup, Play, Settings, Setup, Help and the running session (Qt).

All launch and deployment work stays in friends.py. It runs as a separate
process; launcher_app.py starts it and follows its structured events, and this
window shows them. Closing the window never interrupts a session: friends.py
keeps running and restores KF2 when the game closes.

Pages live in launcher_ui_pages.py and launcher_ui_settings.py, the look in
launcher_ui_theme.py and launcher_ui_widgets.py, and everything they show or
do in launcher_app.py.
"""
import ctypes
import os
from pathlib import Path
import sys
import threading

import launcher_app as app
from launcher_app import LOGS, parse_context

# Kept for callers and tests that address the window module directly.
ROOT, game_folder = app.ROOT, app.game_folder


def _qt():
    from PySide6.QtCore import QObject, QRectF, Qt, QTimer, QUrl, Signal
    from PySide6.QtGui import QColor, QDesktopServices, QFont, QIcon, QImage, QLinearGradient, QPainter, QPixmap
    from PySide6.QtWidgets import (QApplication, QButtonGroup, QFileDialog, QFrame, QHBoxLayout, QMainWindow,
                                   QPushButton, QStackedWidget, QWidget)
    return locals()


def build_window():
    """The window classes, defined once PySide6 is importable."""
    q = _qt()
    QObject, Signal, Qt, QTimer, QUrl = q["QObject"], q["Signal"], q["Qt"], q["QTimer"], q["QUrl"]
    QMainWindow, QWidget, QFrame, QStackedWidget = q["QMainWindow"], q["QWidget"], q["QFrame"], q["QStackedWidget"]
    QPainter, QColor, QPixmap, QIcon = q["QPainter"], q["QColor"], q["QPixmap"], q["QIcon"]
    QDesktopServices, QFileDialog, QPushButton, QButtonGroup = (q["QDesktopServices"], q["QFileDialog"],
                                                                q["QPushButton"], q["QButtonGroup"])
    import launcher_ui_theme as T
    import launcher_ui_widgets as W
    from launcher_ui_pages import (DeveloperPage, FirstTimePage, HelpPage, JoinPage, MatchPage, PlayPage, SessionPage,
                                   SetupPage, WelcomePage)
    from launcher_ui_settings import SettingsPage

    class Bridge(QObject):
        art = Signal(object)
        update = Signal(object)

    class Brand(QWidget):
        def __init__(self):
            super().__init__()
            self.setFixedHeight(T.BRAND_HEIGHT)
            self.pixmap = None
            self.logo = False

        def set_art(self, image, logo):
            pixmap = QPixmap.fromImage(image)
            self.pixmap, self.logo = pixmap, logo
            self.update()

        def paintEvent(self, event):
            painter = QPainter(self)
            painter.setRenderHint(QPainter.RenderHint.Antialiasing)
            painter.setRenderHint(QPainter.RenderHint.TextAntialiasing)
            if self.pixmap is not None:
                painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
                # Never squeezed: on the narrow rail the art keeps its proportions, centred and cropped.
                width = self.pixmap.width() / max(1.0, self.pixmap.devicePixelRatio() or 1.0)
                scale = self.height() / max(1, self.pixmap.height() / max(1.0, self.pixmap.devicePixelRatio() or 1.0))
                target = int(width * scale)
                painter.drawPixmap(int((self.width() - target) / 2), 0, target, self.height(), self.pixmap)
            else:
                painter.fillRect(self.rect(), QColor(T.RAIL))
                icon = QPixmap(str(app.ICON))
                if not icon.isNull():
                    size = min(112, self.width() - 60)
                    painter.drawPixmap(int((self.width() - size) / 2), int(self.height() * 0.44 - size / 2), size, size,
                                       icon)
            # No tagline under the mark: "KF2-VR" already says VR, and the rail keeps its height for pages.

    class Window(QMainWindow):
        def __init__(self, state, art=True):
            super().__init__()
            self.state = state
            self.update_notice = None
            self.update_result = None   # (when, "new" | "current" | "failed") of the last check
            self.update_checking = False
            self.pages = {}
            self.current = None
            self.bridge = Bridge()
            self.bridge.art.connect(self._art_ready)
            self.bridge.update.connect(self._update_ready)
            self.setWindowTitle("KF2-VR")
            icon = QIcon(str(app.ICON))
            if not icon.isNull():
                self.setWindowIcon(icon)
            central = QWidget()
            central.setObjectName("Content")
            layout = q["QHBoxLayout"]()
            layout.setContentsMargins(0, 0, 0, 0)
            layout.setSpacing(0)
            layout.addWidget(self._rail())
            self.stack = QStackedWidget()
            layout.addWidget(self.stack, 1)
            central.setLayout(layout)
            self.setCentralWidget(central)
            self._size()
            W.shortcut(self, "Escape", self._escape)
            W.shortcut(self, "Ctrl+Return", lambda: self.current and self.current.go_primary())
            self.timer = QTimer(self)
            self.timer.setInterval(400)
            self.timer.timeout.connect(self._poll)
            self.art = art
            if art:
                self.restore_geometry()
                self.refresh_art()
                if self.state.update_check_enabled() and not self.state.context.workspace:
                    self.check_updates_now(asked=False)
            if self.state.first_launch():
                self.state.onboarding = True
                self.show_page("welcome")
            else:
                self.show_page("play")

        # ----- frame ----------------------------------------------------------------
        def _size(self):
            screen = q["QApplication"].primaryScreen()
            available = screen.availableGeometry() if screen else None
            width, height = 1240, 800
            if available is not None:
                width, height = min(width, int(available.width() * 0.94)), min(height, int(available.height() * 0.92))
                self.setMinimumSize(min(T.MIN_WIDTH, available.width()), min(T.MIN_HEIGHT, available.height()))
                self.resize(width, height)
                self.move(available.center().x() - width // 2, available.center().y() - height // 2)
            else:
                self.setMinimumSize(T.MIN_WIDTH, T.MIN_HEIGHT)
                self.resize(width, height)

        def resizeEvent(self, event):
            # A narrower sidebar on small windows leaves the pages room; width alone decides it.
            self.rail.setFixedWidth(T.RAIL_NARROW if event.size().width() < T.NARROW_WINDOW else T.RAIL_WIDTH)
            super().resizeEvent(event)
            # One relayout pass before anything paints: breakpoints (tabs and search on one row or two, the
            # column's margins) react to their own resize by changing layouts, which Qt would otherwise lay
            # out on a later event and paint one stale frame first. A few rounds settle the cascade.
            from PySide6.QtCore import QCoreApplication, QEvent
            for _ in range(4):
                QCoreApplication.sendPostedEvents(None, QEvent.Type.LayoutRequest)

        def geometry_file(self):
            import vr_config
            return Path(vr_config.profile_root()) / "launcher-window.json"

        def restore_geometry(self):
            """The size and place the window had when it last closed; Qt keeps it on a screen that exists."""
            import base64
            import json
            try:
                saved = json.loads(self.geometry_file().read_text(encoding="utf-8"))
                self.restoreGeometry(base64.b64decode(saved["geometry"]))
                self.saved_tab = saved.get("settings_tab")
            except (OSError, ValueError, KeyError, TypeError):
                pass

        def save_geometry(self):
            import base64
            import json
            try:
                path = self.geometry_file()
                path.parent.mkdir(parents=True, exist_ok=True)
                settings = self.pages.get("settings")
                path.write_text(json.dumps({"geometry": base64.b64encode(bytes(self.saveGeometry())).decode("ascii"),
                                            "settings_tab": settings.tab if settings else None}), encoding="utf-8")
            except OSError:
                pass

        def prefetch_maps(self):
            try:
                game = self.state.game()
                if game:
                    self.state.stock_maps(game)
                    self.state.maps("solo", game)
                    self.state.maps("host", game)
            except Exception:
                pass

        def _rail(self):
            rail = QFrame()
            rail.setObjectName("Rail")
            rail.setFixedWidth(T.RAIL_WIDTH)
            self.rail = rail
            column = W.vbox(spacing=0)
            self.brand = Brand()
            column.addWidget(self.brand)
            self.nav_holder = W.vbox(spacing=0, margins=(0, T.S2, 0, 0))
            column.addLayout(self.nav_holder)
            column.addStretch(1)
            self.rail_foot = W.vbox(spacing=T.S1, margins=(26, T.S4, T.S4, T.S5))
            column.addLayout(self.rail_foot)
            rail.setLayout(column)
            self.nav_buttons = {}
            self.nav_group = QButtonGroup(self)
            self._draw_foot()
            return rail

        def _nav_button(self, name, page, active):
            button = QPushButton(name.replace("&", "&&"))
            button.setProperty("nav", "true")
            button.setCheckable(True)
            button.setChecked(name == active)
            button.setCursor(Qt.CursorShape.PointingHandCursor)
            button.setFocusPolicy(Qt.FocusPolicy.TabFocus)
            button.clicked.connect(lambda checked=False, page=page: self.show_page(page))
            self.nav_group.addButton(button)
            self.nav_holder.addWidget(button)
            self.nav_buttons[name] = button
            return button

        def _draw_nav(self, active):
            W.clear(self.nav_holder)
            self.nav_buttons = {}
            self.nav_group = QButtonGroup(self)
            steps = (("welcome", "Your game"), ("first-time", "First-time setup"))
            if active in ("welcome", "first-time"):
                self.onboarding_step = active
            if self.state.onboarding and (active in ("welcome", "first-time") or getattr(self, "onboarding_step", None)):
                head = W.label("GETTING STARTED", "overline")
                head.setContentsMargins(26, T.S2, 0, T.S3)
                self.nav_holder.addWidget(head)
                current = getattr(self, "onboarding_step", "welcome")
                reached = [key for key, _ in steps].index(current)
                for index, (key, text) in enumerate(steps):
                    row = W.hbox(spacing=T.S3, margins=(26, T.S2, T.S3, T.S2))
                    here = key == active
                    mark = W.Mark("done" if index < reached else "active" if index == reached else "waiting",
                                  "" if index < reached else str(index + 1), 22)
                    if index <= reached and not here:
                        # A step already reached leads back to it.
                        name = W.Button(text, lambda key=key: self.show_page(key), kind="link")
                        name.setStyleSheet(f"color: {T.TEXT_2}; font-weight: 600;")
                    else:
                        name = W.label(text, "h3" if here else "help")
                        if index > reached:
                            name.setStyleSheet(f"color: {T.TEXT_3};")
                    row.addWidget(mark)
                    row.addWidget(name, 1)
                    self.nav_holder.addLayout(row)
                # Help and the game and headset checks stay in reach before setup is done.
                self.nav_holder.addSpacing(T.S5)
                for name, page in ((app.SETUP_NAV, "setup"), ("Help", "help")):
                    self._nav_button(name, page, active)
                return
            pages = [("Play", "play"), ("Settings", "settings"), (app.SETUP_NAV, "setup"), ("Help", "help")]
            if self.state.session is not None:
                pages.insert(1, ("Session", "session"))
            for name, page in pages:
                self._nav_button(name, page, active)

        def _draw_foot(self):
            W.clear(self.rail_foot)
            if self.update_notice:
                tag, url = self.update_notice
                link = W.Button(f"Update available: {tag}", lambda: QDesktopServices.openUrl(QUrl(url)), kind="link")
                link.setStyleSheet(f"color: {T.GREEN};")
                self.rail_foot.addWidget(link)
            self.rail_foot.addWidget(W.label(app.version_text(self.state.version), "muted"))
            if self.state.developer:
                self.rail_foot.addWidget(W.label("Developer mode", "muted", "warn"))

        def showEvent(self, event):
            super().showEvent(event)
            self.dark_title_bar()

        def dark_title_bar(self):
            # Windows 10 20H1+/11: a dark caption instead of a white one.
            try:
                handle = int(self.winId())
                value = ctypes.c_int(1)
                ctypes.windll.dwmapi.DwmSetWindowAttribute(handle, 20, ctypes.byref(value), ctypes.sizeof(value))
                ctypes.windll.dwmapi.DwmSetWindowAttribute(handle, 35, ctypes.byref(ctypes.c_int(0x00120F0F)), 4)
            except (AttributeError, OSError):
                pass

        def bring_to_front(self):
            self.show()
            self.raise_()
            self.activateWindow()

        # ----- pages ------------------------------------------------------------------
        PAGES = {"welcome": WelcomePage, "first-time": FirstTimePage, "play": PlayPage, "match-solo": MatchPage,
                 "match-host": MatchPage,
                 "join": JoinPage, "session": SessionPage, "settings": SettingsPage, "setup": SetupPage,
                 "help": HelpPage, "developer": DeveloperPage}

        def page(self, name):
            if name not in self.pages:
                widget = self.PAGES[name](self)
                if name == "settings" and getattr(self, "saved_tab", None):
                    widget.prepare(tab=self.saved_tab)  # a returning player opens Settings where they left it
                self.pages[name] = widget
                self.stack.addWidget(widget)
            return self.pages[name]

        def show_page(self, name, **options):
            page = self.page(name)
            # A match form built for the same match is shown as it was left, without rebuilding it.
            reused = hasattr(page, "reuse") and page.reuse(**options)
            if not reused:
                if hasattr(page, "prepare"):
                    page.prepare(**options)
                page.rebuild()
            self.stack.setCurrentWidget(page)
            # The page itself takes focus, so no field opens wearing a focus ring; Tab still reaches every control.
            page.setFocusPolicy(Qt.FocusPolicy.ClickFocus)
            page.setFocus()
            self.current = page
            nav = page.nav
            if name == "first-time" and not self.state.onboarding:
                nav = app.SETUP_NAV
            self._draw_nav(nav)
            q["QApplication"].sendPostedEvents()  # the rail's new buttons are in place before the next frame
            return page

        def _escape(self):
            page = self.current
            search = getattr(page, "search", None)
            if search is not None and search.text():
                search.clear()
            elif page is not None:
                page.go_back()

        # ----- art and updates ------------------------------------------------------------
        def refresh_art(self):
            if not self.art:
                return
            import launcher_art
            game = launcher_art.art_folder(self.state)
            self.state.hero_game = game
            ratio = self.devicePixelRatioF() or 1.0
            ratio = max(ratio, 1.0)

            def work():
                try:
                    self.bridge.art.emit(launcher_art.compose_brand(game, T.RAIL_WIDTH - 1, ratio))
                except Exception:
                    pass
            threading.Thread(target=work, daemon=True).start()
            # Listing maps walks the game folder: do it now, and again whenever the copy changes (every
            # install change refreshes the art), so the first match form opens at once.
            threading.Thread(target=self.prefetch_maps, daemon=True).start()

        def _art_ready(self, result):
            image, logo = result
            self.brand.set_art(image, logo)

        def check_updates_now(self, asked=True):
            if self.update_checking:
                return
            self.update_checking = True
            self.update_asked = asked
            threading.Thread(target=lambda: self.bridge.update.emit(self.state.check_update()), daemon=True).start()
            if self.current is not None and self.current is self.pages.get("setup"):
                self.current.rebuild(keep_scroll=True)

        def update_status_text(self):
            """The line Setup shows for the update check, and its tone."""
            if self.update_checking:
                return "Checking for a newer version…", None
            if self.update_result is None:
                return "Not checked yet this time.", None
            when, result = self.update_result
            stamp = f"{when.day} {when:%b}, {when:%H:%M}"
            if result == "new":
                return f"KF2-VR {self.update_notice[0]} is out (checked at {stamp}); the Play page links to it.", "ok"
            if result == "failed":
                # The automatic check at start says so quietly; only a check the player asked for warns.
                text = "Couldn't check for updates. Check your internet connection."
                return text, "warn" if getattr(self, "update_asked", False) else None
            return f"Up to date (checked at {stamp}).", None

        def _update_ready(self, result):
            from datetime import datetime
            kind, found = result
            self.update_checking = False
            self.update_result = (datetime.now(), kind)
            if kind == "new":
                self.update_notice = found
                self._draw_foot()
            if self.current is not None and self.current in (self.pages.get("play"), self.pages.get("setup")):
                self.current.rebuild(keep_scroll=True)

        # ----- dialogs ------------------------------------------------------------------
        def ask(self, title, text, yes="Continue", no="Cancel", danger=False, detail=None):
            return W.ask(self, title, text, yes=yes, no=no, danger=danger, detail=detail)

        def alert(self, title, text, kind="error", detail=None):
            W.alert(self, title, text, kind=kind, detail=detail)

        def save_failed(self, problem):
            if problem == "running":
                self.alert("Locked while a game runs", f"Change settings in {app.VR_MENU} until the game closes.", kind="info")
            else:
                self.alert("Couldn't save settings", str(problem))

        def saved_feedback(self):
            settings = self.pages.get("settings")
            if settings is not None:
                settings.flash()

        # ----- game ------------------------------------------------------------------------
        def need_game(self):
            game = self.state.game()
            if game:
                return game
            _, problem = self.state.resolve_game()
            if problem == "choose":
                self.show_page("play")
                return None
            return self.pick_game_folder(None)

        def pick_game_folder(self, after=None):
            picked = QFileDialog.getExistingDirectory(self, "Choose the killingfloor2 folder in your Steam or Epic library")
            if not picked:
                return None
            install, problem = self.state.check_folder(picked)
            if problem:
                self.alert(*problem)
                return None
            self.state.use_install(install)
            self.refresh_art()
            if after is not None:
                after()
            return install.root

        def pick_server_folder(self, after=None):
            start = str(Path(self.state.saved.server_root).parent)
            picked = QFileDialog.getExistingDirectory(self, "Choose where the game server goes (about 32 GB)", start)
            if not picked:
                return
            problem = self.state.choose_server_folder(picked)
            if problem:
                self.alert(*problem)
            elif after is not None:
                after()

        def quick_play(self):
            game = self.need_game()
            if not game:
                return
            if self.state.store == "epic" and not self.state.vr:
                self.alert("Epic plays in VR only", "Epic support is experimental and covers Solo in VR only.", kind="info")
                return
            self.run(*self.state.quick_play_arguments(game))

        def open_match(self, kind):
            game = self.need_game()
            if not game:
                return
            if self.state.store == "epic" and (kind != "solo" or not self.state.vr):
                self.alert("Epic plays Solo in VR only", "Epic support is experimental and covers Solo in VR only.",
                           kind="info")
                return
            maps = self.state.maps(kind, game)
            if not maps:
                self.alert("No maps found", "No Killing Floor 2 maps were found in your game folder.")
                return
            self.show_page("match-" + kind, kind=kind, game=game, maps=maps)

        def open_join(self):
            if self.state.store == "epic":
                self.alert("Joining needs Steam", "Joining friends works with the Steam version of Killing Floor 2 for now.",
                           kind="info")
                return
            game = self.need_game()
            if game:
                self.show_page("join", game=game)

        # ----- session -------------------------------------------------------------------
        def run(self, arguments, title):
            if not self.state.allow_workspace_launch(self.ask, self.alert):
                return
            self.state.launch(arguments, title)
            self.show_page("session")
            self.timer.start()

        def _poll(self):
            session = self.state.session
            if session is None:
                self.timer.stop()
                return
            changed = session.poll()
            page = self.pages.get("session")
            if page is not None and self.current is page:
                page.update_view(changed)
            if session.finished:
                self.timer.stop()

        def closeEvent(self, event):
            session = self.state.session
            # A run that is still downloading has nothing to tidy up: closing stops it, so a
            # download never carries on with no window (Kvasir94, 11-05). A started game keeps going.
            if session is not None and session.preparing():
                if not self.ask("KF2-VR is still getting ready",
                                "Closing stops the download. Next time it carries on where it left off.",
                                yes="Stop and close", no="Keep open"):
                    event.ignore()
                    return
                session.stop()
            elif session is not None and session.running() and not self.ask(
                    "KF2-VR is still running",
                    "You can close this window: the game keeps going and tidies up after itself when you quit it.",
                    yes="Close window", no="Keep open"):
                event.ignore()
                return
            if self.art:
                self.save_geometry()
            event.accept()

        # ----- troubleshooting -----------------------------------------------------------
        def send_logs(self):
            """Ask where the log ZIP goes (the Desktop by default), never into the KF2-VR folder."""
            from PySide6.QtCore import QStandardPaths
            # The real Desktop, also when OneDrive or a policy moved it.
            desktop = Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.DesktopLocation)
                           or Path.home() / "Desktop")
            start = desktop if desktop.is_dir() else Path.home() / "Documents"
            folder = QFileDialog.getExistingDirectory(self, "Choose where to save your logs", str(start))
            if not folder:
                return
            title, text, detail, kind = self.state.send_logs(folder)
            self.alert(title, text, kind=kind, detail=detail)

        def recover(self):
            session = self.state.session
            if session is not None and session.running():
                self.alert("Still running", "Wait for the current game to close first.", kind="info")
                return
            if self.state.store == "epic":
                game = self.need_game()
                if game:
                    self.run(["--store", "epic", "--recover-epic", "--game-root", str(game)], "Epic recovery")
                return
            title, text, detail, kind = self.state.recover()
            self.alert(title, text, kind=kind, detail=detail)

        def open_logs(self):
            try:
                LOGS.mkdir(parents=True, exist_ok=True)
                os.startfile(LOGS)
            except OSError:
                # A plain message with the path shortened in the middle; no raw Windows error text.
                where = str(LOGS)
                if len(where) > 64:
                    where = where[:28] + "…" + where[-32:]
                self.alert("Couldn't open the logs folder", f"Windows didn't open it. You'll find it at {where}.")


    return Window


def install_error_hook(window):
    """Errors raised in Qt handlers go to window-error.txt and a short message, once at a time."""
    import traceback
    showing = []

    def hook(kind, value, trace):
        try:
            LOGS.mkdir(parents=True, exist_ok=True)
            with (LOGS / "window-error.txt").open("a", encoding="utf-8") as log:
                log.write("".join(traceback.format_exception(kind, value, trace)) + "\n")
        except OSError:
            pass
        if showing:
            return
        showing.append(True)
        try:
            window.alert("Something went wrong", "That didn't work. The launcher keeps going; if it happens again, press "
                         "Save logs for a bug report on the Help page.", kind="warn")
        finally:
            showing.clear()
    sys.excepthook = hook


def self_check(context):
    """Packaging check: build every page and dialog offscreen without launching, saving or showing anything."""
    from PySide6.QtWidgets import QApplication
    import launcher_settings as model
    import launcher_ui_theme as T
    application = QApplication.instance() or QApplication(sys.argv[:1])
    T.apply(application)
    state = app.LauncherState(context)
    Window = build_window()
    window = Window(state, art=False)
    import launcher_ui_pages as pages
    state.onboarding = True
    window.show_page("welcome")
    window.show_page("first-time")
    state.onboarding = False
    window.show_page("play")
    settings = window.show_page("settings")
    import launcher_ui_settings
    for tab in launcher_ui_settings.TABS:
        settings.show_tab(tab)
    for query in ("reload", "snap", "zzqx"):
        settings.query = query
        settings.rebuild()
    settings.query = ""
    window.show_page("setup")
    window.show_page("help")
    if state.developer:
        window.show_page("developer")
    game = Path("self-check-game")
    for kind in ("solo", "host"):
        window.show_page("match-" + kind, kind=kind, game=game, maps=["KF-BurningParis", "KF-Outpost"])
    join = window.show_page("join", game=game)
    join.choose("address")
    join.choose("code")
    state.session = app.SessionTracker(None, Path("self-check.txt"), Path("self-check.jsonl"), "host", "Hosting")
    state.session.remember({"phase": "host-ready", "join_code": "KF2VR1:self-check"})
    session = window.show_page("session")
    state.session.finished, state.session.returncode = True, 1
    session.update_view({"finished"})
    state.session = None
    for dialog in (pages.GraphicsDialog(window), pages.ControlsDialog(window)):
        dialog.adjustSize()
        dialog.deleteLater()
    application.processEvents()
    window.deleteLater()
    application.processEvents()
    return 0


def main(argv=None):
    context = parse_context(argv)
    if context.self_check:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        return self_check(context)
    state = app.LauncherState(context)
    if not app.single_instance():
        ctypes.windll.user32.MessageBoxW(None, "KF2-VR is already open in another window.", "KF2-VR", 0x40)
        return 0
    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication
    import launcher_ui_theme as T
    QApplication.setApplicationName("KF2-VR")
    application = QApplication(sys.argv[:1])
    T.apply(application)
    Window = build_window()
    window = Window(state)
    install_error_hook(window)
    window.show()
    QTimer.singleShot(50, window.bring_to_front)
    return application.exec()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as error:
        if "--self-check" in sys.argv:
            raise  # a packaging check reports on the console; never wait on a message box
        LOGS.mkdir(parents=True, exist_ok=True)
        import traceback
        (LOGS / "window-error.txt").write_text(traceback.format_exc(), encoding="utf-8")
        ctypes.windll.user32.MessageBoxW(None, f"KF2-VR couldn't open its window:\n\n{error}\n\n"
            "Use Save logs for a bug report when the launcher opens again. "
            "If you share window-error.txt from %LOCALAPPDATA%\\KF2VR\\Logs manually, review and remove personal details "
            "first.", "KF2-VR", 0x10)
        raise SystemExit(1)

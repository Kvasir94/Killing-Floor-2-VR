"""Player window: Solo, Host, Join, Settings and sending logs.

All launch and deployment work stays in friends.py. It runs as a separate
process writing to a log file that this window follows, so closing the window
never interrupts a session: friends.py keeps running and restores KF2 when the
game closes.

The look follows the development launcher (tools/play-gui.ps1): the game's
near-black scanlined plates, blood-red hairlines, condensed uppercase headings
and an art rail made from the player's own installed KF2 wallpaper and logo.
"""
from datetime import datetime
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, font as tkfont, messagebox, ttk

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
# Packaged ZIPs keep everything in app/ beside a single start file.
OUTER = ROOT.parent if ROOT.name.lower() == "app" else ROOT
LOGS = ROOT / "logs"
REPORT_BUTTON = "Save logs for a bug report"
REPORT_WHERE = "Post bug reports in Discord"
NO_WINDOW = 0x08000000
PYTHON = Path(sys.executable).with_name("python.exe")

# Palette shared with tools/play-gui.ps1.
INK, PLATE, PLATE_UP, EDGE = "#0c0c0e", "#16161a", "#202026", "#3e3e46"
FG, DIM, MUTE, WHITE = "#e6e6ea", "#8e8e98", "#5c5c66", "#ffffff"
RED, RED_HOT, RED_DEEP, AMBER = "#b01b1f", "#e23a2e", "#421113", "#d89e3c"

DIFFICULTY_LABELS = {"normal": "Normal", "hard": "Hard", "suicidal": "Suicidal", "hellonearth": "Hell on Earth"}
LENGTH_LABELS = {"short": "Short  -  4 waves, then the boss", "medium": "Medium  -  7 waves, then the boss",
                 "long": "Long  -  10 waves, then the boss"}
QUALITY_LABELS = {"quality": "Quality  -  full detail", "balanced": "Balanced",
                  "performance": "Performance  -  highest frame rate"}
SCALES = ["Keep my last setting"] + [f"{n}%" for n in range(100, 49, -5)]

# Progress lines printed by friends.py and the server installer, in plain words.
STATUS = (
    ("Build:", "Checking your game and files..."),
    ("Join code accepted", "Code accepted. Getting ready..."),
    ("Preparing the free dedicated server", "Setting up the game server..."),
    ("Installing dedicated server", "Downloading the game server. The first time is about 32 GB and can take a long time."),
    ("SteamCMD metadata initialized", "Still downloading the game server..."),
    ("Dedicated server ready", "Game server ready. Starting it..."),
    ("Dedicated server already installed", "Game server ready. Starting it..."),
    ("Checking the server", "Connecting to the game server..."),
    ("Host ready", "Your game is up. Send your friends the code below."),
    ("KF2 is starting", "KF2 is starting. Pick your perk and press Ready.\nKeep this window open while you play."),
)

FRIENDLY_ERRORS = (
    ("KF2 version differs", "Your copy of Killing Floor 2 doesn't match this KF2-VR build. Let Steam finish "
                            "updating KF2, then get the newest KF2-VR from where you downloaded this one."),
    ("Start standard KF2 once", "Start normal Killing Floor 2 from Steam once, quit it, then try again."),
    ("No usable active OpenXR runtime", "Your headset isn't ready. Start Quest Link / Air Link, SteamVR or your "
                                        "headset's PC app, then try again. Or choose Desktop."),
    ("Another KF2-VR session is running", "KF2-VR is already running in another window. Close that game first."),
    ("Another VR/mod session", "A previous KF2-VR session didn't finish tidying up. Use 'Fix a stuck session', then try again."),
    ("Close KF2 and its SDK", "Killing Floor 2 is already open. Close it, then try again."),
    ("Cannot verify server", "Couldn't reach your friend's game. Check the code is the newest one, and ask them to "
                             "make sure their game says it's up."),
    ("Package file changed or missing", "Some KF2-VR files are missing or damaged. Delete this folder and unzip a fresh copy."),
    ("Dedicated server installation", "The game server download didn't finish. Check your internet and disk space, then try again."),
    ("Server reports VAC enabled", "That server isn't a KF2-VR game. Check the code with your friend."),
    ("is not installed on both client and server", "That map isn't installed. Pick a different map."),
)

# The rail is composed by Windows' own imaging (Tk cannot read the game's JPG
# wallpaper), with the same crop, darkening and fades as tools/play-gui.ps1.
RAIL_ART = r"""
Add-Type -AssemblyName System.Drawing
$W = [int]$env:KF2VR_W; $H = [int]$env:KF2VR_H
$art = $null
foreach ($n in 'KF2-Wallpaper1920x1080.jpg','KF2-Wallpaper1680x1050.jpg','KF2-Wallpaper1600x1200.jpg','KF2-Wallpaper1280x720.jpg') {
    $p = Join-Path $env:KF2VR_GAME "Wallpaper\$n"
    if ($env:KF2VR_GAME -and (Test-Path -LiteralPath $p)) { $art = [Drawing.Image]::FromFile($p); break }
}
$logo = $null
try {
    $cache = Join-Path (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath 'appcache/librarycache/232090'
    $file = Join-Path $cache 'logo.png'
    if (-not (Test-Path -LiteralPath $file)) {
        $file = (Get-ChildItem -LiteralPath $cache -Filter 'logo.png' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if ($file) { $logo = [Drawing.Image]::FromFile($file) }
} catch { }
$bmp = New-Object Drawing.Bitmap $W, $H
$g = [Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'AntiAlias'
$whole = New-Object Drawing.Rectangle 0, 0, $W, $H
if ($art) {
    $srcH = [int]($art.Height * 0.64); $srcW = [int]($srcH * $W / $H)
    $left = [Math]::Max(0, [Math]::Min($art.Width - $srcW, [int]($art.Width * 0.68) - [int]($srcW / 2)))
    $g.DrawImage($art, $whole, $left, 0, $srcW, $srcH, [Drawing.GraphicsUnit]::Pixel)
    $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(168, 8, 8, 10))), $whole)
    $wide = $whole; $wide.Inflate(1, 1)
    $g.FillRectangle((New-Object Drawing.Drawing2D.LinearGradientBrush($wide, [Drawing.Color]::FromArgb(0, 12, 12, 14), [Drawing.Color]::FromArgb(236, 12, 12, 14), 0.0)), $whole)
} else {
    $g.FillRectangle((New-Object Drawing.Drawing2D.LinearGradientBrush($whole, [Drawing.Color]::FromArgb(255, 34, 34, 40), [Drawing.Color]::FromArgb(255, 12, 12, 14), 60.0)), $whole)
}
$foot = [int]($H * 0.45)
$under = New-Object Drawing.Rectangle 0, ($H - $foot), $W, $foot
$tall = $under; $tall.Inflate(1, 1)
$g.FillRectangle((New-Object Drawing.Drawing2D.LinearGradientBrush($tall, [Drawing.Color]::FromArgb(0, 8, 8, 10), [Drawing.Color]::FromArgb(226, 8, 8, 10), 90.0)), $under)
for ($y = 0; $y -lt $H; $y += 2) { $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(14, 255, 255, 255))), 0, $y, $W, 1) }
if ($logo) {
    $lw = $W - [int]($W * 0.23); $lh = [int]($lw * $logo.Height / $logo.Width)
    $g.DrawImage($logo, [int]($W * 0.115), [int]($H * 0.16) - [int]($lh / 2), $lw, $lh)
    'logo'
}
$g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(176, 27, 31))), ($W - 3), 0, 3, $H)
$bmp.Save($env:KF2VR_OUT, [Drawing.Imaging.ImageFormat]::Png)
"""


def friendly(message):
    return next((text for key, text in FRIENDLY_ERRORS if key in message), message or "Something went wrong.")


def game_folder():
    settings = ROOT / "settings.json"
    if settings.exists():
        saved = json.loads(settings.read_text(encoding="utf-8")).get("game_root")
        if saved and (Path(saved) / "Binaries/Win64/KFGame.exe").exists():
            return Path(saved)
    import friends
    return friends.find_game()


class Launcher(tk.Tk):
    def __init__(self, art=True):
        super().__init__()
        release = ROOT / "release.json"
        manifest = json.loads(release.read_text(encoding="utf-8")) if release.exists() else {}
        self.build = manifest.get("build_id", ROOT.name)
        self.title("KF2-VR")
        self.configure(bg=INK)
        self.scale = self.winfo_fpixels("1i") / 96
        self.rail_width = self.px(380)
        self.geometry(f"{self.px(1120)}x{self.px(740)}")
        self.minsize(self.px(1020), self.px(680))
        self.theme()
        import friends
        from workshop_loadout import load_preferences
        self.saved = friends.parse_options(["--host"])
        load_preferences(self.saved)
        self.vr = tk.BooleanVar(value=bool(self.saved.vr))
        self.frame_timings = tk.BooleanVar(value=False)
        self.process = None
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.rail = tk.Canvas(self, width=self.rail_width, bg=PLATE, highlightthickness=0)
        self.rail.pack(side="left", fill="y")
        self.rail.bind("<Configure>", lambda event: self.draw_rail())
        self.rail_image = None
        self.rail_logo = False
        self.body = tk.Frame(self, bg=INK)
        self.body.pack(side="left", fill="both", expand=True)
        self.update_idletasks()
        self.dark_title_bar()
        self.rail_ready = None
        if art:
            threading.Thread(target=self.make_rail_art, daemon=True).start()
            self.after(200, self.wait_rail_art)
        self.home()

    # ----- theme ----------------------------------------------------------
    def px(self, value):
        return int(value * self.scale)

    def theme(self):
        families = set(tkfont.families(self))
        display = next((f for f in ("Bahnschrift SemiBold Condensed", "Bahnschrift Condensed", "Agency FB",
                                    "Segoe UI Semibold") if f in families), "Segoe UI")
        self.f_body = (("Segoe UI", 10))
        self.f_small = ("Segoe UI", 9)
        self.f_label = (display, 11)
        self.f_tab = (display, 12)
        self.f_card = (display, 17)
        self.f_action = (display, 14)
        self.f_title = (display, 30)
        self.f_word = (display, 40)
        self.f_tag = (display, 16)
        self.option_add("*TCombobox*Listbox.background", PLATE)
        self.option_add("*TCombobox*Listbox.foreground", FG)
        self.option_add("*TCombobox*Listbox.selectBackground", RED)
        self.option_add("*TCombobox*Listbox.selectForeground", WHITE)
        self.option_add("*TCombobox*Listbox.font", self.f_body)
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure(".", background=INK, foreground=FG, font=self.f_body, bordercolor=EDGE,
                        lightcolor=PLATE_UP, darkcolor=PLATE_UP, troughcolor=PLATE, focuscolor=INK)
        style.configure("TCombobox", fieldbackground=PLATE_UP, background=PLATE_UP, foreground=FG,
                        arrowcolor=FG, padding=self.px(6), selectbackground=PLATE_UP, selectforeground=FG)
        style.map("TCombobox", fieldbackground=[("readonly", PLATE_UP)], foreground=[("readonly", FG)],
                  bordercolor=[("focus", RED), ("hover", DIM)], arrowcolor=[("hover", RED_HOT)],
                  background=[("hover", PLATE_UP), ("pressed", RED_DEEP)])
        style.configure("TEntry", fieldbackground=PLATE_UP, foreground=FG, insertcolor=FG, padding=self.px(6),
                        selectbackground=RED, selectforeground=WHITE)
        style.map("TEntry", bordercolor=[("focus", RED)], fieldbackground=[("readonly", PLATE)])
        style.configure("TCheckbutton", background=INK, foreground=FG, indicatorbackground=PLATE_UP,
                        indicatorforeground=WHITE, indicatormargin=(0, 0, self.px(10), 0), padding=self.px(3))
        style.map("TCheckbutton", indicatorbackground=[("selected", RED), ("active", PLATE_UP)],
                  background=[("active", INK)], foreground=[("active", WHITE)])
        style.configure("Red.Horizontal.TProgressbar", troughcolor=PLATE, background=RED, bordercolor=EDGE,
                        lightcolor=RED_HOT, darkcolor=RED, thickness=self.px(8))

    def dark_title_bar(self):
        # Windows 10 20H1+/11: match the game's dark frame instead of a white caption.
        try:
            handle = ctypes.windll.user32.GetParent(self.winfo_id())
            value = ctypes.c_int(1)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(handle, 20, ctypes.byref(value), ctypes.sizeof(value))
            ctypes.windll.dwmapi.DwmSetWindowAttribute(handle, 35, ctypes.byref(ctypes.c_int(0x0E0C0C)), 4)
        except (AttributeError, OSError):
            pass

    def make_rail_art(self):
        try:
            game = game_folder()
            import tempfile
            target = Path(tempfile.gettempdir()) / f"kf2vr-rail-{self.rail_width}x{self.px(740)}.png"
            import base64
            script = base64.b64encode(RAIL_ART.encode("utf-16-le")).decode("ascii")
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", script],
                stdin=subprocess.DEVNULL, text=True, capture_output=True, creationflags=NO_WINDOW, timeout=60,
                env=dict({k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}, KF2VR_W=str(self.rail_width), KF2VR_H=str(self.px(740)),
                         KF2VR_GAME=str(game or ""), KF2VR_OUT=str(target)))
            if result.returncode == 0 and target.exists():
                self.rail_ready = (target, "logo" in result.stdout)
        except (OSError, subprocess.SubprocessError, ValueError):
            pass

    def wait_rail_art(self):
        # Tk is single-threaded: the worker only leaves its result here.
        if self.rail_ready:
            self.use_rail_art(*self.rail_ready)
        elif self.rail_image is None:
            self.after(200, self.wait_rail_art)

    def use_rail_art(self, path, logo):
        try:
            self.rail_image = tk.PhotoImage(file=str(path))
        except tk.TclError:
            return
        self.rail_logo = logo
        self.draw_rail()

    def draw_rail(self):
        canvas, w, h = self.rail, self.rail_width, self.rail.winfo_height()
        canvas.delete("all")
        if self.rail_image:
            canvas.create_image(0, 0, image=self.rail_image, anchor="nw")
            canvas.create_rectangle(0, self.rail_image.height(), w, h, fill=INK, outline="")
        canvas.create_rectangle(w - 3, 0, w, h, fill=RED, outline="")
        if not self.rail_logo:
            canvas.create_text(self.px(48), self.px(60), text="KILLING\nFLOOR 2", font=self.f_word,
                               fill=WHITE, anchor="nw")
        canvas.create_text(self.px(50), self.px(214), text="VIRTUAL REALITY", font=self.f_tag, fill=RED_HOT, anchor="nw")
        canvas.create_text(self.px(50), h - self.px(40), text="BUILD\n" + self.build, font=self.f_small,
                           fill=MUTE, anchor="sw", width=w - self.px(80))

    # ----- widgets --------------------------------------------------------
    def button(self, parent, text, command, primary=False, small=False):
        fill, border, face = (RED, RED_HOT, WHITE) if primary else (PLATE_UP, EDGE, FG)
        button = tk.Label(parent, text=text.upper(), font=self.f_label if small else self.f_action,
                          bg=fill, fg=face, cursor="hand2", highlightthickness=1, highlightbackground=border,
                          padx=self.px(14 if small else 26), pady=self.px(5 if small else 9))
        def hover(on):
            button.configure(bg=(RED_HOT if primary else RED_DEEP) if on else fill,
                             highlightbackground=RED_HOT if on else border, fg=WHITE if on else face)
        button.bind("<Enter>", lambda event: hover(True))
        button.bind("<Leave>", lambda event: hover(False))
        button.bind("<Button-1>", lambda event: command())
        return button

    def chip(self, parent, text, selected, command):
        chip = tk.Label(parent, text=text.upper(), font=self.f_tab, cursor="hand2", highlightthickness=1,
                        padx=self.px(18), pady=self.px(7))
        def paint(hover=False):
            on = selected()
            chip.configure(bg=RED_DEEP if on else PLATE_UP, fg=WHITE if on else (FG if hover else DIM),
                           highlightbackground=RED if on else (DIM if hover else EDGE))
        chip.paint = paint
        chip.bind("<Enter>", lambda event: paint(True))
        chip.bind("<Leave>", lambda event: paint(False))
        chip.bind("<Button-1>", lambda event: command())
        paint()
        return chip

    def card(self, parent, title, text, command):
        card = tk.Frame(parent, bg=PLATE_UP, highlightthickness=1, highlightbackground=EDGE, cursor="hand2")
        accent = tk.Frame(card, bg=PLATE_UP, width=self.px(4))
        accent.pack(side="left", fill="y")
        heading = tk.Label(card, text=title.upper(), font=self.f_card, bg=PLATE_UP, fg=WHITE, anchor="w")
        heading.pack(fill="x", padx=self.px(18), pady=(self.px(12), 0))
        detail = tk.Label(card, text=text, font=self.f_body, bg=PLATE_UP, fg=DIM, anchor="w")
        detail.pack(fill="x", padx=self.px(18), pady=(0, self.px(12)))
        parts = (card, accent, heading, detail)
        def hover(on):
            card.configure(highlightbackground=RED if on else EDGE)
            accent.configure(bg=RED if on else PLATE_UP)
            detail.configure(fg=FG if on else DIM)
        for part in parts:
            part.bind("<Enter>", lambda event: hover(True))
            part.bind("<Leave>", lambda event: hover(False))
            part.bind("<Button-1>", lambda event: command())
        return card

    def label(self, parent, text, style="body", color=None, **options):
        fonts = {"body": self.f_body, "small": self.f_small, "label": self.f_label, "status": (self.f_card[0], 15)}
        return tk.Label(parent, text=text, font=fonts[style], bg=parent.cget("bg"), fg=color or FG,
                        justify="left", anchor="w", **options)

    def section(self, parent, title):
        self.label(parent, title.upper(), "label", RED_HOT).pack(anchor="w", pady=(self.px(12), self.px(4)))
        rule = tk.Frame(parent, bg=EDGE, height=1)
        rule.pack(fill="x", pady=(0, self.px(6)))

    # ----- layout ---------------------------------------------------------
    def screen(self, title, subtitle=""):
        for child in self.body.winfo_children():
            child.destroy()
        frame = tk.Frame(self.body, bg=INK, padx=self.px(40), pady=self.px(26))
        frame.pack(fill="both", expand=True)
        tk.Label(frame, text=title.upper(), font=self.f_title, bg=INK, fg=WHITE, anchor="w").pack(fill="x")
        if subtitle:
            self.label(frame, subtitle, color=DIM, wraplength=self.px(640)).pack(anchor="w", pady=(self.px(2), 0))
        tk.Frame(frame, bg=RED, height=2, width=self.px(64)).pack(anchor="w", pady=(self.px(12), self.px(8)))
        return frame

    def footer(self, frame, back=True, start=None, start_text="Start"):
        row = tk.Frame(frame, bg=INK)
        row.pack(side="bottom", fill="x", pady=(self.px(14), 0))
        if back:
            self.button(row, "Back", self.home).pack(side="left")
        if start:
            self.button(row, start_text, start, primary=True).pack(side="right")
        return row

    def form(self, frame):
        grid = tk.Frame(frame, bg=INK)
        grid.pack(fill="x")
        grid.columnconfigure(0, minsize=self.px(190))
        grid.columnconfigure(1, weight=1)
        return grid

    def combo(self, grid, fields, label, labels, value):
        row = len(fields)
        self.label(grid, label.upper(), "label", DIM).grid(row=row, column=0, sticky="w", pady=self.px(3))
        box = ttk.Combobox(grid, values=list(labels.values()), state="readonly", width=34, font=self.f_body)
        box.set(labels.get(value, next(iter(labels.values()))))
        box.grid(row=row, column=1, sticky="w", pady=self.px(3))
        fields[label] = (box, labels)

    @staticmethod
    def pick(fields, label):
        box, labels = fields[label]
        return next(key for key, text in labels.items() if text == box.get())

    # ----- home -----------------------------------------------------------
    def home(self):
        frame = self.screen("Play", "Pick how you're playing, then what you want to do.")
        modes = tk.Frame(frame, bg=INK)
        modes.pack(fill="x", pady=(self.px(6), self.px(16)))
        chips = []
        def choose(value):
            self.vr.set(value)
            for chip in chips:
                chip.paint()
        for text, value in (("VR headset", True), ("Desktop - no headset", False)):
            chips.append(self.chip(modes, text, lambda value=value: self.vr.get() == value, lambda value=value: choose(value)))
            chips[-1].pack(side="left", padx=(0, self.px(10)))
        for title, text, command in (
                ("Join a friend", "Paste the code your friend sent you.", self.join),
                ("Host a game", "Start a game and get a code to send your friends.", lambda: self.options("host")),
                ("Play solo", "Practice on your own. No server, no download.", lambda: self.options("solo"))):
            self.card(frame, title, text, command).pack(fill="x", pady=self.px(6))
        tools = tk.Frame(frame, bg=INK)
        tools.pack(side="bottom", fill="x")
        for text, command in (("Settings", self.settings), (REPORT_BUTTON, self.send_logs),
                              ("Fix a stuck session", self.recover), ("Help", self.help)):
            self.button(tools, text, command, small=True).pack(side="left", padx=(0, self.px(8)))

    def help(self):
        for path in (OUTER / "READ ME FIRST.txt", ROOT / "docs/READ-ME-FIRST.txt"):
            if path.exists():
                os.startfile(path)
                return

    # ----- solo / host ----------------------------------------------------
    def need_game(self):
        game = game_folder()
        while not game:
            if not messagebox.askokcancel("Find Killing Floor 2",
                    "KF2-VR couldn't find Killing Floor 2.\n\nPress OK, then pick the 'killingfloor2' folder "
                    "(usually Steam\\steamapps\\common\\killingfloor2)."):
                return None
            picked = filedialog.askdirectory(title="Pick the killingfloor2 folder")
            if picked and (Path(picked) / "Binaries/Win64/KFGame.exe").exists():
                game = Path(picked)
            elif picked:
                messagebox.showwarning("Not that folder", "That folder doesn't contain Killing Floor 2. Try again.")
        return game

    def options(self, kind):
        from launch_menu import installed_maps, installed_solo_maps
        from workshop_loadout import MODS
        from workshop_map import MAP_NAME
        game = self.need_game()
        if not game:
            return
        solo = kind == "solo"
        maps = installed_solo_maps(game) if solo else installed_maps(game, self.saved.server_root)
        if not maps:
            messagebox.showerror("No maps", "No Killing Floor 2 maps were found in your game folder.")
            return
        frame = self.screen("Play solo" if solo else "Host a game",
            ("Practice on your own. No download needed." if solo else
             "The first time you host, KF2-VR downloads the free KF2 game server (about 32 GB). "
             "Your friends don't need it.") + ("  Playing in VR." if self.vr.get() else "  Playing on desktop."))
        self.section(frame, "Match")
        grid = self.form(frame)
        names = {m: m.removeprefix("KF-").replace("_", " ") + ("  (test map)" if m == MAP_NAME else "") for m in maps}
        current = MAP_NAME if self.saved.test_map else self.saved.map
        fields = {}
        self.combo(grid, fields, "Map", names, current if current in names else maps[0])
        self.combo(grid, fields, "Difficulty", DIFFICULTY_LABELS, self.saved.difficulty)
        self.combo(grid, fields, "Match length", LENGTH_LABELS, self.saved.game_length)
        if self.vr.get():
            self.section(frame, "Headset")
            grid = self.form(frame)
            self.combo(grid, fields, "Graphics", QUALITY_LABELS, self.saved.vr_quality)
            self.combo(grid, fields, "Render scale", {s: s for s in SCALES}, SCALES[0])
            self.label(frame, "Shared with Settings and in-game VR Controls > Graphics.",
                       "small", DIM, wraplength=self.px(600)).pack(anchor="w")
        extras = {}
        if self.vr.get():
            extras["threaded"] = tk.BooleanVar(value=bool(self.saved.threaded_render))
            ttk.Checkbutton(frame, text="Threaded rendering (experimental)",
                            variable=extras["threaded"]).pack(anchor="w", pady=(self.px(4), 0))
            self.label(frame, "OFF: portal see-through views. ON: flat portal fill; may improve frame rate.",
                       "small", DIM, wraplength=self.px(600)).pack(anchor="w")
        if not solo:
            self.section(frame, "Extras (optional)")
            for key, text, value in (
                    ("grabs", "VR players can grab Zeds (experimental)", self.saved.multiplayer_grabs),
                    ("focus", "Slow time while a VR player picks a weapon (experimental)", self.saved.inventory_focus)):
                extras[key] = tk.BooleanVar(value=bool(value))
                ttk.Checkbutton(frame, text=text, variable=extras[key]).pack(anchor="w")
            self.label(frame, "Mods - everyone downloads them automatically", "small", DIM).pack(anchor="w", pady=(self.px(8), self.px(2)))
            mods = tk.Frame(frame, bg=INK)
            mods.pack(anchor="w")
            for index, (key, (name, _, _)) in enumerate(MODS.items()):
                extras["mod:" + key] = tk.BooleanVar(value=key in (self.saved.mods or []))
                ttk.Checkbutton(mods, text=name, variable=extras["mod:" + key]).grid(
                    row=index // 3, column=index % 3, sticky="w", padx=(0, self.px(18)))
        else:
            self.section(frame, "Mods and experiments")
            extras["portal"] = tk.BooleanVar(value=bool(self.saved.portal_gun))
            ttk.Checkbutton(frame, text="Portal gun for sale at the trader (experimental, Solo only)",
                            variable=extras["portal"]).pack(anchor="w")
            self.label(frame, "Workshop mods apply to hosted games only.", "small", DIM).pack(anchor="w", pady=(self.px(4), 0))

        extras["breacher"] = tk.BooleanVar(value=bool(self.saved.breacher))
        ttk.Checkbutton(frame, text="Breacher (experimental; matching local package required for every player)",
                        variable=extras["breacher"]).pack(anchor="w", pady=(self.px(6), 0))

        # This opt-in belongs to one Solo VR launch and is never loaded/saved.
        extras["local_test_control"] = tk.BooleanVar(value=False)
        ttk.Checkbutton(frame, text="Local agent test control (Solo VR only; this launch)",
                        variable=extras["local_test_control"],
                        state="normal" if solo and self.vr.get() else "disabled").pack(
                            anchor="w", pady=(self.px(6), 0))
        self.label(frame, "UNRANKED test session; not saved. Hosted/Join control is unavailable.",
                   "small", DIM).pack(anchor="w")

        def start():
            if extras["local_test_control"].get() and not (solo and self.vr.get()):
                messagebox.showerror("Solo VR required", "Local agent test control is available in Solo VR only.")
                return
            pick = lambda label: self.pick(fields, label)
            arguments = ["--solo" if solo else "--host", "--vr" if self.vr.get() else "--desktop",
                         "--game-root", str(game), "--map", pick("Map"),
                         "--difficulty", pick("Difficulty"), "--game-length", pick("Match length")]
            if self.vr.get():
                arguments += ["--vr-quality", pick("Graphics")]
                if pick("Render scale") != SCALES[0]:
                    arguments += ["--eye-render-percent", pick("Render scale").rstrip("%")]
                arguments.append("--threaded-render" if extras["threaded"].get() else "--no-threaded-render")
            if not solo:
                arguments.append("--multiplayer-grabs" if extras["grabs"].get() else "--no-multiplayer-grabs")
                arguments.append("--inventory-focus" if extras["focus"].get() else "--no-inventory-focus")
                chosen = [key for key in MODS if extras["mod:" + key].get()]
                arguments += ["--mods", ",".join(chosen) or "none"]
            else:
                arguments.append("--portal-gun" if extras["portal"].get() else "--no-portal-gun")
            arguments.append("--breacher" if extras["breacher"].get() else "--no-breacher")
            if extras["local_test_control"].get():
                arguments.append("--local-test-control")
            self.run(arguments, "Solo" if solo else "Hosting")

        self.footer(frame, start=start, start_text="Start")

    # ----- join -----------------------------------------------------------
    def join(self):
        game = self.need_game()
        if not game:
            return
        frame = self.screen("Join a friend",
            "Your friend gets a code when they host. It starts with KF2VR1: - copy the whole thing and paste it here.")
        self.section(frame, "Join code")
        code = tk.StringVar()
        entry = ttk.Entry(frame, textvariable=code, font=self.f_body)
        entry.pack(fill="x")
        entry.focus_set()
        row = tk.Frame(frame, bg=INK)
        row.pack(fill="x", pady=self.px(10))

        def paste():
            try:
                code.set(self.clipboard_get().strip())
            except tk.TclError:
                messagebox.showinfo("Nothing copied", "Copy the code from your friend's message first.")
        self.button(row, "Paste code", paste, small=True).pack(side="left")
        address, password = tk.StringVar(), tk.StringVar()
        manual = tk.Frame(frame, bg=INK)

        def reveal():
            other.destroy()
            self.section(manual, "Address and password")
            grid = self.form(manual)
            for index, (text, variable) in enumerate((("Address", address), ("Password", password))):
                self.label(grid, text.upper(), "label", DIM).grid(row=index, column=0, sticky="w", pady=self.px(5))
                ttk.Entry(grid, textvariable=variable, width=30, font=self.f_body).grid(
                    row=index, column=1, sticky="w", pady=self.px(5))
            manual.pack(fill="x")
        other = self.label(frame, "No code? Use an address and password instead", "small", DIM, cursor="hand2")
        other.bind("<Button-1>", lambda event: reveal())
        other.bind("<Enter>", lambda event: other.configure(fg=RED_HOT))
        other.bind("<Leave>", lambda event: other.configure(fg=DIM))
        other.pack(anchor="w", pady=(self.px(14), 0))

        def start():
            text = re.sub(r"\s+", "", code.get())
            host, secret = address.get().strip(), password.get().strip()
            arguments = ["--vr" if self.vr.get() else "--desktop", "--game-root", str(game)]
            if text.startswith("KF2VR1:"):
                arguments += ["--address", text]
            elif not text and re.fullmatch(r"[A-Za-z0-9.-]+", host) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", secret):
                arguments += ["--address", host, "--password", secret]
            else:
                messagebox.showwarning("Check the code", "Paste the whole code from your friend. It starts with KF2VR1:")
                return
            self.run(arguments, "Joining")

        self.footer(frame, start=start, start_text="Join")

    # ----- running session ------------------------------------------------
    def run(self, arguments, title):
        if self.vr.get() and self.frame_timings.get():
            arguments.append("--frame-timings")
        LOGS.mkdir(exist_ok=True)
        self.log = LOGS / f"launcher-{datetime.now():%Y%m%d-%H%M%S}.txt"
        environment = dict(os.environ, PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8")
        with self.log.open("wb") as output:
            self.process = subprocess.Popen([str(PYTHON), "-u", str(HERE / "friends.py"), *arguments],
                cwd=ROOT, env=environment, stdin=subprocess.DEVNULL, stdout=output,
                stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
        self.download_log = None
        self.join_code = None
        frame = self.screen(title, "VR headset" if self.vr.get() else "Desktop")
        self.status = self.label(frame, "Starting...", "status", WHITE, wraplength=self.px(640))
        self.status.pack(anchor="w", pady=(self.px(10), 0))
        self.progress = ttk.Progressbar(frame, mode="indeterminate", style="Red.Horizontal.TProgressbar")
        self.progress.pack(fill="x", pady=self.px(16))
        self.progress.start(12)
        self.code_box = tk.Frame(frame, bg=INK)
        self.code_box.pack(fill="x")
        self.actions = tk.Frame(frame, bg=INK)
        self.actions.pack(side="bottom", fill="x", pady=(self.px(12), 0))
        self.details_shown = tk.BooleanVar(value=False)
        ttk.Checkbutton(frame, text="Show details", variable=self.details_shown,
                        command=self.toggle_details).pack(anchor="w", pady=(self.px(10), 0))
        self.details = tk.Text(frame, height=12, wrap="word", font=("Consolas", 9), state="disabled",
                               bg=PLATE, fg=DIM, relief="flat", highlightthickness=1, highlightbackground=EDGE,
                               padx=self.px(8), pady=self.px(6))
        self.poll()

    def toggle_details(self):
        if self.details_shown.get():
            self.details.pack(fill="both", expand=True, pady=(self.px(6), 0))
        else:
            self.details.pack_forget()

    def poll(self):
        text = self.log.read_text(encoding="utf-8", errors="replace") if self.log.exists() else ""
        self.details.configure(state="normal")
        self.details.delete("1.0", "end")
        self.details.insert("end", text)
        self.details.see("end")
        self.details.configure(state="disabled")
        message = next((status for line in reversed(text.splitlines())
                        for key, status in reversed(STATUS) if line.startswith(key)), None)
        if message:
            self.status.configure(text=message)
        found = re.findall(r"^Download log: (.+)$", text, re.M)
        if found:
            self.download_log = Path(found[-1].strip())
        self.show_download()
        if "Host ready" in text and not self.join_code:
            self.show_join_code()
        if self.process.poll() is None:
            self.after(400, self.poll)
            return
        self.progress.stop()
        self.progress.configure(mode="determinate", value=100)
        # A finished host's code no longer works; don't leave it up to be shared.
        for child in self.code_box.winfo_children():
            child.destroy()
        errors = re.findall(r"Could not start/finish KF2-VR: (.*)", text)
        if self.process.returncode == 0:
            self.status.configure(text="All done. Killing Floor 2 is back to normal.\nYou can close this window.")
        else:
            self.progress.pack_forget()
            self.status.configure(fg=RED_HOT, text="Something went wrong")
            self.label(self.code_box, friendly(errors[-1].strip() if errors else "")
                       + f"\n\nIf it keeps happening, press '{REPORT_BUTTON}'.",
                       wraplength=self.px(640)).pack(anchor="w", pady=(self.px(10), 0))
            self.button(self.actions, REPORT_BUTTON, self.send_logs, primary=True).pack(side="right")
        self.process = None
        self.button(self.actions, "Back to start", self.home).pack(side="left")

    def show_download(self):
        if not self.download_log or not self.download_log.exists() or not self.process or self.process.poll() is not None:
            return
        with self.download_log.open("rb") as handle:
            handle.seek(max(0, self.download_log.stat().st_size - 8192))
            tail = handle.read().decode("utf-8", errors="replace")
        percent = re.findall(r"progress: (\d+(?:\.\d+)?)", tail)
        if percent and self.status.cget("text").startswith("Downloading the game server"):
            self.progress.stop()
            self.progress.configure(mode="determinate", value=float(percent[-1]))

    def show_join_code(self):
        path = ROOT / "JOIN-SERVER.txt"
        found = re.findall(r"KF2VR1:\S+", path.read_text(encoding="utf-8")) if path.exists() else []
        self.join_code = found[-1] if found else "none"
        box = tk.Frame(self.code_box, bg=PLATE_UP, highlightthickness=1, highlightbackground=RED,
                       padx=self.px(16), pady=self.px(12))
        box.pack(fill="x", pady=(self.px(4), 0))
        self.label(box, "CODE FOR YOUR FRIENDS", "label", RED_HOT).pack(anchor="w")
        self.label(box, "Keep it private - it has your game's password.", "small", DIM).pack(anchor="w")
        if not found:
            self.label(box, "KF2-VR couldn't work out your internet address, so there's no code this time. "
                            f"Press '{REPORT_BUTTON}'. {REPORT_WHERE}.", wraplength=self.px(600)).pack(anchor="w", pady=(self.px(6), 0))
            return
        self.code_text = tk.StringVar(value=self.join_code)
        ttk.Entry(box, textvariable=self.code_text, state="readonly", font=self.f_body).pack(fill="x", pady=(self.px(8), 0))
        row = tk.Frame(box, bg=PLATE_UP)
        row.pack(fill="x", pady=(self.px(8), 0))
        copied = self.label(row, "", "small", FG)

        def copy():
            self.clipboard_clear()
            self.clipboard_append(self.join_code)
            copied.configure(text="Copied! Paste it to your friends in Discord.")
        self.button(row, "Copy code", copy, primary=True, small=True).pack(side="left")
        copied.pack(side="left", padx=self.px(12))
        self.label(box, "Friends on the internet also need UDP ports 7777 and 27015 forwarded to this PC "
                        "in your router.", "small", MUTE, wraplength=self.px(600)).pack(anchor="w", pady=(self.px(8), 0))

    def on_close(self):
        if self.process and self.process.poll() is None and not messagebox.askyesno("KF2-VR is still running",
                "KF2-VR is still running.\n\nIt's safe to close this window: the game keeps going and "
                "tidies up after itself when you quit it.\n\nClose this window?"):
            return
        self.destroy()

    # ----- settings -------------------------------------------------------
    def settings(self):
        from session import read_ini, set_ini
        from vr_config import apply_preferences, profile_root, values
        root = profile_root()
        root.mkdir(parents=True, exist_ok=True)
        path = root / "KFGame.ini"
        text = apply_preferences("", read_ini(path) if path.exists() else "")
        hands = values(text, "KF2VR.VRHandsBridge")
        session = values(text, "KF2VR.VRSessionUI")
        frame = self.screen("VR settings", "These are also in the headset under VR Controls.")
        self.section(frame, "Hands and aim")
        grid = self.form(frame)
        aims = {"Relaxed": "Relaxed wrist (like Arizona Sunshine 2)", "Neutral": "Straight", "Quest2": "Older Quest 2 angle"}
        sides = {"0": "Left hand", "1": "Right hand"}
        fields = {}
        self.combo(grid, fields, "Gun aim angle", aims, hands.get("ActiveControllerFitProfile", "Neutral"))
        self.combo(grid, fields, "Walk with", sides, hands.get("MovementHand", "0"))
        self.combo(grid, fields, "Main gun hand", sides, hands.get("PreferredWeaponHand", "1"))
        self.section(frame, "Comfort and graphics")
        grid = self.form(frame)
        self.combo(grid, fields, "Turning", {"True": "Snap turn", "False": "Smooth turn"},
                   session.get("bSnapTurn", "True").capitalize())
        self.combo(grid, fields, "Render scale", {str(n): f"{n}%" for n in range(100, 49, -5)},
                   session.get("EyeRenderPercent", "75"))
        self.label(frame, "Shared with Play solo / Host and in-game VR Controls > Graphics.",
                   "small", DIM, wraplength=self.px(600)).pack(anchor="w")
        self.section(frame, "Other")
        grab = tk.BooleanVar(value=hands.get("bZedGrabEnabled", "True").lower() == "true")
        ttk.Checkbutton(frame, text="Grab Zeds in Solo (the host decides for online games)", variable=grab).pack(anchor="w")
        ttk.Checkbutton(frame, text="Record performance data for bug reports (VR, until you close this window)",
                        variable=self.frame_timings).pack(anchor="w")

        def save():
            nonlocal text
            pick = lambda label: self.pick(fields, label)
            pitch = {"Relaxed": "-20.6", "Neutral": "0.0", "Quest2": "-8.6"}[pick("Gun aim angle")]
            updated = set_ini(text, "KF2VR.VRHandsBridge", {
                "ActiveControllerFitProfile": pick("Gun aim angle"), "FirearmAimPitchDegrees": pitch,
                "FirearmAimYawDegrees": "0.0", "FirearmAimRollDegrees": "0.0",
                "MovementHand": pick("Walk with"), "PreferredWeaponHand": pick("Main gun hand"),
                "bZedGrabEnabled": "True" if grab.get() else "False"})
            updated = set_ini(updated, "KF2VR.VRSessionUI", {
                "bSnapTurn": pick("Turning"), "EyeRenderPercent": pick("Render scale")})
            text = apply_preferences(updated)
            temporary = path.with_suffix(".tmp")
            temporary.write_text(text, encoding="utf-16")
            temporary.replace(path)
            self.home()

        self.footer(frame, start=save, start_text="Save")

    # ----- troubleshooting ------------------------------------------------
    def send_logs(self):
        from diagnostics import collect_logs
        try:
            target = collect_logs(ROOT, OUTER)
        except Exception as error:
            messagebox.showerror("Couldn't gather logs", str(error))
            return
        copied = subprocess.run(["powershell.exe", "-NoProfile", "-Command", "Set-Clipboard -LiteralPath $env:KF2VR_LOGS"],
                                env=dict(os.environ, KF2VR_LOGS=str(target)), creationflags=NO_WINDOW).returncode == 0
        subprocess.Popen(["explorer.exe", "/select,", str(target)])
        messagebox.showinfo("Logs ready",
            (f"Your logs are copied.\n\n{REPORT_WHERE}. Click in the message box, "
             "press Ctrl+V, then press Enter. Say what you were doing when it went wrong.\n\n" if copied else
             f"{REPORT_WHERE}. Drag the highlighted file into your bug report.\n\n")
            + f"The file is also in the folder that just opened:\n{target.name}\n\n"
            "Personal paths, known usernames/player names, account IDs and network addresses are anonymized; "
            "passwords and recognized tokens/join codes are removed. Original logs stay on your PC. "
            "Review the ZIP before sharing: free-form messages may contain other personal details.")

    def recover(self):
        import contextlib
        import io
        from recovery import recover_all
        if self.process and self.process.poll() is None:
            messagebox.showinfo("Still running", "Wait for the current game to close first.")
            return
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                recover_all(ROOT)
        except Exception as error:
            messagebox.showerror("Couldn't fix it yet", friendly(str(error)))
            return
        problems = [line for line in output.getvalue().splitlines() if "restored / already clean" not in line]
        if problems:
            messagebox.showwarning("Partly fixed", "Some things couldn't be fixed automatically. "
                                   f"Press '{REPORT_BUTTON}'.\n\n" + "\n".join(problems[:6]))
        else:
            messagebox.showinfo("All fixed", "Killing Floor 2 is back to normal.")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        pass
    if "--self-check" in argv:
        # Packaging check: build every screen without launching anything.
        window = Launcher(art=False)
        window.withdraw()
        window.settings()
        window.home()
        window.update_idletasks()
        window.destroy()
        return 0
    Launcher().mainloop()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        LOGS.mkdir(parents=True, exist_ok=True)
        import traceback
        (LOGS / "window-error.txt").write_text(traceback.format_exc(), encoding="utf-8")
        ctypes.windll.user32.MessageBoxW(None, f"KF2-VR couldn't open its window:\n\n{error}\n\n"
            "Use Save logs for a bug report when the launcher opens again. "
            "If you share app\\logs\\window-error.txt manually, review and remove personal details first.", "KF2-VR", 0x10)
        raise SystemExit(1)

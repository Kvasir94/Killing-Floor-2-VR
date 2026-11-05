"""The player window's visual system: colour tokens, type scale, spacing and the Qt style sheet.

One dark KF2 palette with a single red accent. Text colours keep at least
4.5:1 contrast on every surface they sit on. Sizes are logical pixels, so Qt
scales them crisply on high-DPI screens. Capitalisation: sentence case for
titles, labels and buttons; capitals only for the small section labels.
"""
from PySide6.QtGui import QColor, QFont, QFontDatabase, QPalette

# Surfaces, darkest first.
INK = "#0f0f12"        # page background
RAIL = "#141418"       # sidebar
PANEL = "#18181d"      # grouped rows, cards at rest
RAISED = "#1f1f26"     # cards, dialogs, popups
FIELD = "#26262e"      # inputs and unselected segments
HOVER = "#2e2e37"
PRESSED = "#363640"
LINE = "#2b2b33"
LINE_STRONG = "#454550"
# Text, from primary to disabled.
WHITE = "#ffffff"
TEXT = "#f1f1f4"
TEXT_2 = "#c6c6cf"
TEXT_3 = "#9d9da8"
DISABLED = "#6a6a74"
# Accents.
RED = "#c8302f"
RED_HOVER = "#d93d36"
RED_PRESSED = "#a92525"
RED_TEXT = "#f06456"   # red used as text on dark surfaces
FOCUS = "#c9c9d4"      # keyboard focus: never red, which means danger or error
RED_SOFT = "#34171a"
AMBER = "#ebb35e"
AMBER_SOFT = "#2a2215"
AMBER_LINE = "#5c4721"
GREEN = "#7fd193"
GREEN_SOFT = "#16261c"
GREEN_LINE = "#2c5537"
BLUE = "#9cb7e0"
BLUE_SOFT = "#182030"
BLUE_LINE = "#2f4163"

# Spacing grid (4 px) and layout.
S1, S2, S3, S4, S5, S6, S8 = 4, 8, 12, 16, 20, 24, 32
RADIUS = 8
RAIL_WIDTH = 248
RAIL_NARROW = 200       # the sidebar on windows narrower than NARROW_WINDOW
NARROW_WINDOW = 1100
BRAND_HEIGHT = 196       # the sidebar art slot: KF2's logo over its wallpaper, or the KF2-VR mark
COLUMN = 1200           # the content column stops growing here and centres
GUTTER = 40             # minimum space either side of the column
NARROW_GUTTER = 20      # ... once the page is narrower than NARROW
NARROW = 760            # page width below which side space shrinks and rows stack
MIN_WIDTH, MIN_HEIGHT = 800, 600   # smallest window: a 1366x768 laptop, or 1920x1080 at 150%
CONTROL_WIDTH = 260     # every dropdown in a settings row lines up

# Type scale (px).
TITLE, H2, H3, BODY, SMALL, OVERLINE = 26, 17, 15, 14, 13, 11
FAMILY = "Segoe UI"
DISPLAY = "Segoe UI"


def choose_families():
    """Segoe UI Variable on Windows 11, Segoe UI on Windows 10."""
    global FAMILY, DISPLAY
    families = set(QFontDatabase.families())
    if "Segoe UI Variable Text" in families:
        FAMILY = "Segoe UI Variable Text"
    if "Segoe UI Variable Display" in families:
        DISPLAY = "Segoe UI Variable Display"
    return FAMILY


def font(size=BODY, weight=QFont.Weight.Normal, display=False, spacing=0.0):
    value = QFont(DISPLAY if display else FAMILY)
    value.setPixelSize(size)
    value.setWeight(weight)
    value.setHintingPreference(QFont.HintingPreference.PreferNoHinting)
    if spacing:
        value.setLetterSpacing(QFont.SpacingType.AbsoluteSpacing, spacing)
    return value


def palette():
    colors = QPalette()
    for role, value in ((QPalette.ColorRole.Window, INK), (QPalette.ColorRole.WindowText, TEXT),
                        (QPalette.ColorRole.Base, FIELD), (QPalette.ColorRole.AlternateBase, PANEL),
                        (QPalette.ColorRole.Text, TEXT), (QPalette.ColorRole.Button, RAISED),
                        (QPalette.ColorRole.ButtonText, TEXT), (QPalette.ColorRole.Highlight, RED),
                        (QPalette.ColorRole.HighlightedText, WHITE), (QPalette.ColorRole.ToolTipBase, RAISED),
                        (QPalette.ColorRole.ToolTipText, TEXT), (QPalette.ColorRole.PlaceholderText, TEXT_3),
                        (QPalette.ColorRole.Link, RED_TEXT), (QPalette.ColorRole.BrightText, WHITE)):
        colors.setColor(role, QColor(value))
    for role in (QPalette.ColorRole.WindowText, QPalette.ColorRole.Text, QPalette.ColorRole.ButtonText):
        colors.setColor(QPalette.ColorGroup.Disabled, role, QColor(DISABLED))
    return colors


def stylesheet():
    return f"""
* {{ font-family: "{FAMILY}"; font-size: {BODY}px; color: {TEXT}; }}
QMainWindow, #Content, QStackedWidget {{ background: {INK}; }}
QToolTip {{ background: {RAISED}; color: {TEXT}; border: 1px solid {LINE_STRONG}; padding: 6px 8px; border-radius: 6px; }}
QLabel {{ background: transparent; }}
QLabel[role="title"] {{ font-family: "{DISPLAY}"; font-size: {TITLE}px; font-weight: 600; color: {WHITE}; }}
QLabel[role="lead"] {{ font-size: {BODY}px; color: {TEXT_2}; }}
QLabel[role="h2"] {{ font-family: "{DISPLAY}"; font-size: {H2}px; font-weight: 600; color: {WHITE}; }}
QLabel[role="h3"] {{ font-size: {H3}px; font-weight: 600; color: {TEXT}; }}
QLabel[role="body"] {{ color: {TEXT}; }}
QLabel[role="help"] {{ font-size: {SMALL}px; color: {TEXT_2}; }}
QLabel[role="muted"] {{ font-size: {SMALL}px; color: {TEXT_3}; }}
QLabel[role="overline"] {{ font-size: {OVERLINE}px; font-weight: 700; color: {TEXT_3}; letter-spacing: 1.4px; }}
QLabel[role="kicker"] {{ font-size: {OVERLINE}px; font-weight: 700; color: {RED_TEXT}; letter-spacing: 1.4px; }}
QLabel[tone="ok"] {{ color: {GREEN}; }}
QLabel[tone="warn"] {{ color: {AMBER}; }}
QLabel[tone="error"] {{ color: {RED_TEXT}; }}
QLabel[role="tag"] {{ font-size: 12px; font-weight: 600; color: {TEXT_2}; background: {FIELD};
    border-radius: 4px; padding: 1px 7px; }}
QLabel[role="tag"][tone="warn"] {{ color: {AMBER}; background: {AMBER_SOFT}; }}
QLabel[role="tag"][tone="ok"] {{ color: {GREEN}; background: {GREEN_SOFT}; }}
QLabel[role="tag"][tone="accent"] {{ color: {WHITE}; background: {RED}; }}
QLabel[role="mono"] {{ font-family: "Cascadia Mono", "Consolas"; font-size: 13px; color: {TEXT}; }}

QPushButton {{ font-size: {BODY}px; font-weight: 600; color: {TEXT}; background: {RAISED};
    border: 1px solid {LINE_STRONG}; border-radius: {RADIUS}px; padding: 0 18px; min-height: 36px; }}
QPushButton:hover {{ background: {HOVER}; border-color: #5b5b68; }}
QPushButton:pressed {{ background: {PRESSED}; }}
QPushButton:focus {{ border-color: {FOCUS}; }}
QPushButton:disabled {{ color: {DISABLED}; background: {PANEL}; border-color: {LINE}; }}
QPushButton[kind="primary"] {{ color: {WHITE}; background: {RED}; border-color: {RED}; }}
QPushButton[kind="primary"]:hover {{ background: {RED_HOVER}; border-color: {RED_HOVER}; }}
QPushButton[kind="primary"]:pressed {{ background: {RED_PRESSED}; border-color: {RED_PRESSED}; }}
QPushButton[kind="primary"]:focus {{ border-color: {WHITE}; }}
QPushButton[kind="primary"]:disabled {{ color: {TEXT_3}; background: {RAISED}; border-color: {LINE_STRONG}; }}
QPushButton[kind="ghost"] {{ background: transparent; border-color: transparent; color: {TEXT_2}; }}
QPushButton[kind="ghost"]:hover {{ background: {HOVER}; color: {TEXT}; }}
QPushButton[kind="ghost"]:focus {{ border-color: {FOCUS}; }}
QPushButton[kind="danger"] {{ background: transparent; color: #ff8f84; border-color: #6c2c2b; }}
QPushButton[kind="danger"]:hover {{ background: {RED_SOFT}; border-color: #8a3532; }}
QPushButton[kind="danger"]:disabled {{ color: {DISABLED}; border-color: {LINE}; }}
QPushButton[kind="dangerfill"] {{ color: {WHITE}; background: #a72a29; border-color: #a72a29; }}
QPushButton[kind="dangerfill"]:hover {{ background: #bf3330; border-color: #bf3330; }}
QPushButton[kind="link"] {{ background: transparent; border: none; color: {RED_TEXT}; padding: 0; min-height: 22px;
    font-weight: 600; text-align: left; }}
QPushButton[kind="link"]:hover {{ color: #ff8a7d; text-decoration: underline; }}
QPushButton[kind="link"]:focus {{ text-decoration: underline; }}
QPushButton[kind="link"]:disabled {{ color: {DISABLED}; }}
QPushButton[size="lg"] {{ min-height: 48px; font-size: 16px; padding: 0 30px; border-radius: 10px; }}
QPushButton[size="sm"] {{ min-height: 30px; font-size: {SMALL}px; padding: 0 12px; border-radius: 6px; }}

QPushButton[seg="true"] {{ background: {FIELD}; color: {TEXT_2}; border: 1px solid {LINE_STRONG}; border-radius: 0;
    min-height: 34px; padding: 0 16px; font-weight: 600; }}
QPushButton[seg="true"][pos="first"] {{ border-top-left-radius: {RADIUS}px; border-bottom-left-radius: {RADIUS}px; }}
QPushButton[seg="true"][pos="last"] {{ border-top-right-radius: {RADIUS}px; border-bottom-right-radius: {RADIUS}px; }}
QPushButton[seg="true"][pos="only"] {{ border-radius: {RADIUS}px; }}
QPushButton[seg="true"]:hover {{ background: {HOVER}; color: {TEXT}; }}
QPushButton[seg="true"]:checked {{ background: {RED}; color: {WHITE}; border-color: {RED}; }}
QPushButton[seg="true"]:checked:hover {{ background: {RED_HOVER}; border-color: {RED_HOVER}; }}
QPushButton[seg="true"]:focus {{ border-color: {FOCUS}; }}
QPushButton[seg="true"]:disabled {{ color: {DISABLED}; background: {PANEL}; border-color: {LINE}; }}
QPushButton[seg="true"]:checked:disabled {{ color: {TEXT}; background: {RAISED}; border: 1px solid {TEXT_3}; }}

QPushButton[nav="true"] {{ background: transparent; border: none; border-radius: 0; text-align: left;
    padding: 0 0 0 26px; min-height: 44px; font-size: 15px; font-weight: 600; color: {TEXT_2}; }}
QPushButton[nav="true"]:hover {{ background: {PANEL}; color: {TEXT}; }}
QPushButton[nav="true"]:checked {{ background: {RAISED}; color: {WHITE}; border-left: 3px solid {RED};
    padding-left: 23px; }}
QPushButton[nav="true"]:focus {{ color: {WHITE}; }}

QPushButton[tab="true"] {{ background: transparent; border: none; border-bottom: 2px solid transparent; border-radius: 0;
    padding: 0 2px; margin-right: 20px; min-height: 38px; font-size: 15px; font-weight: 600; color: {TEXT_2}; }}
QPushButton[tab="true"]:hover {{ color: {TEXT}; border-bottom-color: {LINE_STRONG}; }}
QPushButton[tab="true"]:checked {{ color: {WHITE}; border-bottom-color: {RED}; }}
QPushButton[tab="true"]:focus {{ color: {WHITE}; }}

QLineEdit {{ background: {FIELD}; color: {TEXT}; border: 1px solid {LINE_STRONG}; border-radius: {RADIUS}px;
    padding: 0 10px; min-height: 36px; selection-background-color: {RED}; }}
QLineEdit:hover {{ border-color: #5b5b68; }}
QLineEdit:focus {{ border-color: {FOCUS}; }}
QLineEdit:disabled {{ color: {DISABLED}; background: {PANEL}; border-color: {LINE}; }}
QLineEdit[invalid="true"] {{ border-color: {AMBER}; }}
QLineEdit[readOnly="true"] {{ background: {PANEL}; }}

QComboBox {{ background: {FIELD}; color: {TEXT}; border: 1px solid {LINE_STRONG}; border-radius: {RADIUS}px;
    padding: 0 34px 0 12px; min-height: 36px; }}
QComboBox:hover {{ border-color: #5b5b68; background: {HOVER}; }}
QComboBox:focus {{ border-color: {FOCUS}; }}
QComboBox:on {{ border-color: {FOCUS}; }}
QComboBox:disabled {{ color: {DISABLED}; background: {PANEL}; border-color: {LINE}; }}
QComboBox::drop-down {{ border: none; width: 30px; }}
QComboBox::down-arrow {{ image: none; width: 0; height: 0; }}
QComboBox QAbstractItemView {{ background: {RAISED}; border: 1px solid {LINE_STRONG}; outline: 0; padding: 4px;
    selection-background-color: {HOVER}; selection-color: {WHITE}; }}

QScrollArea, QScrollArea > QWidget > QWidget#Column {{ background: transparent; border: none; }}
QScrollBar:vertical {{ background: transparent; width: 12px; margin: 2px 2px 2px 0; }}
QScrollBar::handle:vertical {{ background: #62626e; border-radius: 4px; min-height: 40px; margin: 0 2px; }}
QScrollBar::handle:vertical:hover {{ background: #7a7a86; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}
QScrollBar:horizontal {{ height: 0; }}

QProgressBar {{ background: {LINE}; border: none; border-radius: 3px; max-height: 6px; min-height: 6px; }}
QProgressBar::chunk {{ background: {RED}; border-radius: 3px; }}

QPlainTextEdit {{ background: {PANEL}; color: {TEXT_2}; border: 1px solid {LINE}; border-radius: {RADIUS}px;
    font-family: "Cascadia Mono", "Consolas"; font-size: 12px; padding: 8px; selection-background-color: {RED}; }}

QFrame#Panel {{ background: {PANEL}; border: 1px solid {LINE}; border-radius: 10px; }}
QFrame#Card {{ background: {RAISED}; border: 1px solid {LINE}; border-radius: 10px; }}
QFrame#Card[hover="true"] {{ background: {HOVER}; border-color: #5b5b68; }}
QFrame#Card[selected="true"] {{ border: 1px solid {RED}; background: #24191c; }}
QFrame#Card[disabled="true"] {{ background: {PANEL}; }}
QFrame#Card:focus {{ border-color: {FOCUS}; }}
QFrame#Hero {{ background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #2a1416, stop:1 {RAISED});
    border: 1px solid #4a2427; border-radius: 12px; }}
QFrame#Placeholder {{ background: transparent; border: 1px dashed {LINE_STRONG}; border-radius: 10px; }}
QFrame#Callout {{ border-radius: 10px; border: 1px solid {LINE_STRONG}; background: {RAISED}; }}
QFrame#Callout[tone="warn"] {{ background: {AMBER_SOFT}; border-color: {AMBER_LINE}; }}
QFrame#Callout[tone="ok"] {{ background: {GREEN_SOFT}; border-color: {GREEN_LINE}; }}
QFrame#Callout[tone="info"] {{ background: {BLUE_SOFT}; border-color: {BLUE_LINE}; }}
QFrame#Callout[tone="error"] {{ background: {RED_SOFT}; border-color: #6c2c2b; }}
QFrame#Rule {{ background: {LINE}; border: none; max-height: 1px; min-height: 1px; }}
QFrame#Footer {{ background: {INK}; border-top: 1px solid {LINE}; }}
QFrame#Rail {{ background: {RAIL}; border-right: 1px solid #241316; }}
QWidget#Dialog {{ background: {RAISED}; border: 1px solid {LINE_STRONG}; border-radius: 12px; }}
QFrame#CodeBox {{ background: {RAISED}; border: 1px solid {RED}; border-radius: 10px; }}
"""


def apply(app):
    from PySide6.QtWidgets import QStyleFactory
    choose_families()
    app.setStyle(QStyleFactory.create("Fusion"))
    app.setPalette(palette())
    app.setFont(font())
    app.setStyleSheet(stylesheet())

"""Killing Floor 2's own art, read at run time from the player's install: never shipped with KF2-VR.

The sidebar header uses the game's wallpaper (KF2's Wallpaper folder) under Steam's cached library logo;
the Quick start card uses the same wallpaper, darkened. Without the game, the KF2-VR mark stands in.
"""
from pathlib import Path

WALLPAPERS = ("KF2-Wallpaper1920x1080.jpg", "KF2-Wallpaper1680x1050.jpg", "KF2-Wallpaper1600x1200.jpg",
              "KF2-Wallpaper1280x720.jpg")
STEAM_APP = "232090"


def steam_cache():
    """Steam's library cache folder for Killing Floor 2 on this PC, or None."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            steam = Path(winreg.QueryValueEx(key, "SteamPath")[0])
    except (OSError, ImportError):
        return None
    cache = steam / "appcache/librarycache" / STEAM_APP
    return cache if cache.is_dir() else None


def steam_logo():
    """Steam's own library logo for Killing Floor 2, when this PC has one cached."""
    cache = steam_cache()
    if cache is None:
        return None
    if (cache / "logo.png").is_file():
        return cache / "logo.png"
    return next(iter(sorted(cache.rglob("logo.png"))), None)


def wallpaper(game):
    """The game's own wallpaper, largest first, or None."""
    for name in WALLPAPERS:
        path = Path(game) / "Wallpaper" / name if game else None
        if path is not None and path.is_file():
            return path
    return None


def art_folder(state):
    """A game folder whose wallpaper can dress the launcher: the chosen copy, else any copy that has one."""
    install, _ = state.resolve_game()
    folders = ([install.root] if install else []) + [found.root for found in state.installs()]
    return next((folder for folder in folders if (Path(folder) / "Wallpaper").is_dir()), None)


def compose_brand(game, width, ratio):
    """(image, has_logo) for the sidebar header. With the game: a wallpaper crop, darkened and faded, under
    KF2's logo and "VIRTUAL REALITY". Without it: the KF2-VR mark and wordmark, shorter, no tagline."""
    from PySide6.QtCore import QRectF, Qt
    from PySide6.QtGui import QColor, QFont, QImage, QLinearGradient, QPainter
    import launcher_app as app
    import launcher_ui_theme as T
    logo_path = steam_logo() if game else None
    logo = QImage(str(logo_path)) if logo_path else QImage()
    art_path = wallpaper(game)
    art = QImage(str(art_path)) if art_path else QImage()
    has_logo = not logo.isNull()
    height = T.BRAND_HEIGHT   # the same slot with or without the game, so the nav never moves
    w, h = int(width * ratio), int(height * ratio)
    image = QImage(w, h, QImage.Format.Format_ARGB32_Premultiplied)
    image.fill(QColor(T.RAIL))
    painter = QPainter(image)
    painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    if not art.isNull():
        source_h = art.height() * 0.5
        source_w = source_h * w / h
        left = max(0.0, min(art.width() - source_w, art.width() * 0.66 - source_w / 2))
        painter.drawImage(QRectF(0, 0, w, h), art, QRectF(left, art.height() * 0.08, source_w, source_h))
        painter.fillRect(0, 0, w, h, QColor(10, 10, 12, 165))
        fade = QLinearGradient(0, h * 0.35, 0, h)
        fade.setColorAt(0, QColor(20, 20, 24, 0))
        fade.setColorAt(1, QColor(T.RAIL))
        painter.fillRect(0, 0, w, h, fade)
    if has_logo:
        lw = w * 0.76
        lh = lw * logo.height() / logo.width()
        painter.drawImage(QRectF((w - lw) / 2, h * 0.40 - lh / 2, lw, lh), logo)
        painter.setPen(QColor(T.RED_TEXT))
        painter.setFont(T.font(int(11 * ratio), QFont.Weight.Bold, spacing=3.2))
        painter.drawText(QRectF(0, h - 40 * ratio, w, 20 * ratio), Qt.AlignmentFlag.AlignCenter, "VIRTUAL REALITY")
    else:
        # The KF2-VR mark fills the art slot: the icon where KF2's logo sits, the wordmark on the tagline line.
        icon = QImage(str(app.ICON))
        if not icon.isNull():
            size = 84 * ratio
            painter.drawImage(QRectF((w - size) / 2, h * 0.40 - size / 2, size, size), icon)
        painter.setPen(QColor(T.WHITE))
        painter.setFont(T.font(int(26 * ratio), QFont.Weight.Bold, display=True))
        painter.drawText(QRectF(0, h * 0.66, w, h * 0.22), Qt.AlignmentFlag.AlignCenter | Qt.TextFlag.TextSingleLine,
                         "KF2-VR")
    painter.end()
    return image, has_logo


def hero_image(game):
    """The wallpaper for the Quick start card as a QImage, or a null QImage without the game."""
    from PySide6.QtGui import QImage
    path = wallpaper(game)
    return QImage(str(path)) if path else QImage()

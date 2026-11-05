"""Draws the Workshop page's step-by-step setup picture (docs/workshop/setup-guide.png)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parents[2] / "docs" / "workshop" / "setup-guide.png"
W, H = 1280, 1180
BG, CARD, TEXT, DIM, RED, GREEN = (17, 17, 17), (34, 34, 34), (238, 238, 238), (160, 160, 160), (178, 34, 34), (90, 130, 30)
FONTS = Path(r"C:\Windows\Fonts")


def font(size, bold=False):
    return ImageFont.truetype(str(FONTS / ("segoeuib.ttf" if bold else "segoeui.ttf")), size)


def key(draw, x, y, label, w=None):
    w = w or 26 + int(draw.textlength(label, font=font(30, True)))
    draw.rounded_rectangle((x, y, x + w, y + 64), 10, fill=(60, 60, 60), outline=(120, 120, 120), width=3)
    draw.rounded_rectangle((x + 4, y + 4, x + w - 4, y + 54), 8, fill=(80, 80, 80))
    draw.text((x + w / 2, y + 30), label, fill=TEXT, font=font(30, True), anchor="mm")
    return x + w


def button(draw, x, y, label, fill, w=260, h=60):
    draw.rounded_rectangle((x, y, x + w, y + h), 8, fill=fill)
    draw.text((x + w / 2, y + h / 2), label, fill="white", font=font(28, True), anchor="mm")


def main():
    image = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(image)
    draw.text((W / 2, 60), "KF2VR - VR setup", fill=TEXT, font=font(52, True), anchor="mm")
    draw.text((W / 2, 112), "Do this once. Desktop players only need step 1.", fill=DIM, font=font(28), anchor="mm")
    top, step_h = 160, 196
    steps = ["Click Subscribe. Press Play on Killing Floor 2 once, then quit (Steam downloads it).",
             "In Steam: right-click Killing Floor 2 > Manage > Browse local files.",
             "Click steamapps in the address bar, then open these folders in order:",
             "Exit Steam. Run Setup KF2VR and select your Steam account. Then reopen Steam.",
             "Press Play on Killing Floor 2 and pick Play in VR."]
    for i, words in enumerate(steps):
        y = top + i * step_h
        draw.rounded_rectangle((40, y, W - 40, y + step_h - 20), 16, fill=CARD)
        draw.ellipse((70, y + 52, 142, y + 124), fill=RED)
        draw.text((106, y + 88), str(i + 1), fill="white", font=font(40, True), anchor="mm")
        draw.text((175, y + 30), words, fill=TEXT, font=font(27))
        vy = y + 88
        if i == 0:
            button(draw, 175, vy, "+ Subscribe", GREEN)
        elif i == 1:
            x = 175
            for label in ("Killing Floor 2", "Manage", "Browse local files"):
                w = 40 + int(draw.textlength(label, font=font(26, True)))
                draw.rounded_rectangle((x, vy, x + w, vy + 60), 8, fill=(60, 60, 60))
                draw.text((x + w / 2, vy + 30), label, fill="white", font=font(26, True), anchor="mm")
                x += w
                if label != "Browse local files":
                    draw.text((x + 22, vy + 30), ">", fill=TEXT, font=font(34, True), anchor="mm"); x += 44
        elif i == 2:
            draw.rectangle((175, vy, 1215, vy + 60), fill=(240, 240, 240), outline=(90, 90, 90), width=2)
            parts = [("...", False), ("steamapps", True), ("workshop", False), ("content", False),
                     ("232090", False), ("3817663661", False)]
            x = 190
            for k, (label, hot) in enumerate(parts):
                f = font(24, True)
                w = int(draw.textlength(label, font=f))
                if hot:
                    draw.rounded_rectangle((x - 8, vy + 10, x + w + 8, vy + 50), 6, fill=(204, 228, 247), outline=(0, 120, 215), width=2)
                draw.text((x, vy + 30), label, fill=(20, 20, 20), font=f, anchor="lm")
                x += w + 14
                if k < len(parts) - 1:
                    draw.text((x + 4, vy + 30), ">", fill=(90, 90, 90), font=font(24, True), anchor="mm"); x += 24
        elif i == 3:
            draw.rounded_rectangle((175, vy - 4, 205, vy + 60), 4, fill=(220, 220, 220))
            draw.rectangle((180, vy + 8, 200, vy + 14), fill=(60, 60, 60))
            draw.text((225, vy + 28), "Setup KF2VR", fill=TEXT, font=font(30, True), anchor="lm")
            draw.text((440, vy + 28), "(double-click)", fill=DIM, font=font(26), anchor="lm")
            button(draw, 660, vy, "OK", (0, 103, 192), 160)
        else:
            button(draw, 175, vy, "Play in VR (KF2-VR)", RED, 330)
            button(draw, 525, vy, "Play normally", (60, 60, 60), 260)
    draw.text((W / 2, H - 30), "To undo it, double-click Setup KF2VR again.", fill=DIM, font=font(26), anchor="mm")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    image.save(OUT, optimize=True)
    print(OUT, OUT.stat().st_size)


if __name__ == "__main__":
    main()

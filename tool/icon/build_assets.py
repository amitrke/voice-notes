"""Builds the final Voice Notes icon assets (design D: waveform turning into text).

    python tool/icon/build_assets.py

Writes the sources `flutter_launcher_icons` reads into assets/icon/, and the store
graphics into docs/store-assets/. Then run:  dart run flutter_launcher_icons
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
from make_icons import (GRID, SS, S, box, bars_mask, finish, gradient, hex_rgb,  # noqa: E402
                        layer, paint)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICON_DIR = os.path.join(ROOT, "assets", "icon")
STORE_DIR = os.path.join(ROOT, "docs", "store-assets")
TEAL_DARK, TEAL_LIGHT = "#0F766E", "#2DD4BF"
WHITE = (255, 255, 255)


def mark_mask():
    """The white mark: four waveform bars plus three text lines, on the 1024 grid."""
    bars = bars_mask([140, 300, 430, 250], width=58, gap=30, cx=312)
    d = ImageDraw.Draw(bars)
    for length, y in ((330, 392), (330, 512), (210, 632)):
        d.rounded_rectangle(box(536, y - 28, 536 + length, y + 28), radius=S(28), fill=255)
    return bars


def scaled_centered(mask, factor):
    """Scale `mask` about its bounding box's centre and re-centre it on the canvas."""
    bbox = mask.getbbox()
    cx, cy = (bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2
    crop = mask.crop(bbox)
    w, h = int(crop.width * factor), int(crop.height * factor)
    crop = crop.resize((w, h), Image.LANCZOS)
    out = Image.new("L", mask.size, 0)
    out.paste(crop, (int(mask.width / 2 - w / 2), int(mask.height / 2 - h / 2)))
    return out


def background():
    return gradient(GRID * SS, TEAL_DARK, TEAL_LIGHT, 135)


def main():
    os.makedirs(ICON_DIR, exist_ok=True)
    os.makedirs(STORE_DIR, exist_ok=True)
    big = GRID * SS
    mark = mark_mask()

    # iOS / master icon: full bleed, opaque (iOS rejects transparency).
    img = background()
    paint(img, scaled_centered(mark, 1.0), WHITE)
    master = finish(img).convert("RGB")
    master.save(os.path.join(ICON_DIR, "icon.png"))

    # Android adaptive icon. The launcher crops to a circle/squircle and the safe
    # zone is the central 66% (676 of 1024), so the mark is scaled to fit inside it.
    bb = mark.getbbox()
    width_px = (bb[2] - bb[0]) / SS
    factor = min(1.0, 640 / width_px)
    fg_mask = scaled_centered(mark, factor)
    fg = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    fg.paste(Image.new("RGBA", (big, big), WHITE + (255,)), mask=fg_mask)
    fg = fg.resize((GRID, GRID), Image.LANCZOS)
    fg.save(os.path.join(ICON_DIR, "adaptive_foreground.png"))
    # Themed (monochrome) layer: Android tints it, so it must be one flat colour.
    fg.save(os.path.join(ICON_DIR, "adaptive_monochrome.png"))
    finish(background()).convert("RGB").save(os.path.join(ICON_DIR, "adaptive_background.png"))

    # Play Store icon: 512x512 PNG, full bleed. Google applies the mask itself.
    master.resize((512, 512), Image.LANCZOS).save(os.path.join(STORE_DIR, "play-icon-512.png"))

    # Play feature graphic: 1024x500.
    fw, fh = 1024, 500
    # Darker than the icon so the tile stands out against it.
    g = gradient(fw * 2, "#022C2B", "#0F766E", 20).resize((fw, fh), Image.LANCZOS)
    mark_small = master.resize((260, 260), Image.LANCZOS).convert("RGBA")
    corner = Image.new("L", (260 * 4, 260 * 4), 0)
    ImageDraw.Draw(corner).rounded_rectangle([0, 0, 260 * 4 - 1, 260 * 4 - 1], radius=58 * 4, fill=255)
    corner = corner.resize((260, 260), Image.LANCZOS)
    g.paste(mark_small.convert("RGB"), (90, (fh - 260) // 2), corner)
    d = ImageDraw.Draw(g)
    bold = ImageFont.truetype("C:/Windows/Fonts/segoeuib.ttf", 92)
    reg = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 36)
    d.text((400, 160), "Voice Notes", font=bold, fill=WHITE)
    d.text((404, 284), "Speak in any language.", font=reg, fill=(224, 255, 250))
    d.text((404, 332), "Get text, English and a summary.", font=reg, fill=(224, 255, 250))
    g.save(os.path.join(STORE_DIR, "feature-graphic-1024x500.png"))

    for folder in (ICON_DIR, STORE_DIR):
        for name in sorted(os.listdir(folder)):
            if name.endswith(".png"):
                with Image.open(os.path.join(folder, name)) as im:
                    print(f"{os.path.relpath(os.path.join(folder, name), ROOT):55} {im.size} {im.mode}")


if __name__ == "__main__":
    main()

"""Draws the Voice Notes app icon variants with Pillow.

    python tool/icon/make_icons.py            # writes previews to tool/icon/out/

Everything is drawn on a 1024 design grid at 4x and downsampled for smooth edges.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

GRID = 1024
SS = 4  # supersampling factor
OUT = os.path.join(os.path.dirname(__file__), "out")


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def gradient(size, c1, c2, angle_deg=135):
    """Linear gradient from c1 to c2 across the square, at angle_deg."""
    a, b = hex_rgb(c1), hex_rgb(c2)
    t = math.radians(angle_deg)
    dx, dy = math.cos(t), math.sin(t)
    base = Image.linear_gradient("L")  # 256x256 vertical black->white
    # Build via a rotated, resized gradient mask for speed.
    diag = int(size * (abs(dx) + abs(dy)))
    mask = base.resize((diag, diag)).rotate(-(angle_deg - 90), resample=Image.BICUBIC)
    left = (mask.width - size) // 2
    mask = mask.crop((left, left, left + size, left + size))
    return Image.composite(Image.new("RGB", (size, size), b),
                           Image.new("RGB", (size, size), a), mask)


def S(v):
    return int(round(v * SS))


def box(x0, y0, x1, y1):
    return [S(x0), S(y0), S(x1), S(y1)]


def layer():
    return Image.new("L", (GRID * SS, GRID * SS), 0)


def finish(img):
    return img.resize((GRID, GRID), Image.LANCZOS)


# ---------------------------------------------------------------------------
# Shapes (as L masks on the supersampled grid)
# ---------------------------------------------------------------------------

def mic_mask(cx=512, top=190, scale=1.0):
    """A microphone: capsule, cradle arc, stem and base."""
    m = layer()
    d = ImageDraw.Draw(m)
    k = scale

    def sx(v):
        return cx + (v - 512) * k

    def sy(v):
        return top + (v - 190) * k

    # capsule
    d.rounded_rectangle(box(sx(402), sy(190), sx(622), sy(590)), radius=S(110 * k), fill=255)
    # cradle: lower half of a ring around the capsule
    ring = layer()
    rd = ImageDraw.Draw(ring)
    cyc = sy(440)
    r = 210 * k
    w = 46 * k
    rd.ellipse(box(sx(512) - r, cyc - r, sx(512) + r, cyc + r), fill=255)
    rd.ellipse(box(sx(512) - r + w, cyc - r + w, sx(512) + r - w, cyc + r - w), fill=0)
    rd.rectangle([0, 0, GRID * SS, S(cyc)], fill=0)  # keep only the lower half
    # round the cut ends
    for ex in (sx(512) - r + w / 2, sx(512) + r - w / 2):
        rd.ellipse(box(ex - w / 2, cyc - w / 2, ex + w / 2, cyc + w / 2), fill=255)
    m.paste(255, mask=ring)
    # stem and base
    d.rounded_rectangle(box(sx(488), sy(640), sx(536), sy(740)), radius=S(10 * k), fill=255)
    d.rounded_rectangle(box(sx(392), sy(724), sx(632), sy(776)), radius=S(26 * k), fill=255)
    return m


def wave_arcs_mask(cx=512, cy=400, radii=(300, 360), span=38, width=30):
    m = layer()
    d = ImageDraw.Draw(m)
    for r in radii:
        for side in (0, 180):
            d.arc(box(cx - r, cy - r, cx + r, cy + r), side - span, side + span,
                  fill=255, width=S(width))
            # Round caps. PIL draws an arc's stroke inward from radius r, so the
            # stroke's centre line sits at r - width / 2.
            mid = r - width / 2
            for ang in (side - span, side + span):
                ex = cx + mid * math.cos(math.radians(ang))
                ey = cy + mid * math.sin(math.radians(ang))
                rr = width / 2
                d.ellipse(box(ex - rr, ey - rr, ex + rr, ey + rr), fill=255)
    return m


def bars_mask(heights, width=70, gap=40, cy=512, cx=512):
    m = layer()
    d = ImageDraw.Draw(m)
    n = len(heights)
    total = n * width + (n - 1) * gap
    x = cx - total / 2
    for h in heights:
        d.rounded_rectangle(box(x, cy - h / 2, x + width, cy + h / 2), radius=S(width / 2), fill=255)
        x += width + gap
    return m


def paint(canvas, mask, fill, alpha=1.0):
    """Paint `fill` (RGB tuple or an RGB image) through `mask` onto canvas."""
    if isinstance(fill, tuple):
        fill = Image.new("RGB", canvas.size, fill)
    if alpha < 1.0:
        mask = mask.point(lambda v: int(v * alpha))
    canvas.paste(fill, mask=mask)


# ---------------------------------------------------------------------------
# Variants. Each returns a full-bleed 1024 RGB square (what iOS wants).
# ---------------------------------------------------------------------------

def variant_a():
    """Indigo-violet gradient, white microphone with sound arcs."""
    big = GRID * SS
    img = gradient(big, "#4338CA", "#9333EA", 135)
    paint(img, wave_arcs_mask(512, 410, radii=(290, 350), span=36, width=30), (255, 255, 255), 0.55)
    paint(img, mic_mask(512, 200, 0.92), (255, 255, 255))
    return finish(img)


def variant_b():
    """Deep navy, glowing waveform bars."""
    big = GRID * SS
    img = Image.new("RGB", (big, big), hex_rgb("#0B1020"))
    bars = bars_mask([170, 330, 500, 640, 500, 330, 170], width=78, gap=36)
    fill = gradient(big, "#22D3EE", "#A78BFA", 90)
    # soft glow behind the bars
    glow = bars.filter(ImageFilter.GaussianBlur(S(34)))
    paint(img, glow, hex_rgb("#6D5BFF"), 0.45)
    paint(img, bars, fill)
    return finish(img)


def variant_c():
    """Light background, indigo speech bubble containing a waveform."""
    big = GRID * SS
    img = Image.new("RGB", (big, big), hex_rgb("#EEF2FF"))
    bubble = layer()
    d = ImageDraw.Draw(bubble)
    d.rounded_rectangle(box(160, 210, 864, 700), radius=S(150), fill=255)
    d.polygon([(S(250), S(660)), (S(250), S(840)), (S(430), S(690))], fill=255)
    paint(img, bubble, gradient(big, "#4F46E5", "#7C3AED", 120))
    paint(img, bars_mask([110, 220, 330, 220, 110], width=64, gap=34, cy=455), (255, 255, 255))
    return finish(img)


def variant_d():
    """Teal gradient: a waveform on the left turning into lines of text."""
    big = GRID * SS
    img = gradient(big, "#0F766E", "#2DD4BF", 135)
    bars = bars_mask([140, 300, 430, 250], width=58, gap=30, cx=312)
    paint(img, bars, (255, 255, 255))
    lines = layer()
    d = ImageDraw.Draw(lines)
    for i, (length, y) in enumerate(((330, 392), (330, 512), (210, 632))):
        d.rounded_rectangle(box(536, y - 28, 536 + length, y + 28), radius=S(28), fill=255)
    paint(img, lines, (255, 255, 255), 0.95)
    return finish(img)


def variant_e():
    """Warm coral-to-amber record button with ripples and a microphone."""
    big = GRID * SS
    img = gradient(big, "#E11D48", "#F59E0B", 135)
    for r, w, a in ((385, 26, 0.30), (305, 26, 0.55)):
        ring = layer()
        d = ImageDraw.Draw(ring)
        d.ellipse(box(512 - r, 512 - r, 512 + r, 512 + r), fill=255)
        d.ellipse(box(512 - r + w, 512 - r + w, 512 + r - w, 512 + r - w), fill=0)
        paint(img, ring, (255, 255, 255), a)
    disc = layer()
    ImageDraw.Draw(disc).ellipse(box(512 - 220, 512 - 220, 512 + 220, 512 + 220), fill=255)
    paint(img, disc, (255, 255, 255))
    paint(img, mic_mask(512, 512 - 103, 0.36), hex_rgb("#E11D48"))
    return finish(img)


def variant_f():
    """Dark slate with a white note card: a waveform header over text lines."""
    big = GRID * SS
    img = gradient(big, "#0F172A", "#334155", 135)
    card = layer()
    ImageDraw.Draw(card).rounded_rectangle(box(236, 168, 788, 856), radius=S(70), fill=255)
    paint(img, card, hex_rgb("#F8FAFC"))
    paint(img, bars_mask([44, 96, 150, 96, 44, 70, 120, 70, 44], width=28, gap=18, cy=360),
          gradient(big, "#F59E0B", "#EF4444", 0))
    lines = layer()
    d = ImageDraw.Draw(lines)
    for length, y in ((380, 560), (380, 640), (240, 720)):
        d.rounded_rectangle(box(318, y - 16, 318 + length, y + 16), radius=S(16), fill=255)
    paint(img, lines, hex_rgb("#CBD5E1"))
    return finish(img)


def variant_g():
    """Blue-to-cyan with a big white disc and a blue microphone."""
    big = GRID * SS
    img = gradient(big, "#1D4ED8", "#06B6D4", 135)
    disc = layer()
    ImageDraw.Draw(disc).ellipse(box(512 - 335, 512 - 335, 512 + 335, 512 + 335), fill=255)
    paint(img, disc, (255, 255, 255))
    paint(img, mic_mask(512, 512 - 180, 0.62), hex_rgb("#1D4ED8"))
    return finish(img)


def variant_h():
    """Warm white with bold pink-to-orange waveform bars."""
    big = GRID * SS
    img = Image.new("RGB", (big, big), hex_rgb("#FFF7ED"))
    bars = bars_mask([220, 400, 580, 400, 220], width=96, gap=48)
    paint(img, bars, gradient(big, "#EC4899", "#F97316", 90))
    return finish(img)


VARIANTS = {"a_mic": variant_a, "b_wave": variant_b, "c_bubble": variant_c,
            "d_wave_to_text": variant_d, "e_record": variant_e, "f_note": variant_f,
            "g_disc": variant_g, "h_bars": variant_h}
SETS = {"contact": ["a_mic", "b_wave", "c_bubble"],
        "contact2": ["d_wave_to_text", "e_record", "f_note", "g_disc", "h_bars"]}


def rounded_preview(img, size):
    """Approximate the iOS squircle (~22.4% corner radius) at `size`."""
    im = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1],
                                           radius=int(size * 4 * 0.224), fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(im, mask=mask)
    return out


def contact_sheet(rendered, columns=3):
    pad, big = 40, 360
    smalls = (120, 60, 40)
    cell_w, cell_h = big + pad, big + 30 + 120 + pad
    rows = -(-len(rendered) // columns)
    sheet = Image.new("RGB", (pad + min(columns, len(rendered)) * cell_w, pad + rows * cell_h), (236, 236, 240))
    for i, img in enumerate(rendered.values()):
        cx = pad + (i % columns) * cell_w
        cy = pad + (i // columns) * cell_h
        p = rounded_preview(img, big)
        sheet.paste(p, (cx, cy), p)
        x = cx
        for sz in smalls:
            q = rounded_preview(img, sz)
            sheet.paste(q, (x, cy + big + 30 + (120 - sz) // 2), q)
            x += sz + 20
    return sheet


def main():
    os.makedirs(OUT, exist_ok=True)
    rendered = {}
    for name, fn in VARIANTS.items():
        img = fn()
        img.save(os.path.join(OUT, f"{name}.png"))
        rendered[name] = img
    for sheet_name, names in SETS.items():
        contact_sheet({n: rendered[n] for n in names}).save(os.path.join(OUT, f"{sheet_name}.png"))
    print("wrote", ", ".join(VARIANTS), "and", ", ".join(SETS), "to", OUT)


if __name__ == "__main__":
    main()

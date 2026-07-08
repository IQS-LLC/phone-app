"""
Generates the Lugh app icon (icon.png) — a gold-to-orange gradient square
with a black bolt, matching the in-app branding (theme.dart's C.accent /
the login screen's _LogoSection gradient). Run once with:

    python assets/icon/generate_icon.py

then regenerate platform icons with:

    dart run flutter_launcher_icons

Full-bleed square, no pre-rounded corners or padding — Android adaptive
icons and iOS apply their own masking, baking corners in here would double
up or look wrong on shapes flutter_launcher_icons doesn't expect.
"""
from PIL import Image, ImageDraw

SIZE = 1024
GOLD   = (245, 197, 66)    # C.accent  0xFFF5C542
ORANGE = (249, 115, 22)    # 0xFFF97316
BLACK  = (10, 10, 14)

img = Image.new("RGB", (SIZE, SIZE), GOLD)
px = img.load()

# Diagonal gradient gold -> orange -> gold, approximating the app's
# SweepGradient without needing a full conic-gradient implementation.
for y in range(SIZE):
    for x in range(SIZE):
        t = (x + y) / (2 * SIZE)  # 0..1 diagonal position
        # triangle wave so it eases back to gold at the far corner
        wave = abs(((t * 2) % 2) - 1)
        r = int(GOLD[0] + (ORANGE[0] - GOLD[0]) * wave)
        g = int(GOLD[1] + (ORANGE[1] - GOLD[1]) * wave)
        b = int(GOLD[2] + (ORANGE[2] - GOLD[2]) * wave)
        px[x, y] = (r, g, b)

draw = ImageDraw.Draw(img)

# Bolt glyph (matches Icons.bolt_rounded's silhouette closely enough at
# icon scale) — a simple lightning-bolt polygon, centered.
cx, cy, s = SIZE / 2, SIZE / 2, SIZE * 0.34
bolt = [
    (cx + s * 0.15, cy - s),
    (cx - s * 0.55, cy + s * 0.15),
    (cx - s * 0.05, cy + s * 0.15),
    (cx - s * 0.15, cy + s),
    (cx + s * 0.55, cy - s * 0.15),
    (cx + s * 0.05, cy - s * 0.15),
]
draw.polygon(bolt, fill=BLACK)

img.save("assets/icon/icon.png")
print("Wrote assets/icon/icon.png", img.size)

# Adaptive-icon foreground: same bolt, transparent background, scaled down
# so it sits inside Android's ~66% safe zone (the OS masks/crops the rest).
fg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
fg_draw = ImageDraw.Draw(fg)
safe_s = s * 0.62
fg_bolt = [
    (cx + safe_s * 0.15, cy - safe_s),
    (cx - safe_s * 0.55, cy + safe_s * 0.15),
    (cx - safe_s * 0.05, cy + safe_s * 0.15),
    (cx - safe_s * 0.15, cy + safe_s),
    (cx + safe_s * 0.55, cy - safe_s * 0.15),
    (cx + safe_s * 0.05, cy - safe_s * 0.15),
]
fg_draw.polygon(fg_bolt, fill=BLACK)
fg.save("assets/icon/icon_foreground.png")
print("Wrote assets/icon/icon_foreground.png", fg.size)

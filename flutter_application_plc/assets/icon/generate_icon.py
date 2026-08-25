"""
Generates the Lugh app icon (icon.png) — a rosewine gradient square with a
white bolt, matching the in-app branding (theme.dart's C.accent / G.accent /
the login screen's _LogoSection gradient) and IQS's (iqs.am) brand primary.
Run once with:

    python assets/icon/generate_icon.py

then regenerate platform icons with:

    dart run flutter_launcher_icons

Full-bleed square, no pre-rounded corners or padding — Android adaptive
icons and iOS apply their own masking, baking corners in here would double
up or look wrong on shapes flutter_launcher_icons doesn't expect.
"""
from PIL import Image, ImageDraw

SIZE = 1024
ROSE      = (226, 85, 126)   # C.accent        0xFFE2557E
ROSE_DARK = (194, 63, 104)   # G.accent stop 2 0xFFC23F68
WHITE     = (255, 255, 255)

img = Image.new("RGB", (SIZE, SIZE), ROSE)
px = img.load()

# Diagonal gradient rose -> darker rose -> rose, approximating the app's
# SweepGradient without needing a full conic-gradient implementation.
for y in range(SIZE):
    for x in range(SIZE):
        t = (x + y) / (2 * SIZE)  # 0..1 diagonal position
        # triangle wave so it eases back to the base tone at the far corner
        wave = abs(((t * 2) % 2) - 1)
        r = int(ROSE[0] + (ROSE_DARK[0] - ROSE[0]) * wave)
        g = int(ROSE[1] + (ROSE_DARK[1] - ROSE[1]) * wave)
        b = int(ROSE[2] + (ROSE_DARK[2] - ROSE[2]) * wave)
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
draw.polygon(bolt, fill=WHITE)

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
fg_draw.polygon(fg_bolt, fill=WHITE)
fg.save("assets/icon/icon_foreground.png")
print("Wrote assets/icon/icon_foreground.png", fg.size)

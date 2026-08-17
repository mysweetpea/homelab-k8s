"""Compose MySweetPea branded Jellyfin splashscreen (1920x1080).
Dark nordic gradient + subtle geometric petals + centered gold/teal logo.
"""
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance
import math, random

W, H = 1920, 1080

# --- Base dark nordic gradient (top-left glow like auth-bg) ---
img = Image.new("RGB", (W, H), (12, 19, 22))  # #0C1316
draw = ImageDraw.Draw(img, "RGBA")

def radial(cx, cy, r, color, max_alpha):
    """Draw a radial glow by layering concentric ellipses."""
    steps = 60
    for i in range(steps, 0, -1):
        t = i / steps
        rr = r * (1 - t + 0.02)
        alpha = int(max_alpha * t * t)
        draw.ellipse([cx - rr, cy - rr, cx + rr, cy + rr],
                     fill=(color[0], color[1], color[2], alpha))

# Top-left cool glow (#294149-ish)
radial(W * 0.18, H * 0.10, 1400, (41, 65, 73), 90)
# Bottom-right sage glow
radial(W * 0.83, H * 0.85, 1000, (94, 184, 168), 28)
# Subtle gold ambient bottom-center
radial(W * 0.5, H * 1.05, 1200, (217, 168, 108), 16)

img = img.filter(ImageFilter.GaussianBlur(1.2))

# --- Subtle film grain (dark noise overlay, NOT inverted) ---
grain = Image.new("L", (W, H))
gp = grain.load()
rng = random.Random(42)
for y in range(0, H, 2):
    for x in range(0, W, 2):
        v = rng.randint(0, 10)
        gp[x, y] = v
grain = grain.resize((W, H))
noise = Image.new("RGB", (W, H), (0, 0, 0))
img = Image.composite(noise, img, grain)  # dark speckles only where grain is bright
img = ImageEnhance.Brightness(img).enhance(0.99)

# --- Subtle petal shapes (like auth-bg) ---
overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
od = ImageDraw.Draw(overlay)
petal_color = (143, 175, 181, 26)  # #8FAFB5 @ 10%
def petal(cx, cy, s, rot):
    pts = []
    for a_deg in range(0, 360, 6):
        a = math.radians(a_deg + rot)
        r = s * (0.35 + 0.65 * abs(math.sin(a * 2)) ** 0.7)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a) * 0.82))
    od.polygon(pts, fill=petal_color)

petal(160, 205, 130, 0)
petal(1690, 720, 150, 15)
petal(1470, 140, 90, -10)
petal(420, 880, 100, 25)
petal(1750, 300, 80, -20)
img = Image.alpha_composite(img.convert("RGBA"), overlay)

# --- Centered logo ---
logo = Image.open("mysweetpea-logo-dark.png").convert("RGBA")
# Scale to ~28% of width
ls = int(W * 0.28)
logo = logo.resize((ls, ls), Image.LANCZOS)
# Soft glow behind logo
glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
glow_r = ls * 0.75
for i in range(40, 0, -1):
    t = i / 40
    alpha = int(22 * t * t)
    gd.ellipse([W/2 - glow_r*t, H/2 - glow_r*t*0.9, W/2 + glow_r*t, H/2 + glow_r*t*0.9],
               fill=(217, 168, 108, alpha))
glow = glow.filter(ImageFilter.GaussianBlur(60))
img = Image.alpha_composite(img, glow)

img.alpha_composite(logo, (int(W/2 - ls/2), int(H/2 - ls/2)))

img.convert("RGB").save("mysweetpea-splashscreen.png", optimize=True)
print("saved", img.size)

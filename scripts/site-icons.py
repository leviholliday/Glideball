#!/usr/bin/env python3
"""The website's icons and share picture, made from the app icon.

    python3 scripts/site-icons.py [icon.png]     default: brand/icon-candidates/orb-b.png

Writes website/assets/icon-256.png|webp, icon-512.webp, icon-1024.png,
favicon-64.png, apple-touch-icon.png, og.png (1200x630: the orb on the dark
stage with the wordmark and the headline) and website/favicon.ico.
/assets/ is cached for a year, so bump the ?v= on the pages that use them
after running this. Needs Pillow (pip install pillow) and macOS's SF fonts.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "brand/icon-candidates/orb-b.png")
ASSETS = os.path.join(ROOT, "website/assets")
STAGE = (11, 11, 16)  # --bg on the site
ROUNDED = "/System/Library/Fonts/SFNSRounded.ttf"
SF = "/System/Library/Fonts/SFNS.ttf"

icon = Image.open(SRC).convert("RGBA")
if icon.size != (1024, 1024):
    icon = icon.resize((1024, 1024), Image.LANCZOS)


def sized(px):
    return icon.resize((px, px), Image.LANCZOS)


def save(img, name, **kw):
    path = os.path.join(ASSETS, name)
    img.save(path, **kw)
    print("wrote", os.path.relpath(path, ROOT))


save(sized(1024), "icon-1024.png", optimize=True)
save(sized(256), "icon-256.png", optimize=True)
save(sized(256), "icon-256.webp", quality=90, method=6)
save(sized(512), "icon-512.webp", quality=90, method=6)

# Small sizes: crop to the squircle so the orb isn't lost in the margin.
box = (96, 96, 928, 928)
tight = icon.crop(box)
save(tight.resize((64, 64), Image.LANCZOS), "favicon-64.png", optimize=True)
ico = os.path.join(ROOT, "website/favicon.ico")
tight.resize((48, 48), Image.LANCZOS).save(ico, sizes=[(16, 16), (32, 32), (48, 48)])
print("wrote website/favicon.ico")

# Apple touch icon: opaque and full-bleed (iOS rounds the corners itself).
body = icon.getpixel((180, 512))[:3]
touch = Image.new("RGBA", (832, 832), body + (255,))
touch.alpha_composite(tight)
save(touch.convert("RGB").resize((180, 180), Image.LANCZOS), "apple-touch-icon.png", optimize=True)


# Share picture.
def font(path, size, weight):
    f = ImageFont.truetype(path, size)
    # Axes: SF Pro Rounded is (GRAD, Weight); SF Pro is (Width, Optical Size, GRAD, Weight).
    f.set_variation_by_axes([400, weight] if path == ROUNDED else [100, min(96, max(17, size)), 400, weight])
    return f


W, H = 1200, 630
og = Image.new("RGBA", (W, H), STAGE + (255,))
# A soft pool of the orb's own light under it, and nothing else glowing.
glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
g = ImageDraw.Draw(glow)
g.ellipse((60, 90, 520, 550), fill=(61, 107, 255, 70))
g.ellipse((150, 260, 470, 580), fill=(240, 86, 216, 40))
og.alpha_composite(glow.filter(ImageFilter.GaussianBlur(70)))
orb = sized(450)
og.alpha_composite(orb, (52, 90))

d = ImageDraw.Draw(og)
x = 530
d.text((x, 170), "Glideball", font=font(ROUNDED, 96, 760), fill=(244, 244, 247))
head = font(SF, 32, 600)
# The site's headline, broken where it reads best.
lines = ["A smoother scroll ring and a faster pointer", "for your Kensington trackball"]
y = 296
for ln in lines:
    d.text((x, y), ln, font=head, fill=(206, 206, 216))
    y += 46
d.text((x, y + 26), "Free and open source · macOS 26 Tahoe or later", font=font(SF, 24, 500), fill=(142, 142, 152))
save(og.convert("RGB"), "og.png", optimize=True)

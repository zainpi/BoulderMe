"""Compose App Store screenshots as one connected panorama, then slice it.

Usage: python3 compose.py <raw dir> <fonts dir> <icon png> <out dir>
Writes <out dir>/panorama.html; render.mjs turns it into PNG slices.
Each slice is 1320x2868 (6.9-inch iPhone). Phones and the climbing wall
cross the seams so the set reads as one long image in the App Store.
"""
import base64
import json
import math
import pathlib
import random
import sys

raw, fonts, icon, out = map(pathlib.Path, sys.argv[1:5])
W, H = 1320, 2868

# (raw screenshot, caption line 1, caption line 2)
SLIDES = [
    ("welcome", "Find your", "bouldering partner"),
    ("discover", "Climbers at your level,", "at your gym"),
    ("profile", "See their grades,", "styles and gym access"),
    ("invitation", "Invite them", "to a session"),
    ("chat", "Chat opens once", "they say yes"),
    ("me", "Your profile,", "your rules"),
]
N = len(SLIDES)
TOTAL = W * N

# Phone geometry: screen keeps the simulator's 1320x2868 aspect.
SCREEN_W = 800
SCREEN_H = round(SCREEN_W * 2868 / 1320)
BEZEL = 26
PHONE_W, PHONE_H = SCREEN_W + 2 * BEZEL, SCREEN_H + 2 * BEZEL

# Phone centre as a fraction of its own slide, tilt in degrees, and top edge.
# Phones 2+3 and 4+5 fan out across their shared seam, so neighbouring
# screenshots join up; holds and the route line cross the other seams.
LAYOUT = [
    (0.56, 3, 700),
    (0.80, -5, 780),
    (0.30, 4, 700),
    (0.80, -4, 780),
    (0.30, 4, 700),
    (0.52, -2, 740),
]
SEAM_HOLDS = [1, 3, 5]  # seams (after slide n) that get a big hold right on them

def data_uri(path, mime):
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode()


font_css = "".join(
    f"@font-face{{font-family:Nunito;font-weight:{w};src:url({data_uri(fonts / f'nunito-{w}.ttf', 'font/ttf')})}}"
    for w in (700, 800, 900))

# A wavy charcoal wall band running the full width, with holds and a dotted route.
random.seed(7)


def wall_y(x):
    return 2080 + 200 * math.sin(x / 1300) + 120 * math.sin(x / 470 + 1.3)


top = " ".join(f"L{x},{wall_y(x) - 520:.0f}" for x in range(0, TOTAL + 41, 40))
wall_path = f"M0,{H} L0,{wall_y(0) - 520:.0f} " + top + f" L{TOTAL},{H} Z"

hold_colors = ["#F5B700", "#FF8A3D", "#55703A", "#2F5F8A", "#FFE3CC"]
holds, route = [], []
x = 120
while x < TOTAL - 80:
    y = wall_y(x) - 380 + random.uniform(-90, 330)
    r = random.uniform(46, 92)
    c = random.choice(hold_colors)
    rot = random.uniform(0, 360)
    holds.append(
        f'<g transform="translate({x:.0f},{y:.0f}) rotate({rot:.0f})">'
        f'<path d="M{-r},0 C{-r},{-r * .8} {r * .2},{-r * .95} {r},{-r * .25} C{r * 1.1},{r * .5} {r * .1},{r * .9} {-r * .6},{r * .7} Z" fill="{c}"/>'
        f'<circle cx="{r * .05:.0f}" cy="0" r="{r * .16:.0f}" fill="#3A2F2C" opacity=".55"/></g>')
    route.append((x, y))
    x += random.uniform(230, 360)

for seam in SEAM_HOLDS:
    sx = W * seam
    sy = wall_y(sx) - 300
    holds.append(
        f'<g transform="translate({sx},{sy:.0f}) rotate({seam * 47})">'
        f'<path d="M-150,0 C-150,-120 30,-140 150,-40 C165,75 15,135 -90,105 Z" fill="#F5B700"/>'
        f'<circle cx="8" cy="0" r="26" fill="#3A2F2C" opacity=".55"/></g>')
    route.append((sx, sy))
route.sort()

# Route line through every other hold, crossing every seam.
pts = route[::2]
d = f"M{pts[0][0]:.0f},{pts[0][1]:.0f} " + " ".join(
    f"Q{(a[0] + b[0]) / 2:.0f},{min(a[1], b[1]) - 160:.0f} {b[0]:.0f},{b[1]:.0f}" for a, b in zip(pts, pts[1:]))

# Soft sun blobs behind the captions.
blobs = "".join(
    f'<circle cx="{W * i + W * .78:.0f}" cy="{360 + 140 * (i % 2)}" r="{260 + 40 * (i % 3)}" fill="#FFB27F" opacity=".35"/>'
    for i in range(N))

phones = []
for i, ((scene, l1, l2), (cx, tilt, top_px)) in enumerate(zip(SLIDES, LAYOUT)):
    left = W * i + cx * W - PHONE_W / 2
    img = data_uri(raw / f"{scene}.png", "image/png")
    phones.append(
        f'<div class="phone" style="left:{left:.0f}px;top:{top_px}px;transform:rotate({tilt}deg)">'
        f'<img src="{img}"></div>')

captions = []
for i, (scene, l1, l2) in enumerate(SLIDES):
    if i == 0:
        captions.append(
            f'<div class="cap hero" style="left:{W * i + 110}px">'
            f'<div class="brand"><img src="{data_uri(icon, "image/png")}"><span>BoulderMe</span></div>'
            f'<div class="l1">{l1}</div><div class="l2">{l2}</div></div>')
    else:
        captions.append(
            f'<div class="cap" style="left:{W * i + 110}px"><div class="l1">{l1}</div><div class="l2">{l2}</div></div>')

html = f"""<!doctype html><html><head><meta charset="utf-8"><style>
{font_css}
html,body{{margin:0;padding:0}}
#stage{{position:relative;width:{TOTAL}px;height:{H}px;overflow:hidden;
  background:linear-gradient(100deg,#FF6D00 0%,#FF8A1F 30%,#FF7410 55%,#FF8A3D 80%,#FF6D00 100%);
  font-family:Nunito,sans-serif}}
svg.bg{{position:absolute;left:0;top:0}}
.phone{{position:absolute;width:{PHONE_W}px;height:{PHONE_H}px;border-radius:150px;background:#1E1816;
  box-shadow:0 0 0 8px #FFF6EC, 0 60px 120px rgba(58,47,44,.45);transform-origin:50% 50%}}
.phone img{{position:absolute;left:{BEZEL}px;top:{BEZEL}px;width:{SCREEN_W}px;height:{SCREEN_H}px;border-radius:122px}}
.cap{{position:absolute;top:190px;width:{W - 220}px;color:#FFFFFF}}
.cap .l1{{font-weight:800;font-size:100px;line-height:1.05;letter-spacing:-1px}}
.cap .l2{{font-weight:900;font-size:100px;line-height:1.05;letter-spacing:-1px;color:#3A2F2C}}
.cap.hero{{top:120px}}
.brand{{display:flex;align-items:center;gap:30px;margin-bottom:40px}}
.brand img{{width:150px;height:150px;border-radius:34px;box-shadow:0 0 0 6px #FFF6EC}}
.brand span{{font-weight:900;font-size:84px;color:#FFF6EC}}
</style></head><body><div id="stage">
<svg class="bg" width="{TOTAL}" height="{H}" viewBox="0 0 {TOTAL} {H}">
{blobs}
<path d="{wall_path}" fill="#3A2F2C"/>
<path d="{d}" fill="none" stroke="#F5B700" stroke-width="16" stroke-linecap="round" stroke-dasharray="2 44" opacity=".9"/>
{''.join(holds)}
</svg>
{''.join(phones)}
{''.join(captions)}
</div></body></html>"""

out.mkdir(parents=True, exist_ok=True)
(out / "panorama.html").write_text(html)
(out / "slides.json").write_text(json.dumps({"width": W, "height": H, "count": N, "scenes": [s[0] for s in SLIDES]}))
print("wrote", out / "panorama.html")

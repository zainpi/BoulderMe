"""Compose App Store screenshots as one connected bouldering-gym panorama, then slice it.

Usage: python3 compose.py <raw dir> <fonts dir> <art dir> <icon png> <out dir>
  raw dir:   simulator captures from the appstore-screenshots workflow
  fonts dir: nunito-700/800/900.ttf
  art dir:   art_climber.png, art_spotter.png (cut out of the app icon by key_icon.py)
Writes <out dir>/panorama.html and slides.json; render.cjs turns them into PNG slices.

The whole set is one gym: a charcoal wall with bolt holes, taped problems and
holds runs behind everything, a row of crash pads runs along the floor, and
holds, stickers, the climber and the spotter cross the seams between slides.
"""
import base64
import json
import math
import pathlib
import random
import sys

raw, fonts, art, icon, out = map(pathlib.Path, sys.argv[1:6])
W, H = 1320, 2868
N = 6
TOTAL = W * N
random.seed(11)

INK = "#3A2F2C"
CREAM = "#FFF6EC"
SUNNY = "#F5B700"
ORANGE = "#FF8A3D"
MOSS = "#55703A"
DENIM = "#2F5F8A"
PEACH = "#FFE3CC"
HOLD_COLORS = [SUNNY, ORANGE, MOSS, DENIM, PEACH, "#E8505B"]

CAPTIONS = [
    ("Find your", "bouldering partner"),
    ("Spot climbers", "at your level"),
    ("Check their beta:", "grades, styles, gyms"),
    ("Invite them", "to a session"),
    ("Chat opens when", "they say yes"),
    ("Chalk up.", "You're in control."),
]

# Phones: (slide, screenshot, centre as fraction of slide, tilt, top)
SCREEN_W = 780
SCREEN_H = round(SCREEN_W * 2868 / 1320)
BEZEL = 26
PHONE_W, PHONE_H = SCREEN_W + 2 * BEZEL, SCREEN_H + 2 * BEZEL
PHONES = [
    (1, "discover", 0.60, -4, 860),
    (2, "profile", 0.44, 4, 800),
    (3, "invitation", 0.58, -3, 860),
    (4, "chat", 0.42, 4, 800),
    (5, "me", 0.56, -3, 840),
]
FLOOR = 2650  # top of the crash pads


def uri(path, mime="image/png"):
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode()


font_css = "".join(
    f"@font-face{{font-family:Nunito;font-weight:{w};src:url({uri(fonts / f'nunito-{w}.ttf', 'font/ttf')})}}"
    for w in (700, 800, 900))


def hold(x, y, r, color, rot, kind=None):
    """A chunky climbing hold with a bolt, as an SVG group."""
    kind = kind or random.choice(["jug", "crimp", "sloper", "pinch"])
    shapes = {
        "jug": f"M{-r},{r * .1} C{-r},{-r * .9} {r * .3},{-r} {r},{-r * .3} C{r * 1.15},{r * .45} {r * .2},{r * .95} {-r * .55},{r * .75} Z",
        "crimp": f"M{-r * 1.2},{r * .25} C{-r},{-r * .45} {r},{-r * .55} {r * 1.2},{r * .1} C{r * .9},{r * .5} {-r * .9},{r * .6} {-r * 1.2},{r * .25} Z",
        "sloper": f"M{-r},{r * .3} C{-r * .9},{-r * .8} {r * .9},{-r * .8} {r},{r * .3} C{r * .5},{r * .6} {-r * .5},{r * .6} {-r},{r * .3} Z",
        "pinch": f"M{-r * .45},{-r} C{r * .5},{-r * 1.05} {r * .6},{r} {r * .1},{r * 1.05} C{-r * .6},{r} {-r * .9},{-r * .5} {-r * .45},{-r} Z",
    }
    return (f'<g transform="translate({x:.0f},{y:.0f}) rotate({rot:.0f})">'
            f'<path d="{shapes[kind]}" fill="{color}" stroke="rgba(0,0,0,.18)" stroke-width="{max(3, r * .06):.0f}"/>'
            f'<path d="{shapes[kind]}" fill="rgba(255,255,255,.18)" transform="translate({-r * .12:.0f},{-r * .12:.0f}) scale(.55)"/>'
            f'<circle r="{r * .17:.0f}" fill="{INK}" opacity=".7"/><circle r="{r * .07:.0f}" fill="#999"/></g>')


def tape(x, y, grade, color, rot):
    """Gym route tape with a hand-written grade."""
    return (f'<g transform="translate({x:.0f},{y:.0f}) rotate({rot:.0f})">'
            f'<rect x="-62" y="-26" width="124" height="52" rx="6" fill="{color}"/>'
            f'<text x="0" y="13" text-anchor="middle" font-family="Nunito" font-weight="900" font-size="36" fill="{INK}">{grade}</text></g>')


def wall_top(x):
    return 1180 + 140 * math.sin(x / 1100 + .6) + 70 * math.sin(x / 380)


# --- Wall: charcoal band with a bolt-hole grid and taped problems -------------
wall_pts = " ".join(f"L{x},{wall_top(x):.0f}" for x in range(0, TOTAL + 41, 40))
wall = f'<path d="M0,{H} L0,{wall_top(0):.0f} {wall_pts} L{TOTAL},{H} Z" fill="url(#wallgrad)"/>'
bolts = []
for x in range(60, TOTAL, 120):
    for y in range(int(wall_top(x)) + 60, FLOOR, 120):
        bolts.append(f'<circle cx="{x + (60 if (y // 120) % 2 else 0)}" cy="{y}" r="7" fill="#1E1816" opacity=".55"/>')

holds, tapes = [], []
x = 90
while x < TOTAL - 60:
    y = random.uniform(wall_top(x) + 110, FLOOR - 140)
    c = random.choice(HOLD_COLORS)
    holds.append(hold(x, y, random.uniform(40, 80), c, random.uniform(0, 360)))
    near_seam = min(x % W, W - x % W) < 160
    if random.random() < .22 and not near_seam:
        tapes.append(tape(x + 70, y + 95, f"V{random.randint(0, 8)}", c if c not in (DENIM, MOSS) else PEACH, random.uniform(-12, 12)))
    x += random.uniform(140, 260)

# Big seam-crossing volumes: a triangle volume on seams 2|3 and 4|5, a jug on 3|4 and 5|6.
volumes = []
for seam, col in ((2, MOSS), (4, DENIM)):
    sx = W * seam
    top_y = wall_top(sx) + 120
    volumes.append(
        f'<path d="M{sx - 260},{top_y + 520} L{sx + 40},{top_y} L{sx + 280},{top_y + 470} Z" fill="{col}"/>'
        f'<path d="M{sx + 40},{top_y} L{sx + 280},{top_y + 470} L{sx + 10},{top_y + 380} Z" fill="rgba(0,0,0,.2)"/>')
    volumes.append(hold(sx + 20, top_y + 300, 70, SUNNY, 20, "jug"))
for seam in (1, 3, 5):
    sx = W * seam
    volumes.append(hold(sx, wall_top(sx) + 260, 130, SUNNY if seam != 3 else ORANGE, seam * 40, "jug"))

# --- Crash pads along the floor ------------------------------------------------
pads = []
px = -180
i = 0
while px < TOTAL:
    w = random.uniform(980, 1240)
    col = [DENIM, MOSS, "#E8505B", DENIM, SUNNY, MOSS][i % 6]
    pads.append(
        f'<g><rect x="{px + 10:.0f}" y="{FLOOR}" width="{w - 20:.0f}" height="260" rx="46" fill="{col}"/>'
        f'<rect x="{px + 10:.0f}" y="{FLOOR}" width="{w - 20:.0f}" height="70" rx="40" fill="rgba(255,255,255,.18)"/>'
        f'<line x1="{px + 70:.0f}" y1="{FLOOR + 150}" x2="{px + w - 70:.0f}" y2="{FLOOR + 150}" stroke="rgba(255,255,255,.45)" stroke-width="6" stroke-dasharray="22 18"/>'
        f'<rect x="{px + w / 2 - 90:.0f}" y="{FLOOR + 175}" width="180" height="40" rx="12" fill="rgba(0,0,0,.25)"/></g>')
    px += w
    i += 1

# --- Chalk dust puffs (some on seams) -------------------------------------------
chalk = []
for cx, cy, r in [(1320, 1040, 120), (3960, 1000, 110), (6600, 1080, 130), (420, 2350, 90), (5300, 2480, 100), (7500, 2350, 110)]:
    for k in range(5):
        chalk.append(f'<circle cx="{cx + random.uniform(-r, r):.0f}" cy="{cy + random.uniform(-r * .6, r * .6):.0f}" r="{random.uniform(r * .35, r * .7):.0f}" fill="white" opacity=".22" filter="url(#blur)"/>')

# --- Chalk bag and brush on slide 6 ---------------------------------------------
bx, by = W * 5 + 120, FLOOR - 250
chalk_bag = (
    f'<g transform="translate({bx},{by}) rotate(-6)">'
    f'<path d="M0,40 Q0,250 30,260 L230,260 Q260,250 260,40 Z" fill="#E8505B"/>'
    f'<rect x="-10" y="20" width="280" height="50" rx="20" fill="{SUNNY}"/>'
    f'<ellipse cx="130" cy="30" rx="120" ry="26" fill="white" opacity=".9"/>'
    f'<path d="M30,150 L230,150" stroke="rgba(255,255,255,.5)" stroke-width="8" stroke-dasharray="14 12"/>'
    f'<rect x="170" y="-120" width="34" height="150" rx="10" fill="{DENIM}" transform="rotate(18 187 -45)"/>'
    f'<rect x="150" y="-170" width="70" height="70" rx="16" fill="{PEACH}" transform="rotate(18 187 -45)"/></g>')

# --- Phones, each with holds bolted onto its frame ------------------------------
phone_html = []
for slide, scene, cx, tilt, top in PHONES:
    left = W * slide + cx * W - PHONE_W / 2
    frame_holds = "".join([
        hold(-40, PHONE_H * .3, 88, random.choice(HOLD_COLORS), 30, "crimp"),
        hold(PHONE_W + 36, PHONE_H * .58, 96, random.choice(HOLD_COLORS), -40, "jug"),
        hold(PHONE_W * .72, -36, 74, random.choice(HOLD_COLORS), 10, "pinch"),
    ])
    phone_html.append(
        f'<div class="phone" style="left:{left:.0f}px;top:{top}px;transform:rotate({tilt}deg)">'
        f'<img src="{uri(raw / f"{scene}.png")}">'
        f'<svg class="frameholds" width="{PHONE_W + 300}" height="{PHONE_H + 300}" viewBox="-150 -150 {PHONE_W + 300} {PHONE_H + 300}">{frame_holds}</svg></div>')

# --- Stickers and speech bubbles ------------------------------------------------
stickers = [
    # (left, top, rotation, class, html). Text never crosses a seam: the App Store
    # shows a gap between screenshots, so only art and holds run across them.
    (900, 1640, -8, "bubble right", "Tuesday<br>crew?"),
    (W * 2 + 830, 1150, 10, "sticker grade", "V4–V6"),
    (W * 3 + 90, 520, -4, "bubble", "Wanna try<br>the new slab set?"),
    (W * 3 + 60, 2120, 9, "sticker round", "Overhang<br>fan"),
    (W * 5 - 330 + 380, 1300, 6, "bubble right", "Send it!"),
    (W * 5 + 40, 1720, -9, "sticker round sunny", "Flash<br>it!"),
    (W * 6 - 470, 500, 10, "sticker star", "No GPS.<br>No ads."),
    (W * 4 + 760, 470, 8, "sticker star", "Beta<br>swap!"),
]
sticker_html = "".join(
    f'<div class="{cls}" style="left:{l:.0f}px;top:{t:.0f}px;transform:rotate({r}deg)">{txt}</div>'
    for l, t, r, cls, txt in stickers)

# --- Hero art: the icon's climber on slide 1, the spotter cheering on the 1|2 seam
hero_art = (
    f'<img class="art" src="{uri(art / "art_climber.png")}" style="left:110px;top:900px;width:1100px">'
    f'<img class="art" src="{uri(art / "art_spotter.png")}" style="left:{W - 300}px;top:{FLOOR - 700}px;width:520px">')

captions = []
for i, (l1, l2) in enumerate(CAPTIONS):
    brand = (f'<div class="brand"><img src="{uri(icon)}"><span>BoulderMe</span></div>' if i == 0 else "")
    captions.append(f'<div class="cap{" hero" if i == 0 else ""}" style="left:{W * i + 100}px">{brand}'
                    f'<div class="l1">{l1}</div><div class="l2">{l2}</div></div>')

html = f"""<!doctype html><html><head><meta charset="utf-8"><style>
{font_css}
html,body{{margin:0;padding:0}}
#stage{{position:relative;width:{TOTAL}px;height:{H}px;overflow:hidden;font-family:Nunito,sans-serif;
  background:linear-gradient(100deg,#FF6D00 0%,#FF8A1F 22%,#FF7410 45%,#FF8A3D 68%,#FF7A1A 85%,#FF6D00 100%)}}
svg.bg{{position:absolute;left:0;top:0}}
.art{{position:absolute;filter:drop-shadow(0 30px 40px rgba(0,0,0,.25))}}
.phone{{position:absolute;width:{PHONE_W}px;height:{PHONE_H}px;border-radius:140px;background:#1E1816;
  box-shadow:0 0 0 10px {CREAM}, 0 70px 110px rgba(30,24,22,.55)}}
.phone img{{position:absolute;left:{BEZEL}px;top:{BEZEL}px;width:{SCREEN_W}px;height:{SCREEN_H}px;border-radius:116px}}
.frameholds{{position:absolute;left:-150px;top:-150px;overflow:visible;filter:drop-shadow(0 10px 10px rgba(0,0,0,.3))}}
.cap{{position:absolute;top:200px;width:{W - 200}px;color:white}}
.cap .l1{{font-weight:800;font-size:104px;line-height:1.04;letter-spacing:-1px}}
.cap .l2{{font-weight:900;font-size:104px;line-height:1.04;letter-spacing:-1px;color:{INK}}}
.cap.hero{{top:130px}}
.brand{{display:flex;align-items:center;gap:30px;margin-bottom:40px}}
.brand img{{width:150px;height:150px;border-radius:34px;box-shadow:0 0 0 7px {CREAM}}}
.brand span{{font-weight:900;font-size:84px;color:{CREAM}}}
.sticker,.bubble{{position:absolute;font-weight:900;color:{INK};text-align:center;line-height:1.05;
  filter:drop-shadow(0 16px 18px rgba(0,0,0,.28))}}
.sticker.grade{{background:{SUNNY};font-size:110px;padding:30px 54px;border-radius:70px;border:12px solid white}}
.sticker.round{{width:300px;height:300px;border-radius:50%;background:{PEACH};border:12px solid white;font-size:58px;
  display:flex;align-items:center;justify-content:center}}
.sticker.round.sunny{{background:{SUNNY};font-size:74px}}
.sticker.star{{width:360px;height:360px;font-size:58px;display:flex;align-items:center;justify-content:center;
  background:white;clip-path:polygon(50% 0,61% 13%,77% 6%,80% 23%,96% 26%,90% 42%,100% 55%,87% 66%,92% 83%,75% 84%,68% 100%,53% 91%,38% 100%,30% 85%,12% 86%,15% 69%,0 58%,10% 44%,3% 28%,20% 24%,22% 7%,38% 13%)}}
.bubble{{background:white;font-size:58px;padding:40px 56px;border-radius:70px}}
.bubble::after{{content:"";position:absolute;left:80px;bottom:-50px;border:30px solid transparent;border-top:44px solid white;border-left:44px solid white}}
.bubble.right::after{{left:auto;right:80px;border-left:30px solid transparent;border-right:44px solid white}}
</style></head><body><div id="stage">
<svg class="bg" width="{TOTAL}" height="{H}" viewBox="0 0 {TOTAL} {H}">
<defs>
<linearGradient id="wallgrad" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4A3C37"/><stop offset="1" stop-color="#2E2522"/></linearGradient>
<filter id="blur" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="22"/></filter>
</defs>
{''.join(f'<circle cx="{W * i + W * .8:.0f}" cy="{380 + 120 * (i % 2)}" r="{250 + 40 * (i % 3)}" fill="#FFB27F" opacity=".35"/>' for i in range(N))}
{wall}
{''.join(bolts)}
{''.join(volumes)}
{''.join(holds)}
{''.join(tapes)}
{''.join(pads)}
{''.join(chalk)}
{chalk_bag}
</svg>
{hero_art}
{''.join(phone_html)}
{sticker_html}
{''.join(captions)}
</div></body></html>"""

out.mkdir(parents=True, exist_ok=True)
(out / "panorama.html").write_text(html)
(out / "slides.json").write_text(json.dumps({"width": W, "height": H, "count": N}))
print("wrote", out / "panorama.html")

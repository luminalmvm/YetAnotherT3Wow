#!/usr/bin/env python3
"""Generate the T3Bridge addon icon (WoW-style hand-painted spell/item icon).

    python art/generate_icon.py                 # ship default concept + previews
    python art/generate_icon.py --concept tome  # ship another concept instead
    python art/generate_icon.py --no-ship       # previews only, leave icon.tga alone

Outputs
    addon/T3Bridge/Media/icon.tga   64x64 32-bit uncompressed TGA (shipped)
    art/source/icon-128.tga|png     128x128 source of the shipped concept
    art/source/icon-512.png         512x512 working master of the shipped concept
    art/previews/*.png              concept sheets and in-game mock-ups

Requires Python 3.9+, numpy, scipy, Pillow. Deterministic (fixed seeds).
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paint as P  # noqa: E402
from paint import S  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "art"
PREVIEWS = ART / "previews"
SOURCE = ART / "source"
SHIPPED = ROOT / "addon" / "T3Bridge" / "Media" / "icon.tga"


# ==========================================================================
# the "T3" glyph pair (shared by all concepts)
# ==========================================================================

def tapered_arc(c, r_out, r_in, a0, a1, taper_from, steps=48):
    """Polygon of a thick arc (degrees, clockwise, y down) whose thickness
    narrows to a point between taper_from and a1."""
    import math
    rm = (r_out + r_in) / 2
    outer, inner = [], []
    for i in range(steps + 1):
        a = a0 + (a1 - a0) * i / steps
        t = 0.0 if a <= taper_from else (a - taper_from) / (a1 - taper_from)
        t = t ** 1.3
        ro = r_out + (rm - r_out) * t
        ri = r_in + (rm - r_in) * t
        ca, sa = math.cos(math.radians(a)), math.sin(math.radians(a))
        outer.append((c[0] + ro * ca, c[1] + ro * sa))
        inner.append((c[0] + ri * ca, c[1] + ri * sa))
    return outer + inner[::-1]


def t3_glyph(scale: float = 1.0, cx: float = 0.5, cy: float = 0.5) -> np.ndarray:
    """Coverage mask of an angular, rune-like 'T3'. Designed in unit space
    centred on (0.5, 0.5) then scaled about that centre."""

    def tf(pts):
        return [(cx + (x - 0.5) * scale, cy + (y - 0.5) * scale) for x, y in pts]

    sh = P.Shape(ss=2)
    # --- T ---------------------------------------------------------------
    # top bar with flared, chamfered ends (like a hammered rune)
    sh.poly(tf([(0.150, 0.210), (0.210, 0.238), (0.428, 0.238), (0.486, 0.210),
                (0.474, 0.350), (0.428, 0.338), (0.210, 0.338), (0.162, 0.350)]))
    # stem, slightly tapering, ending in a spear point
    sh.poly(tf([(0.266, 0.300), (0.384, 0.300), (0.372, 0.690), (0.325, 0.795),
                (0.278, 0.690)]))
    # --- 3 ---------------------------------------------------------------
    # flat top bar, flared at the left end, sharp corner at the right
    sh.poly(tf([(0.545, 0.210), (0.596, 0.238), (0.800, 0.238), (0.860, 0.238),
                (0.800, 0.338), (0.596, 0.338), (0.557, 0.350)]))
    # diagonal from the top-right corner down to the middle
    sh.poly(tf([(0.745, 0.290), (0.860, 0.238), (0.712, 0.462), (0.590, 0.462)]))
    # middle spur pointing left (gives the 3 its rune-like waist)
    sh.poly(tf([(0.560, 0.468), (0.610, 0.418), (0.700, 0.418), (0.700, 0.520), (0.610, 0.520)]))
    # lower bowl, tapering to a hooked point at the lower left
    c = (0.630, 0.612)
    pts = tapered_arc(c, 0.192, 0.090, -90, 172, 120)
    sh.poly(tf(pts))
    return sh.mask()


def gold_metal(d: np.ndarray, seed: int, rim_color="#59d0ff", bevel=0.040,
               bright=1.0) -> np.ndarray:
    """Shade a glyph SDF as polished, hand-painted gold with a top-left light."""
    w = bevel * S
    h = P.height_from_sdf(d, w, "round")
    n = P.normals(h, strength=w * 1.1)
    diff = P.lambert(n)
    spec = P.blinn(n, 26)
    up = np.clip(0.5 - n[..., 1] * 1.2 - n[..., 0] * 0.4, 0, 1)  # env: sky above
    x, y = P.grid()
    face = np.clip(1.05 - (x * 0.45 + y * 0.75), 0, 1)
    scratches = P.brush_noise(seed, 28, 6)
    mott = P.fbm(seed + 1, octaves=4, base=6)
    v = 0.52 * diff + 0.22 * up + 0.22 * face
    v = v * bright + (scratches - 0.5) * 0.07 + (mott - 0.5) * 0.06
    col = P.ramp(v, [
        (0.00, "#1a0a02"),
        (0.18, "#4e2808"),
        (0.36, "#8f5414"),
        (0.52, "#c98220"),
        (0.66, "#eeb03a"),
        (0.80, "#ffd873"),
        (0.92, "#fff4cc"),
        (1.00, "#ffffff"),
    ])
    col = P.add(col, P.rgb("#fff3d0"), spec * 0.9)
    # cool rim light from the arcane glow (bottom-right facing bevels)
    rim = P.facing(n, (0.55, 0.8, 0.2)) * (1 - P.smoothstep(0.0, 0.7, h))
    col = P.screen(col, P.rgb(rim_color), rim * 0.9)
    # dark crevice right at the edge
    col = P.multiply(col, P.rgb("#2a1404"), (1 - P.smoothstep(0, 0.18, h)) * 0.5)
    return col


def draw_glyph(img, glyph, seed, glow_color="#7fe0ff", glow=0.9, shadow=0.85,
               outline=0.018, bevel=0.040, bright=1.0, rim_color="#59d0ff", rough=0.005):
    d = P.sdf(glyph)
    if rough:  # slightly irregular, worn edges instead of perfect vectors
        d = d + (P.fbm(seed + 7, octaves=4, base=12) - 0.5) * rough * S * 2
        glyph = P.smoothstep(-1, 1, d)
    # outer arcane glow hugging the letters (separates them from the bg)
    g = np.clip(1 + d / (0.09 * S), 0, 1) ** 2.2 * (d < 0)
    img = P.screen(img, P.rgb(glow_color), g * glow)
    # drop shadow down-right
    sh = P.blur(glyph, 6)
    sh = P.shift(sh, 0.018 * S, 0.026 * S)
    img = P.multiply(img, P.rgb("#05030c"), sh * shadow)
    # wide soft contact darkening: keeps the letters legible at 20 px
    wide = P.blur(glyph, 0.035 * S)
    img = P.multiply(img, P.rgb("#0a0820"), np.clip(wide * 1.6, 0, 1) * shadow * 0.45)
    # dark outline
    ol = P.smoothstep(-outline * S - 1.5, -outline * S + 1.5, d)
    img = P.over(img, P.rgb("#120a04"), ol)
    # metal
    metal = gold_metal(d, seed, rim_color=rim_color, bevel=bevel, bright=bright)
    cov = P.smoothstep(-1.0, 1.0, d)
    return P.over(img, metal, cov)


def finish(img: np.ndarray, seed: int, kuwa=2, vignette=0.55, bevel_px=0.022):
    """Shared final pass: paint daubs, vignette, thin icon-edge bevel."""
    if kuwa:
        img = P.kuwahara(img, kuwa)
    x, y = P.grid()
    r = np.sqrt((x - 0.5) ** 2 + (y - 0.5) ** 2)
    img = P.multiply(img, P.rgb("#000000"), P.smoothstep(0.38, 0.75, r) * vignette)
    # icon edge: dark rim + thin inner bevel (light top-left, dark bottom-right)
    e = np.minimum(np.minimum(x, 1 - x), np.minimum(y, 1 - y))
    band = 1 - P.smoothstep(0.0, bevel_px, e)
    tl = (x < 1 - y).astype(np.float32)
    tl = P.blur(tl, 3)
    img = P.screen(img, P.rgb("#fff1c8"), band * tl * 0.22)
    img = P.multiply(img, P.rgb("#000000"), band * (1 - tl) * 0.45)
    outer = 1 - P.smoothstep(0.0, 0.008, e)
    img = P.over(img, P.rgb("#050302"), outer * 0.85)
    # fine canvas grain
    grain = P.fbm(seed + 99, octaves=2, base=96)
    img = img * (1 + (grain[..., None] - 0.5) * 0.06)
    return np.clip(img, 0, 1)


# ==========================================================================
# Concept A - gilded T3 rune over an arcane crystal
# ==========================================================================

def concept_crystal() -> np.ndarray:
    x, y = P.grid()
    r = np.sqrt((x - 0.5) ** 2 + (y - 0.52) ** 2)

    # --- painted backdrop: deep violet/indigo with swirling arcane mist ---
    n1 = P.swirl(P.fbm(11, octaves=6, base=3), 0.5, 0.52, 2.6)
    n2 = P.brush_noise(12, 35, 9)
    v = 0.55 * n1 + 0.25 * n2 + 0.45 * (1 - P.smoothstep(0.0, 0.62, r))
    img = P.ramp(v, [
        (0.00, "#07051a"),
        (0.30, "#1b1150"),
        (0.55, "#33208a"),
        (0.75, "#2f5ad0"),
        (0.92, "#5cb9ff"),
        (1.00, "#bff0ff"),
    ])
    # wisps of brighter arcane energy
    wisp = P.smoothstep(0.62, 0.9, P.swirl(P.fbm(13, octaves=5, base=5), 0.5, 0.52, 4.0))
    img = P.screen(img, P.rgb("#8a6cff"), wisp * 0.45 * (1 - P.smoothstep(0.2, 0.7, r)))

    # faint arcane circle with rune ticks
    rr = np.sqrt((x - 0.5) ** 2 + (y - 0.505) ** 2)
    ang = np.arctan2(y - 0.505, x - 0.5)
    ring = np.exp(-((rr - 0.425) / 0.006) ** 2) + 0.6 * np.exp(-((rr - 0.385) / 0.004) ** 2)
    ticks = (np.cos(ang * 16) > 0.82) * np.exp(-((rr - 0.405) / 0.012) ** 2)
    img = P.screen(img, P.rgb("#7fd2ff"), np.clip(ring + ticks, 0, 1) * 0.45)

    # --- faceted crystal --------------------------------------------------
    top, bot = (0.5, 0.055), (0.5, 0.955)
    ul, ur = (0.265, 0.30), (0.735, 0.30)
    ll, lr = (0.300, 0.735), (0.700, 0.735)
    mid = (0.52, 0.47)
    crystal = P.Shape().poly([top, ur, lr, bot, ll, ul]).mask()
    facets = [  # (polygon, brightness) - light comes from top-left
        ([top, ul, mid], 0.95),
        ([top, mid, ur], 0.62),
        ([ul, ll, mid], 0.72),
        ([ur, mid, lr], 0.30),
        ([ll, bot, mid], 0.48),
        ([mid, bot, lr], 0.16),
    ]
    fac = np.zeros((S, S), np.float32)
    for pts, b in facets:
        m = P.Shape().poly(pts).mask()
        fac = np.maximum(fac, m * b)
    fac = P.blur(fac, 1.2)
    cloud = P.fbm(21, octaves=5, base=4)
    core = np.exp(-((x - 0.5) ** 2 / 0.020 + (y - 0.50) ** 2 / 0.045))
    cv = fac * 0.85 + cloud * 0.14 + core * 0.35
    ccol = P.ramp(cv, [
        (0.00, "#06123a"),
        (0.25, "#0d3a8e"),
        (0.50, "#1f78d8"),
        (0.72, "#4fc4ff"),
        (0.88, "#a8ecff"),
        (1.00, "#f2fdff"),
    ])
    # facet edge highlights
    edges = np.zeros((S, S), np.float32)
    for pts, _ in facets:
        m = P.Shape().poly(pts).mask()
        dd = np.abs(P.sdf(m))
        edges = np.maximum(edges, np.exp(-(dd / 1.6) ** 2) * (m > 0.02))
    ccol = P.screen(ccol, P.rgb("#d8f6ff"), edges * 0.55 * (1 - y * 0.6)[..., None][..., 0])
    # bright glint streak on the lit upper-left facet
    streak = np.exp(-(((x - 0.5) * 0.8 + (y - 0.30) * 0.6 + 0.07) / 0.012) ** 2) * P.smoothstep(0.08, 0.2, y)         * (1 - P.smoothstep(0.30, 0.42, y)) * (x < 0.5)
    ccol = P.screen(ccol, P.rgb("#ffffff"), streak * 0.6)
    cd = P.sdf(crystal)
    # crystal halo
    halo = np.clip(1 + cd / (0.16 * S), 0, 1) ** 2.5 * (cd < 0)
    img = P.screen(img, P.rgb("#3aa8ff"), halo * 0.75)
    img = P.over(img, P.rgb("#050a20"), P.smoothstep(-0.012 * S - 1, -0.012 * S + 1, cd))
    img = P.over(img, ccol, P.smoothstep(-1, 1, cd))

    # sparkles
    for (sx, sy, sr, rot) in [(0.17, 0.20, 0.10, 0.0), (0.84, 0.80, 0.08, 0.3),
                              (0.82, 0.16, 0.06, 0.2), (0.15, 0.84, 0.05, 0.0)]:
        img = P.screen(img, P.rgb("#dff7ff"), P.star(sx, sy, sr, 0.05, rot) * 0.9)

    # --- the gilded T3 ---------------------------------------------------
    glyph = t3_glyph(scale=1.0, cx=0.5, cy=0.505)
    img = draw_glyph(img, glyph, seed=31)
    return finish(img, seed=41)


# ==========================================================================
# Concept B - ancient tome with a glowing T3 seal
# ==========================================================================

def concept_tome() -> np.ndarray:
    x, y = P.grid()
    r = np.sqrt((x - 0.5) ** 2 + (y - 0.5) ** 2)
    # backdrop: warm dark umber with candle glow
    n = P.fbm(51, octaves=6, base=3)
    v = 0.6 * n + 0.5 * (1 - P.smoothstep(0, 0.75, r))
    img = P.ramp(v, [(0, "#0a0604"), (0.4, "#2b1709"), (0.7, "#5a3313"), (1, "#a8692a")])

    # book block, rotated slightly; built in a local frame
    ang = np.deg2rad(-8)
    ca, sa = np.cos(ang), np.sin(ang)

    def rot(pts, c=(0.5, 0.5)):
        out = []
        for px, py in pts:
            dx, dy = px - c[0], py - c[1]
            out.append((c[0] + dx * ca - dy * sa, c[1] + dx * sa + dy * ca))
        return out

    pages = P.Shape().poly(rot([(0.20, 0.13), (0.86, 0.13), (0.86, 0.90), (0.20, 0.90)])).mask()
    cover = P.Shape().poly(rot([(0.13, 0.08), (0.82, 0.08), (0.82, 0.87), (0.13, 0.87)])).mask()
    spine = P.Shape().poly(rot([(0.10, 0.07), (0.22, 0.07), (0.22, 0.88), (0.10, 0.88)])).mask()
    # pages (cream, striped) peeking at right/bottom
    stripes = 0.5 + 0.5 * np.sin((x * ca + y * sa) * S * 0.9)
    pcol = P.ramp(0.55 + 0.25 * stripes * 0.4 + (P.fbm(52, 3, 8) - 0.5) * 0.2,
                  [(0, "#5a4426"), (0.5, "#cdb48a"), (1, "#f4e6c4")])
    pd = P.sdf(pages)
    img = P.multiply(img, P.rgb("#000000"), P.shift(P.blur(pages, 8), 10, 14) * 0.8)
    img = P.over(img, P.rgb("#140c06"), P.smoothstep(-3, -1, pd))
    img = P.over(img, pcol, P.smoothstep(-1, 1, pd))
    # leather cover
    cd = P.sdf(cover)
    h = P.height_from_sdf(cd, 0.05 * S, "soft")
    leather = P.fbm(53, octaves=6, base=6)
    h2 = h + (leather - 0.5) * 0.06
    nn = P.normals(h2, 0.05 * S)
    lv = P.lambert(nn) * 0.65 + (1 - (x * 0.4 + y * 0.6)) * 0.35 + (leather - 0.5) * 0.25
    lcol = P.ramp(lv, [(0, "#1a0805"), (0.35, "#4a1a0e"), (0.6, "#7a2e16"), (0.85, "#b0532a"), (1, "#d88a4e")])
    img = P.over(img, P.rgb("#0d0503"), P.smoothstep(-3, -1, cd))
    img = P.over(img, lcol, P.smoothstep(-1, 1, cd))
    # spine band
    sd_ = P.sdf(spine)
    sh_ = P.height_from_sdf(sd_, 0.04 * S, "round")
    sn = P.normals(sh_, 0.05 * S)
    scol = P.ramp(P.lambert(sn) * 0.8 + 0.1 + (leather - 0.5) * 0.2,
                  [(0, "#120503"), (0.5, "#5a2010"), (1, "#a2502a")])
    img = P.over(img, scol, P.smoothstep(-1, 1, sd_))
    # gold corner guards
    corners = P.Shape()
    for (cx_, cy_, sx_, sy_) in [(0.82, 0.08, -1, 1), (0.82, 0.87, -1, -1), (0.22, 0.08, 1, 1), (0.22, 0.87, 1, -1)]:
        corners.poly(rot([(cx_, cy_), (cx_ + sx_ * 0.17, cy_), (cx_, cy_ + sy_ * 0.17)]))
    cg = corners.mask() * cover
    img = draw_glyph(img, cg, seed=54, glow=0.0, shadow=0.5, outline=0.008, bevel=0.02, bright=0.9,
                     rim_color="#d08a40")
    # round gold seal with a glowing arcane centre
    seal = P.Shape().circle((0.50, 0.48), 0.335).mask()
    img = draw_glyph(img, seal, seed=55, glow=0.0, shadow=0.9, outline=0.012, bevel=0.05,
                     rim_color="#e0a050")
    inner = P.Shape().circle((0.50, 0.48), 0.285).mask()
    idd = P.sdf(inner)
    core = np.exp(-(((x - 0.47) ** 2 + (y - 0.45) ** 2) / 0.02))
    icol = P.ramp(P.fbm(56, 5, 4) * 0.35 + core * 0.75,
                  [(0, "#061038"), (0.4, "#1a4fc0"), (0.75, "#56c8ff"), (1, "#e8fbff")])
    img = P.over(img, P.rgb("#0a0603"), P.smoothstep(-2, 0, idd))
    img = P.over(img, icol, P.smoothstep(-0.5, 1.5, idd) * 1.0)
    # inner shadow of the seal recess (top-left)
    ish = P.shift(1 - P.blur(inner, 7), 6, 8) * inner
    img = P.multiply(img, P.rgb("#000000"), ish * 0.8)
    glyph = t3_glyph(scale=0.66, cx=0.50, cy=0.485)
    img = draw_glyph(img, glyph, seed=57, glow=1.0, shadow=0.7, outline=0.014, bevel=0.022,
                     glow_color="#9fe8ff")
    for (sx, sy, sr) in [(0.30, 0.30, 0.06), (0.70, 0.66, 0.05)]:
        img = P.screen(img, P.rgb("#e6fbff"), P.star(sx, sy, sr, 0.05) * 0.85)
    return finish(img, seed=58)


# ==========================================================================
# Concept C - carved runestone with a glowing T3
# ==========================================================================

def concept_runestone() -> np.ndarray:
    x, y = P.grid()
    r = np.sqrt((x - 0.5) ** 2 + (y - 0.5) ** 2)
    n = P.fbm(61, octaves=6, base=3)
    v = 0.45 * n + 0.55 * (1 - P.smoothstep(0, 0.7, r))
    img = P.ramp(v, [(0, "#04060c"), (0.45, "#0c1a33"), (0.8, "#1e4a7a"), (1, "#4a9ad0")])
    # stone slab with chipped silhouette
    slab = P.Shape().poly([(0.20, 0.09), (0.50, 0.06), (0.79, 0.07), (0.90, 0.21), (0.92, 0.55),
                           (0.87, 0.87), (0.70, 0.95), (0.40, 0.94), (0.16, 0.92), (0.09, 0.70),
                           (0.10, 0.45), (0.12, 0.24)]).mask()
    sd_ = P.sdf(slab) + (P.fbm(66, 5, 8) - 0.5) * 0.03 * S
    slab = P.smoothstep(-1, 1, sd_)
    h = P.height_from_sdf(sd_, 0.09 * S, "round")
    rock = P.fbm(62, octaves=7, base=5)
    fine = P.fbm(67, octaves=3, base=48)
    cr = P.fbm(63, 5, 5)
    cracks = np.exp(-((cr - 0.5) / 0.012) ** 2)
    h2 = h + (rock - 0.5) * 0.22 + (fine - 0.5) * 0.05 - cracks * 0.06
    nn = P.normals(h2, 0.07 * S)
    sv = P.lambert(nn) * 0.8 + (1 - (x * 0.4 + y * 0.6)) * 0.2 + (rock - 0.5) * 0.2
    scol = P.ramp(sv, [(0, "#0b0c10"), (0.3, "#2c2f36"), (0.55, "#575a62"), (0.8, "#8f8e8a"),
                       (1, "#cfc9b8")])
    warm = P.fbm(68, 4, 3)
    scol = P.multiply(scol, P.rgb("#c8a888"), warm * 0.35)
    moss = P.smoothstep(0.60, 0.78, P.fbm(64, 5, 4)) * P.smoothstep(0.45, 1.0, y)
    scol = P.over(scol, P.ramp(P.fbm(69, 3, 20), [(0, "#24361a"), (1, "#6a8a34")]), moss * 0.7)
    img = P.multiply(img, P.rgb("#000000"), P.shift(P.blur(slab, 9), 10, 14) * 0.85)
    img = P.over(img, P.rgb("#07080a"), P.smoothstep(-4, -1, sd_))
    img = P.over(img, scol, P.smoothstep(-1, 1, sd_))
    # carved, glowing T3
    glyph = t3_glyph(scale=0.95, cx=0.5, cy=0.5)
    gd = P.sdf(glyph)
    g = np.clip(1 + gd / (0.07 * S), 0, 1) ** 2 * (gd < 0)
    img = P.screen(img, P.rgb("#2a9cff"), g * 0.7)
    # dark lip of the carving
    img = P.over(img, P.rgb("#04101e"), P.smoothstep(-0.012 * S - 1, -0.012 * S + 1, gd))
    depth = P.smoothstep(0, 0.045 * S, gd)
    ccol = P.ramp(0.35 + depth * 0.65, [(0, "#0b3c8a"), (0.45, "#1e8cff"), (0.75, "#6fd8ff"), (1, "#e8fcff")])
    img = P.over(img, ccol, P.smoothstep(-1, 1, gd))
    # carved walls: the upper-left inner wall is in shadow
    shadow_in = P.shift(1 - P.blur(glyph, 3), 4, 6) * glyph
    img = P.multiply(img, P.rgb("#03081c"), shadow_in * 0.75)
    for (sx, sy, sr) in [(0.24, 0.20, 0.07), (0.80, 0.80, 0.06)]:
        img = P.screen(img, P.rgb("#e6fbff"), P.star(sx, sy, sr, 0.05) * 0.8)
    return finish(img, seed=65)


CONCEPTS = {
    "crystal": ("Gilded T3 rune over an arcane crystal", concept_crystal),
    "tome": ("Ancient tome with a glowing T3 seal", concept_tome),
    "runestone": ("Carved runestone with a glowing T3", concept_runestone),
}
DEFAULT = "crystal"


# ==========================================================================
# output: TGA writer/reader, resampling, previews
# ==========================================================================

def downsample(img: Image.Image, size: int) -> Image.Image:
    out = img.resize((size, size), Image.LANCZOS)
    if size <= 64:
        out = P.sharpen(out, amount=0.45, radius=0.6)
    return out


def write_tga(img: Image.Image, path: Path) -> None:
    """32-bit uncompressed true-colour TGA, bottom-left origin (descriptor
    0x08 = 8 alpha bits, origin bit clear) - the same layout as the original
    icon.tga and the most widely supported variant (WoW reads it fine)."""
    img = img.convert("RGBA")
    w, h = img.size
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x08)
    a = np.asarray(img, np.uint8)
    bgra = a[..., [2, 1, 0, 3]][::-1]  # flip rows: first row stored = bottom row
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + bgra.tobytes())


def read_tga(path: Path) -> Image.Image:
    """Independent minimal reader (honours the origin bit) used to verify."""
    b = path.read_bytes()
    idlen, cmtype, imtype = b[0], b[1], b[2]
    w, h = struct.unpack("<HH", b[12:16])
    bpp, desc = b[16], b[17]
    assert cmtype == 0 and imtype == 2 and bpp == 32, (cmtype, imtype, bpp)
    data = np.frombuffer(b, np.uint8, w * h * 4, 18 + idlen).reshape(h, w, 4)
    rgba = data[..., [2, 1, 0, 3]]
    if not desc & 0x20:  # bottom-left origin
        rgba = rgba[::-1]
    if desc & 0x10:
        rgba = rgba[:, ::-1]
    return Image.fromarray(np.ascontiguousarray(rgba), "RGBA")


def circle_mask(size, ss=4, inset=0.0):
    m = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(m).ellipse([inset * ss, inset * ss, (size - inset) * ss - 1, (size - inset) * ss - 1], fill=255)
    return m.resize((size, size), Image.LANCZOS)


def gold_ring_layer(size, r_out, r_in, ss=4):
    """Procedural bronze-gold ring (stand-in for the game's frame art)."""
    W = size * ss
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float32)
    c = W / 2
    rr = np.sqrt((xx - c) ** 2 + (yy - c) ** 2) / ss
    t = np.clip((rr - r_in) / (r_out - r_in), 0, 1)
    prof = np.sin(t * np.pi)  # raised round ring
    ang = np.arctan2(yy - c, xx - c)
    light = 0.5 + 0.5 * np.cos(ang - np.deg2rad(225)) * (1 - 2 * t)
    v = 0.25 + 0.55 * prof * light + 0.25 * prof
    col = P.ramp(v, [(0, "#2a1606"), (0.35, "#6e4416"), (0.6, "#b88a3a"), (0.85, "#ecd08a"), (1, "#fff4c8")])
    a = ((rr >= r_in) & (rr <= r_out)).astype(np.float32)
    im = P.to_image(col, a)
    return im.resize((size, size), Image.LANCZOS)


def game_bg(w, h, seed=7):
    rng = np.random.default_rng(seed)
    n = P.value_noise(rng, 6, size=max(w, h))[:h, :w]
    base = np.stack([0.10 + n * 0.06, 0.09 + n * 0.05, 0.07 + n * 0.04], -1)
    return Image.fromarray((np.clip(base, 0, 1) * 255).astype(np.uint8), "RGB").convert("RGBA")


def mock_portrait(icon128: Image.Image, scale=3) -> Image.Image:
    """~60px round portrait with a gold ring, like PortraitFrameTemplate."""
    size = 74
    canvas = game_bg(size, size)
    port = icon128.resize((60, 60), Image.LANCZOS)
    canvas.paste(port, (7, 7), circle_mask(60))
    ring = gold_ring_layer(size, 37, 29.5)
    canvas.alpha_composite(ring)
    return canvas.resize((size * scale, size * scale), Image.NEAREST)


def mock_minimap(icon64: Image.Image, scale=6) -> Image.Image:
    """31x31 minimap button: dark disc, 20px circle-masked icon, ring."""
    size = 31
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    disc = Image.new("RGBA", (20, 20), (12, 10, 8, 255))
    canvas.paste(disc, (6, 5), circle_mask(20))
    ic = icon64.resize((20, 20), Image.LANCZOS)
    canvas.paste(ic, (6, 5), circle_mask(20))
    ring = gold_ring_layer(32, 15.6, 10.4)  # centred on (16, 16)
    canvas.alpha_composite(ring.crop((0, 1, 31, 32)))  # -> centre (16, 15) = icon centre
    bg = game_bg(size, size, 3)
    bg.alpha_composite(canvas)
    return bg.resize((size * scale, size * scale), Image.NEAREST)


def contact_sheet(name, master: Image.Image) -> Image.Image:
    i128 = downsample(master, 128)
    i64 = downsample(master, 64)
    i20 = i64.resize((20, 20), Image.LANCZOS)
    W, H = 760, 300
    sheet = game_bg(W, H, 11)
    # square item-icon views
    sheet.alpha_composite(i128, (20, 40))
    sheet.alpha_composite(i64, (168, 40))
    sheet.alpha_composite(i64.resize((40, 40), Image.LANCZOS), (168, 120))
    sheet.alpha_composite(i20, (168, 180))
    sheet.alpha_composite(i20.resize((80, 80), Image.NEAREST), (20, 190))
    # 1:1 in-game-size round views
    sheet.alpha_composite(mock_portrait(i128, 1), (250, 40))
    sheet.alpha_composite(mock_minimap(i64, 1), (340, 60))
    # enlarged mock-ups
    sheet.alpha_composite(mock_portrait(i128, 2), (400, 20))
    sheet.alpha_composite(mock_minimap(i64, 5), (560, 20))
    d = ImageDraw.Draw(sheet)
    d.text((20, 10), name, fill=(255, 210, 90, 255))
    d.text((20, 172), "128 / 64 / 40 / 20 px  (20px x4 nearest below)", fill=(200, 190, 160, 255))
    d.text((400, 175), "portrait mock x2", fill=(200, 190, 160, 255))
    d.text((560, 182), "minimap button mock x5 (20px icon)", fill=(200, 190, 160, 255))
    return sheet


def overview(masters, chosen) -> Image.Image:
    keys = list(masters)
    W, H = 40 + 230 * len(keys), 330
    sheet = game_bg(W, H, 5)
    d = ImageDraw.Draw(sheet)
    for i, k in enumerate(keys):
        x0 = 20 + i * 230
        i128 = downsample(masters[k], 128)
        i64 = downsample(masters[k], 64)
        sheet.alpha_composite(i128, (x0, 40))
        sheet.alpha_composite(i64, (x0 + 140, 40))
        sheet.alpha_composite(i64.resize((20, 20), Image.LANCZOS), (x0 + 140, 116))
        sheet.alpha_composite(mock_minimap(i64, 1), (x0 + 172, 110))
        sheet.alpha_composite(mock_portrait(i128, 1), (x0 + 140, 150))
        sheet.alpha_composite(i64.resize((20, 20), Image.LANCZOS).resize((80, 80), Image.NEAREST), (x0, 190))
        label = f"{k}{'  (shipped)' if k == chosen else ''}"
        d.text((x0, 14), label, fill=(255, 210, 90, 255) if k == chosen else (200, 190, 160, 255))
        d.text((x0, 280), "20px x4 nearest", fill=(150, 140, 120, 255))
    return sheet


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--concept", default=DEFAULT, choices=sorted(CONCEPTS))
    ap.add_argument("--only", choices=sorted(CONCEPTS), help="render just this concept's preview")
    ap.add_argument("--no-ship", action="store_true", help="do not overwrite addon icon.tga")
    args = ap.parse_args(argv)

    PREVIEWS.mkdir(parents=True, exist_ok=True)
    SOURCE.mkdir(parents=True, exist_ok=True)
    masters = {}
    names = [args.only] if args.only else list(CONCEPTS)
    if args.concept not in names and not args.no_ship:
        names.append(args.concept)
    for key in names:
        title, fn = CONCEPTS[key]
        print(f"painting {key} ...", flush=True)
        arr = fn()
        master = P.to_image(arr)
        masters[key] = master
        contact_sheet(f"{key}: {title}", master).save(PREVIEWS / f"concept-{key}.png")
        downsample(master, 128).save(PREVIEWS / f"concept-{key}-128.png")

    if len(masters) > 1:
        overview(masters, args.concept).save(PREVIEWS / "concepts-overview.png")

    if not args.no_ship:
        master = masters[args.concept]
        master.save(SOURCE / "icon-512.png")
        i128 = downsample(master, 128)
        i64 = downsample(master, 64)
        i128.save(SOURCE / "icon-128.png")
        write_tga(i128, SOURCE / "icon-128.tga")
        write_tga(i64, SHIPPED)
        # verify: read back with our own reader and with Pillow
        back = read_tga(SHIPPED)
        assert back.size == (64, 64)
        assert np.array_equal(np.asarray(back), np.asarray(i64.convert("RGBA"))), "TGA round-trip mismatch"
        pil = Image.open(SHIPPED).convert("RGBA")
        assert np.array_equal(np.asarray(pil), np.asarray(i64.convert("RGBA"))), "Pillow reads TGA differently"
        back.save(PREVIEWS / "shipped-icon-readback-64.png")
        back.resize((256, 256), Image.NEAREST).save(PREVIEWS / "shipped-icon-readback-x4.png")
        # in-game style mock-ups of the shipped icon
        mock_portrait(i128, 3).save(PREVIEWS / "mock-portrait.png")
        mock_minimap(i64, 6).save(PREVIEWS / "mock-minimap.png")
        print(f"wrote {SHIPPED} ({SHIPPED.stat().st_size} bytes) from concept '{args.concept}'")


if __name__ == "__main__":
    main()

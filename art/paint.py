"""Small procedural-painting toolkit used by generate_icon.py.

Everything works on float32 numpy arrays at a supersampled working size
(S x S, default 512 = 8x the shipped 64 px icon). Coordinates passed to the
shape helpers are in unit space: (0, 0) is the top-left corner of the icon,
(1, 1) the bottom-right, y points down.

No external assets: all texture comes from seeded noise, all shapes are
drawn from coordinates in this repo.
"""
from __future__ import annotations

import math

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

S = 512  # working resolution


# --------------------------------------------------------------------------
# basics
# --------------------------------------------------------------------------

def grid(size: int = S):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    return (x + 0.5) / size, (y + 0.5) / size


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def rgb(hexstr: str) -> np.ndarray:
    hexstr = hexstr.lstrip("#")
    return np.array([int(hexstr[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], np.float32)


def fill(color) -> np.ndarray:
    return np.ones((S, S, 3), np.float32) * np.asarray(color, np.float32)


def over(dst: np.ndarray, src, alpha: np.ndarray) -> np.ndarray:
    """Alpha-blend src (HxWx3 or colour) over dst with coverage alpha (HxW)."""
    a = np.clip(alpha, 0, 1)[..., None]
    return dst * (1 - a) + np.asarray(src, np.float32) * a


def screen(dst, src, amount):
    a = np.clip(amount, 0, 1)[..., None]
    s = np.asarray(src, np.float32)
    return 1 - (1 - dst) * (1 - s * a)


def add(dst, src, amount):
    a = np.clip(amount, 0, None)[..., None]
    return dst + np.asarray(src, np.float32) * a


def multiply(dst, src, amount):
    a = np.clip(amount, 0, 1)[..., None]
    s = np.asarray(src, np.float32)
    return dst * (1 - a + s * a)


def ramp(v: np.ndarray, stops) -> np.ndarray:
    """Map scalar field v (0..1) through colour stops [(pos, '#hex'), ...]."""
    pos = np.array([p for p, _ in stops], np.float32)
    cols = np.stack([rgb(c) if isinstance(c, str) else np.asarray(c, np.float32) for _, c in stops])
    v = np.clip(v, 0, 1)
    out = np.empty(v.shape + (3,), np.float32)
    for ch in range(3):
        out[..., ch] = np.interp(v, pos, cols[:, ch])
    return out


# --------------------------------------------------------------------------
# noise
# --------------------------------------------------------------------------

def value_noise(rng, cells: int, size: int = S, aspect=(1.0, 1.0)) -> np.ndarray:
    cx = max(2, int(cells * aspect[0]))
    cy = max(2, int(cells * aspect[1]))
    a = rng.random((cy + 1, cx + 1)).astype(np.float32)
    img = Image.fromarray(a, mode="F").resize((size, size), Image.BICUBIC)
    return np.asarray(img, np.float32)


def fbm(seed: int, octaves: int = 5, base: int = 4, persistence: float = 0.55,
        aspect=(1.0, 1.0), size: int = S) -> np.ndarray:
    rng = np.random.default_rng(seed)
    out = np.zeros((size, size), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * value_noise(rng, base * 2 ** o, size, aspect)
        tot += amp
        amp *= persistence
    out /= tot
    lo, hi = np.percentile(out, 1), np.percentile(out, 99)
    return np.clip((out - lo) / (hi - lo), 0, 1)


def brush_noise(seed: int, angle_deg: float, length: float = 10.0, size: int = S) -> np.ndarray:
    """Streaky noise that looks like short brush strokes along angle_deg."""
    rng = np.random.default_rng(seed)
    n = rng.random((size, size)).astype(np.float32)
    n = ndi.gaussian_filter(n, (0.8, length))  # streak horizontally
    n = ndi.rotate(n, angle_deg, reshape=False, mode="reflect", order=1)
    n = ndi.gaussian_filter(n, 0.7)
    lo, hi = np.percentile(n, 1), np.percentile(n, 99)
    return np.clip((n - lo) / (hi - lo), 0, 1)


def swirl(field: np.ndarray, cx=0.5, cy=0.5, strength=2.0) -> np.ndarray:
    """Rotate a field around a centre by an angle that falls off with radius."""
    size = field.shape[0]
    x, y = grid(size)
    dx, dy = x - cx, y - cy
    r = np.sqrt(dx * dx + dy * dy)
    ang = strength * np.exp(-r * 4.0)
    ca, sa = np.cos(ang), np.sin(ang)
    sx = (cx + dx * ca - dy * sa) * size - 0.5
    sy = (cy + dx * sa + dy * ca) * size - 0.5
    return ndi.map_coordinates(field, [sy, sx], order=1, mode="reflect").astype(np.float32)


# --------------------------------------------------------------------------
# shapes -> coverage masks and signed distance fields
# --------------------------------------------------------------------------

class Shape:
    """Accumulates vector primitives (unit coords) and rasterises them."""

    def __init__(self, ss: int = 2):
        self.ss = ss
        self.W = S * ss
        self.img = Image.new("L", (self.W, self.W), 0)

    def _p(self, pts):
        return [(x * self.W, y * self.W) for x, y in pts]

    def poly(self, pts, value=255):
        layer = Image.new("L", (self.W, self.W), 0)
        ImageDraw.Draw(layer).polygon(self._p(pts), fill=255)
        self._merge(layer, value)
        return self

    def circle(self, c, r, value=255):
        layer = Image.new("L", (self.W, self.W), 0)
        x, y = c
        ImageDraw.Draw(layer).ellipse([(x - r) * self.W, (y - r) * self.W,
                                       (x + r) * self.W, (y + r) * self.W], fill=255)
        self._merge(layer, value)
        return self

    def arc(self, c, r_out, r_in, start, end, value=255):
        """Thick arc; angles in degrees, 0 = +x (right), clockwise (y down)."""
        layer = Image.new("L", (self.W, self.W), 0)
        d = ImageDraw.Draw(layer)
        x, y = c
        d.pieslice([(x - r_out) * self.W, (y - r_out) * self.W,
                    (x + r_out) * self.W, (y + r_out) * self.W], start, end, fill=255)
        d.ellipse([(x - r_in) * self.W, (y - r_in) * self.W,
                   (x + r_in) * self.W, (y + r_in) * self.W], fill=0)
        self._merge(layer, value)
        return self

    def _merge(self, layer, value):
        a = np.asarray(self.img, np.int16)
        b = np.asarray(layer, np.int16)
        if value == 255:
            out = np.maximum(a, b)
        else:  # subtract
            out = np.minimum(a, 255 - b)
        self.img = Image.fromarray(out.astype(np.uint8), "L")

    def mask(self) -> np.ndarray:
        return np.asarray(self.img.resize((S, S), Image.BOX), np.float32) / 255.0


def sdf(mask: np.ndarray) -> np.ndarray:
    """Signed distance in working pixels; positive inside, negative outside."""
    m = mask > 0.5
    inside = ndi.distance_transform_edt(m)
    outside = ndi.distance_transform_edt(~m)
    d = (inside - outside).astype(np.float32)
    return ndi.gaussian_filter(d, 0.8)


def blur(a, sigma):
    if a.ndim == 3:
        return np.stack([ndi.gaussian_filter(a[..., i], sigma) for i in range(a.shape[2])], -1)
    return ndi.gaussian_filter(a, sigma)


def shift(a, dx, dy):
    return ndi.shift(a, (dy, dx) + ((0,) if a.ndim == 3 else ()), order=1, mode="nearest")


# --------------------------------------------------------------------------
# lighting
# --------------------------------------------------------------------------

LIGHT = np.array([-0.55, -0.70, 0.62], np.float32)
LIGHT /= np.linalg.norm(LIGHT)


def height_from_sdf(d: np.ndarray, width: float, profile: str = "round") -> np.ndarray:
    t = np.clip(d / width, 0, 1)
    if profile == "round":
        h = np.sqrt(1 - (1 - t) ** 2)
    elif profile == "chamfer":
        h = t
    else:  # soft
        h = t * t * (3 - 2 * t)
    return ndi.gaussian_filter(h, 1.0)


def normals(h: np.ndarray, strength: float) -> np.ndarray:
    gy, gx = np.gradient(h)
    n = np.stack([-gx * strength, -gy * strength, np.ones_like(h)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n


def lambert(n, light=LIGHT):
    return np.clip((n * light).sum(-1), 0, 1)


def blinn(n, power=30.0, light=LIGHT):
    hv = light + np.array([0, 0, 1], np.float32)
    hv /= np.linalg.norm(hv)
    return np.clip((n * hv).sum(-1), 0, 1) ** power


def facing(n, direction):
    d = np.asarray(direction, np.float32)
    d /= np.linalg.norm(d)
    return np.clip((n * d).sum(-1), 0, 1)


# --------------------------------------------------------------------------
# painterly filters
# --------------------------------------------------------------------------

def kuwahara(img: np.ndarray, radius: int = 3) -> np.ndarray:
    """Classic 4-quadrant Kuwahara filter: flattens detail into paint daubs."""
    k = radius + 1
    h = radius // 2 if radius % 2 == 0 else (radius + 1) // 2
    lum = img.mean(-1)
    m = np.stack([ndi.uniform_filter(img[..., c], k, mode="reflect") for c in range(3)], -1)
    ml = ndi.uniform_filter(lum, k, mode="reflect")
    v = ndi.uniform_filter(lum * lum, k, mode="reflect") - ml * ml
    means, vars_ = [], []
    for dy in (-h, h):
        for dx in (-h, h):
            means.append(np.roll(m, (-dy, -dx), (0, 1)))
            vars_.append(np.roll(v, (-dy, -dx), (0, 1)))
    idx = np.argmin(np.stack(vars_), 0)
    means = np.stack(means)
    return np.take_along_axis(means, idx[None, ..., None].repeat(3, -1), 0)[0]


def sharpen(img: Image.Image, amount=0.6, radius=0.8) -> Image.Image:
    from PIL import ImageFilter
    return img.filter(ImageFilter.UnsharpMask(radius=radius, percent=int(amount * 100), threshold=0))


def to_image(arr: np.ndarray, alpha: np.ndarray | None = None) -> Image.Image:
    a = np.clip(arr, 0, 1)
    u8 = (a * 255 + 0.5).astype(np.uint8)
    if alpha is None:
        alpha = np.ones(arr.shape[:2], np.float32)
    al = (np.clip(alpha, 0, 1) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(np.dstack([u8, al]), "RGBA")


def star(cx, cy, r, thickness=0.06, rot=0.0):
    """Four-point sparkle intensity field."""
    x, y = grid()
    dx, dy = (x - cx), (y - cy)
    ca, sa = math.cos(rot), math.sin(rot)
    u, v = dx * ca - dy * sa, dx * sa + dy * ca
    au, av = np.abs(u) / r, np.abs(v) / r
    arm1 = np.clip(1 - au, 0, 1) * np.exp(-(av / thickness) ** 2)
    arm2 = np.clip(1 - av, 0, 1) * np.exp(-(au / thickness) ** 2)
    core = np.exp(-((dx * dx + dy * dy) / (r * 0.18) ** 2))
    return np.clip(arm1 ** 1.5 + arm2 ** 1.5 + core, 0, 1)

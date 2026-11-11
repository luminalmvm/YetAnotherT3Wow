#!/usr/bin/env python3
"""Crop and mask the README screenshots from one full in-game screenshot.

The full screenshot is NOT part of the repo (it shows the rest of the game UI, including other
players' names). This script documents exactly which regions are published and which are masked,
so the images can be re-made from a new screenshot.

    python art/make_screenshots.py --source <full 2000x1125 screenshot.png> --out docs/img --mask-titles

Crops (coordinates in the 2000x1125 source):
    chat-window.png  the T3 Code chat window          (543, 292) - (1422, 900)
    tracker.png      the T3 Code tracker block         (1735, 830) - (2000, 1028)
    minimap.png      the minimap with the T3 button    (1780, 40) - (1985, 245)

Masks (pixelated with large blocks so the text cannot be read at any zoom):
    always           the file path in the chat window's "Tool" line (it contains a local user name)
    --mask-titles    the four tracker rows whose titles start with "Pro:" (rows 8 to 11); every
                     other title, the header, status icons and timers stay visible

Needs Pillow (pip install pillow).
"""
import argparse
import os
import sys

from PIL import Image

SOURCE_SIZE = (2000, 1125)

CROPS = {
    "chat-window.png": (543, 292, 1422, 900),
    "tracker.png": (1735, 830, 2000, 1028),
    "minimap.png": (1780, 40, 1985, 245),
}

# Source-image boxes (left, top, right, bottom) and mosaic block size in pixels.
ALWAYS_MASK = [
    ("chat path line", (630, 432, 1208, 456), 8),
]
TITLE_MASK = [
    # Text of row 7 ends at y=942 and row 12 starts at y=1001, so this box holds rows 8..11 only.
    ("tracker 'Pro:' titles, rows 8..11", (1767, 945, 1960, 998), 7),
]

MAX_BYTES = 400 * 1024


def pixelate(img, box, block):
    """Replace box with a mosaic: each block x block cell becomes its average colour."""
    l, t, r, b = box
    region = img.crop(box)
    w, h = region.size
    small = region.resize((max(1, -(-w // block)), max(1, -(-h // block))), Image.BOX)
    mosaic = small.resize((small.width * block, small.height * block), Image.NEAREST).crop((0, 0, w, h))
    img.paste(mosaic, (l, t))


def save_small(img, path):
    img.save(path, optimize=True)
    if os.path.getsize(path) > MAX_BYTES:
        img.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(path, optimize=True)
    return os.path.getsize(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True, help="full 2000x1125 in-game screenshot (PNG)")
    ap.add_argument("--out", required=True, help="output folder (e.g. docs/img)")
    ap.add_argument("--mask-titles", action="store_true", help="pixelate tracker titles except the first row")
    a = ap.parse_args()

    img = Image.open(a.source).convert("RGB")
    if img.size != SOURCE_SIZE:
        sys.exit(f"expected a {SOURCE_SIZE[0]}x{SOURCE_SIZE[1]} screenshot, got {img.size[0]}x{img.size[1]}; update the boxes")

    masks = ALWAYS_MASK + (TITLE_MASK if a.mask_titles else [])
    for name, box, block in masks:
        pixelate(img, box, block)
        print(f"masked {name}: {box}, {block} px blocks")

    os.makedirs(a.out, exist_ok=True)
    for name, box in CROPS.items():
        path = os.path.join(a.out, name)
        size = save_small(img.crop(box), path)
        print(f"wrote {path} ({box[2] - box[0]}x{box[3] - box[1]}, {size // 1024} KB)")


if __name__ == "__main__":
    main()

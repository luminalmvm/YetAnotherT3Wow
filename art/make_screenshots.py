#!/usr/bin/env python3
"""Crop and mask the README screenshots from full in-game screenshots.

The full screenshots are NOT part of the repo (they show the rest of the game UI, including other
players' names). This script documents exactly which regions are published and which are masked,
so the images can be re-made from new screenshots.

    python art/make_screenshots.py --source <full 2000x1125 screenshot.png> --out docs/img --mask-titles
    python art/make_screenshots.py --images-source <full 2559x1439 screenshot.png> --out docs/img

Crops (coordinates in the 2000x1125 source):
    chat-window.png  the T3 Code chat window          (543, 292) - (1422, 900)
    tracker.png      the T3 Code tracker block         (1735, 830) - (2000, 1028)
    minimap.png      the minimap with the T3 button    (1780, 40) - (1985, 245)

Masks (pixelated with large blocks so the text cannot be read at any zoom):
    always           the file path in the chat window's "Tool" line (it contains a local user name)
    --mask-titles    every tracker title except the first row (rows 2 to 14); the header
                     ("T3 Code  1 running"), the first row, status icons, collapse buttons and
                     timers stay visible

images.png (from --images-source, a 2559x1439 screenshot of the chat window with a staged image chip
next to the image viewer showing a snip of the chat window):
    crop             (240, 205) - (2291, 1135): the chat window and the viewer; leaves out the chat log
                     (bottom left), the unit frames at the screen edge and the tracker column right
                     of the viewer
    masks            every name in the game world (nameplates, also faint ones seen through the
                     translucent chat window), the player's own name behind the chat window, the
                     edge of the Questie tracker, and inside the nested snip: nameplates, party
                     frame names, the player name behind the input box and the GitHub repo path
                     in the last chat line (see IMAGES_MASK)
    output           downscaled to 1600 px wide, quantized so it stays under 600 KB

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
    # Row 1's text ends at y=863 and row 2 starts at y=868; the last row ends at y=1022. Titles start
    # at x=1768 (status icons end before 1767) and the longest title's "..." ends before x=1961,
    # while the timers start at x=1967.
    ("tracker titles, rows 2..14", (1767, 865, 1961, 1026), 7),
]

MAX_BYTES = 400 * 1024

IMAGES_SOURCE_SIZE = (2559, 1439)
IMAGES_CROP = (240, 205, 2291, 1135)
IMAGES_WIDTH = 1600
IMAGES_MAX_BYTES = 600 * 1024
# Source-image boxes (left, top, right, bottom) in the 2559x1439 screenshot, and mosaic block size.
# Several names are faint: they are nameplates behind the translucent chat window, readable once the
# contrast is raised, so they are masked too.
IMAGES_MASK = [
    # game world, outside the windows
    ("NPC nameplate behind the chat header (faint)", (1095, 256, 1195, 290), 10),
    ("NPC guild line under the thread dropdown (faint)", (504, 281, 594, 295), 7),
    ("NPC name between the dropdowns (faint)", (563, 268, 578, 281), 5),
    ("NPC nameplate 'Watchmaster ...'", (2160, 288, 2275, 312), 10),
    ("Questie tracker header, zone and quest icons", (2210, 340, 2291, 455), 10),
    ("NPC nameplate above the viewer title bar", (1538, 434, 1646, 458), 10),
    ("player nameplate with guild", (1925, 410, 2045, 454), 10),
    ("player nameplate behind the chat window (faint)", (688, 809, 908, 836), 10),
    ("own player name in the unit frame behind the chat window (faint)", (688, 924, 822, 955), 10),
    # inside the nested snip shown in the viewer (it is about 0.65x the outer UI scale)
    ("nested: NPC nameplate with guild", (1474, 528, 1558, 554), 7),
    ("nested: NPC nameplate above the health bar", (1998, 482, 2136, 513), 7),
    ("nested: faint NPC nameplate in the chat header", (1972, 594, 2052, 622), 7),
    ("nested: party frames and a player nameplate", (1350, 762, 1430, 932), 8),
    ("nested: GitHub repo path in the last chat line", (1492, 972, 1642, 991), 6),
    ("nested: player name and a nameplate behind the input box (faint)", (1428, 993, 1656, 1047), 8),
]


def pixelate(img, box, block):
    """Replace box with a mosaic: each block x block cell becomes its average colour."""
    l, t, r, b = box
    region = img.crop(box)
    w, h = region.size
    small = region.resize((max(1, -(-w // block)), max(1, -(-h // block))), Image.BOX)
    mosaic = small.resize((small.width * block, small.height * block), Image.NEAREST).crop((0, 0, w, h))
    img.paste(mosaic, (l, t))


def make_images(source, out):
    img = Image.open(source).convert("RGB")
    if img.size != IMAGES_SOURCE_SIZE:
        sys.exit(f"expected a {IMAGES_SOURCE_SIZE[0]}x{IMAGES_SOURCE_SIZE[1]} screenshot, got "
                 f"{img.size[0]}x{img.size[1]}; update IMAGES_CROP and IMAGES_MASK")
    for name, box, block in IMAGES_MASK:
        pixelate(img, box, block)
        print(f"masked {name}: {box}, {block} px blocks")
    img = img.crop(IMAGES_CROP)
    img = img.resize((IMAGES_WIDTH, round(img.height * IMAGES_WIDTH / img.width)), Image.LANCZOS)
    path = os.path.join(out, "images.png")
    img.save(path, optimize=True)
    for colors in (256, 192, 128):
        if os.path.getsize(path) <= IMAGES_MAX_BYTES:
            break
        img.quantize(colors=colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(path, optimize=True)
    size = os.path.getsize(path)
    print(f"wrote {path} ({img.width}x{img.height}, {size // 1024} KB)")
    if size > IMAGES_MAX_BYTES:
        sys.exit(f"{path} is larger than {IMAGES_MAX_BYTES // 1024} KB")


def save_small(img, path):
    img.save(path, optimize=True)
    if os.path.getsize(path) > MAX_BYTES:
        img.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(path, optimize=True)
    return os.path.getsize(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", help="full 2000x1125 in-game screenshot (PNG) for the three UI crops")
    ap.add_argument("--images-source", help="full 2559x1439 screenshot (PNG) for images.png")
    ap.add_argument("--out", required=True, help="output folder (e.g. docs/img)")
    ap.add_argument("--mask-titles", action="store_true", help="pixelate tracker titles except the first row")
    a = ap.parse_args()
    if not a.source and not a.images_source:
        ap.error("give --source, --images-source or both")

    os.makedirs(a.out, exist_ok=True)
    if a.images_source:
        make_images(a.images_source, a.out)
    if not a.source:
        return

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

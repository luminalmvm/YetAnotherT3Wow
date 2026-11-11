# T3Bridge icon art

The addon icon is original, procedurally painted artwork. It uses no game files
and no external images or fonts. Everything comes from seeded noise and vector
shapes defined in this folder.

## Files

| Path | What |
| --- | --- |
| `generate_icon.py` | Generator: three concepts, TGA writer and reader, previews |
| `paint.py` | Painting toolkit (noise, SDF bevels, lighting, Kuwahara paint filter) |
| `source/icon-512.png` | Working master of the shipped concept (8x supersampled) |
| `source/icon-128.png`, `source/icon-128.tga` | 128x128 source |
| `previews/concepts-overview.png` | All concepts side by side at 128, 64 and 20 px, with mock-ups |
| `previews/concept-*.png` | One sheet per concept (sizes, portrait mock, minimap mock) |
| `previews/mock-portrait.png`, `previews/mock-minimap.png` | Mock-ups of the shipped icon |
| `previews/shipped-icon-readback-*.png` | The shipped `icon.tga` decoded again, to check orientation |

## Concepts

- **crystal** (shipped): a gilded, rune-like "T3" over a faceted arcane-blue
  crystal. It has a faint arcane circle and sparkles on a painted indigo background.
- **tome**: a leather tome with gold corners and a round gold seal. A glowing
  "T3" sits in the seal.
- **runestone**: a chipped, mossy stone slab with a carved, glowing "T3".

The motif sits inside a centred circle about 80% of the icon's width. That way
the circle-masked portrait and minimap button lose only background.

## Regenerate

Needs Python 3.9 or newer, with `numpy`, `scipy` and `Pillow` installed
(`pip install numpy scipy pillow`).

```
python art/generate_icon.py                    # paint all concepts, ship "crystal"
python art/generate_icon.py --concept runestone  # ship another concept
python art/generate_icon.py --no-ship          # previews only
python art/generate_icon.py --no-ship --only tome
```

The output is the same on every run because the seeds are fixed. A full run
takes a few seconds.

## Shipped format

`addon/T3Bridge/Media/icon.tga` has this format:

- 64x64 pixels, 32-bit uncompressed true-colour TGA (image type 2).
- BGRA with 8 alpha bits, fully opaque.
- Bottom-left origin: descriptor byte `0x08`, with the top-left bit `0x20` clear.
- 18-byte header, no ID field, no footer, 16402 bytes in total.

This matches the layout of the original file. After writing the file, the
generator decodes it with its own reader, which follows the origin bit, and
with Pillow. It then checks that both results match the intended pixels byte
for byte.

## Where the game uses it

The addon loads the texture as `Interface\AddOns\T3Bridge\Media\icon`, without
the file extension:

- `T3Bridge.toc`: `## IconTexture:` (AddOn list and Addon Compartment).
- `UI/Minimap.lua`: a 20px icon, circle-masked, inside `MiniMap-TrackingBorder`.
- `UI/ChatFrame.lua`: the round portrait of `PortraitFrameTemplate`.

WoW caches textures. After you replace `icon.tga`, restart the game completely.
`/reload` is usually not enough.

## README screenshots

`make_screenshots.py` crops the images in `docs/img/` from two full in-game screenshots, which are not
committed. From `--source` it makes the chat window, tracker and minimap crops; it always pixelates the
local file path in the chat window, and with `--mask-titles` it also pixelates selected tracker titles.
From `--images-source` it makes `images.png` (chat window and image viewer), pixelating every name in
the game world, including faint ones behind the translucent chat window, and the names and repo path
inside the nested snip. The script lists every crop and mask box.

```
python art/make_screenshots.py --source <full 2000x1125 screenshot.png> --out docs/img --mask-titles
python art/make_screenshots.py --images-source <full 2559x1439 screenshot.png> --out docs/img
```

`docs/img/icon.png` is a copy of `source/icon-128.png`.

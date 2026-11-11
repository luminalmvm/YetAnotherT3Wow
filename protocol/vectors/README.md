# Outbound test vectors

One JSON file per case (PROTOCOL.md section 3). They were produced by the addon's Lua encoder
(`python addon/T3Bridge/test/run_tests.py --write-vectors`) and cross-checked by a separate
JavaScript implementation (`node scripts/dev/gen-vectors.js --check --png`, 13/13 match).

| Field | Meaning |
|---|---|
| `sid_hex`, `seq`, `flags` | Frame header values (sid = addon session, 4 bytes) |
| `cell`, `rows` | Cell size in physical pixels and matrix rows (8 or 32) |
| `message_utf8` / `message_hex` / `message_len` | Whole command payload before splitting |
| `parts[]` | One entry per frame: `part`, `parts`, `len`, `payload_hex`, `frame_hex`, `crc32_hex`, `cells` |
| `cells` | `rows` strings of 256 `0`/`1` characters. Row 0 is the sync row `1010…` |

`<name>.p<part>.png` shows each frame drawn exactly as the addon draws it: matrix at pixel (0,0),
`cell`×`cell` pixels per cell, white = 1, on a black backing, over a fake game-scene gradient.
Use these images to unit-test the companion decoder without WoW.

`/t3 spike s2` shows four of these in game (`hello_c1`, `focus_c2`, `intr_c4`, `boundary_207_c2`),
using the same sid/seq/payload, so a live capture can be compared byte for byte.

Cases: short commands at cell 1/2/4 (including `model` with the optional effort field, `model_effort_c2`), a retransmit (`flags=1`), UTF-8 text, free text with tab and
newline, the 206/207-byte boundary where frames switch from 8 to 32 rows, and a 4000-byte `send`
split into 5 parts with seq 65535.

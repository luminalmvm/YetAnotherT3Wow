# Development

Everything except the in-game checks runs without WoW and without T3 Code. Commands run from the repo root unless they say otherwise.

## Tests

| What | Command | Needs |
|---|---|---|
| Companion unit tests | `cd companion; npm install; npm run build; npx vitest run` | Node 22+ |
| Decoder self-test + all vectors | `node companion/dist/main.js --selftest` | built companion |
| Addon tests (Lua 5.1: compile, unit, whole addon against a WoW mock) | `python addon/T3Bridge/test/run_tests.py` | Python 3, `pip install lupa` |
| Addon encoder vs companion vectors | `python scripts/dev/crosscheck-lua-vectors.py` | `lupa` |
| Second, independent encoder vs `protocol/vectors` | `node scripts/dev/gen-vectors.js --check` | Node |
| Capture helper and test window | `dotnet build -c Release capture-helper/T3Capture` and `capture-helper/T3TestWindow` | .NET SDK 7+ |
| Installer dry run | `scripts/install-addon.ps1 -WowPath <folder> -WhatIf` | PowerShell 5.1+ |

`run_tests.py` loads every addon file under real Lua 5.1 (lupa's `lua51`), so Lua 5.2+ syntax fails here exactly as it would in game. The smoke suite runs the whole addon twice against `test/wow_mock.lua` ("modern" and "legacy" client APIs) and decodes the matrix it draws.

## End-to-end without WoW

- `node companion/dist/main.js --demo --no-capture --out <some folder>\live.lua` writes realistic snapshots from fake T3 data into any file.
- `node companion/dist/testing/e2eCapture.js --cell 2 --hold-ms 200` drives `T3TestWindow` (a D3D11 flip-model window that draws matrix frames) and decodes them through the real capture helper.
- `bash scripts/dev/run-e2e-matrix.sh 200 120 run` runs that over cell sizes 1/2/4 and scale factors 1/1.25/1.5 and writes JSON to `companion/test-results/` (git-ignored).
- `node companion/dist/testing/e2eLoop.js --cell 2` runs the full loop against a real T3 server: it creates a throwaway thread, sends to it through the pixel path and deletes it afterwards.

## In game

- `scripts/sync-addon.ps1` copies changed addon files into the installed addon (it refuses new files and TOC changes while WoW runs, because the client only lists files at start-up), then `/reload`.
- `scripts/dev/set-live-file.ps1 -Loop` stands in for the companion with the reference fixture; `-Spike -Loop` feeds `/t3 spike s1`.
- `/t3 spike s2` flashes four reference frames (also in `protocol/vectors`) for 3 s each, so a live capture can be compared byte for byte.
- `/t3 spike img` + `scripts/spike-image-slots.ps1` check image slots on the real client (new content before first load, caching, `/reload`, new files, orientation, load time).
- Image tools without WoW: `T3Capture.exe decode --in <img> --max 512 --out <raw>` (also `clipboard`, `convert`, `procinfo`, `version`; see [capture-helper/README.md](../capture-helper/README.md)).
- `/t3 debug` and `/t3 log` show the addon's debug lines; the companion logs to `%LOCALAPPDATA%\T3Bridge\companion.log` (`--log-level debug` for more).

## Regenerating generated files

| File | Command |
|---|---|
| `protocol/fixtures/live.sample.lua`, `addon/T3Bridge/Demo.lua` | `node scripts/dev/make-fixture.js` |
| `protocol/vectors/*.json` | `python addon/T3Bridge/test/run_tests.py --write-vectors` |
| `protocol/vectors/*.png` | `node scripts/dev/gen-vectors.js --check --png` |
| `companion/test/vectors/*.json` | `cd companion; UPDATE_VECTORS=1 npx vitest run test/vectors.test.ts` |
| `addon/T3Bridge/Media/icon.tga` | `python art/generate_icon.py` (needs `numpy scipy pillow`, see [art/README.md](../art/README.md)) |
| `docs/img/*.png` | `python art/make_screenshots.py --source <full screenshot> --images-source <images screenshot> --out docs/img --mask-titles` |

## Notes for changes

- Keep the protocol backward compatible where possible and record changes in the change list at the top of [PROTOCOL.md](../protocol/PROTOCOL.md).
- The addon must never create files at run time or rely on files created after login. The companion never creates image slot files either; it only overwrites them in place.
- Fixtures under `docs/fixtures` are redacted captures of real server responses with fake ids and shifted timestamps. Never add real ids, titles, paths or tokens.

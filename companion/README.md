# T3Bridge companion

Bridges T3 Code to the T3Bridge WoW addon:
- **Inbound:** writes `<AddOns>\T3Bridge_Live\live.lua` in place (PROTOCOL.md §2) from live T3 state (WebSocket).
- **Outbound:** decodes the addon's pixel matrix from a read-only live window capture (`capture-helper/T3Capture`),
  then runs the commands against T3 (send, model, stop, answer). A screenshot-folder watcher is the fallback.

Day to day (from the repo root):
```
powershell -ExecutionPolicy Bypass -File scripts\start-bridge.ps1            # hidden, single instance
powershell -ExecutionPolicy Bypass -File scripts\start-bridge.ps1 -Console   # visible log window
powershell -ExecutionPolicy Bypass -File scripts\stop-bridge.ps1             # clean stop, clears live.lua
```

From this folder:
```
npm install && npm run build
node dist/main.js --status        # discovery, credential, paths (no writes)
node dist/main.js --login         # scoped T3 bearer (orchestration:read+operate), DPAPI-stored
node dist/main.js --pair          # alternative: paste a one-time pairing token on stdin
node dist/main.js                 # run the bridge
node dist/main.js --clear         # overwrite live.lua/Inbox.lua with an empty snapshot
node dist/main.js --demo          # fake T3 data; reacts to addon commands (writes the real live.lua if it exists)
node dist/main.js --demo --no-capture --out <folder>\live.lua   # demo into any file
node dist/main.js --selftest      # decoder self-test + test vectors
npx vitest run                    # unit tests
```
Options: `--capture wgc|screenshot|off`, `--log-level debug`, `--config <file>`.

Config: `%LOCALAPPDATA%\T3Bridge\config.json`, merged over the defaults in `src/config.ts`. The WoW folder
(`wowRoot`, the folder that holds `Interface\AddOns`) defaults to `$T3B_WOW_PATH`, then the first
`World of Warcraft\_forever_` found in common folders; `scripts\install-companion.ps1 -WowPath …` pins it.
The capture helper is found via `capture.helperPath`, `$T3B_CAPTURE_HELPER`, `%LOCALAPPDATA%\T3Bridge\capture\`,
or the Release build inside this repo. Log: `%LOCALAPPDATA%\T3Bridge\companion.log` (rotates at 2 MB; no tokens, no message text).

Docs: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md), [`../docs/t3-api-notes.md`](../docs/t3-api-notes.md) (T3 API),
[`../docs/companion-protocol-notes.md`](../docs/companion-protocol-notes.md) (protocol details),
[`../docs/dev-notes/PHASE0-REPORT-A.md`](../docs/dev-notes/PHASE0-REPORT-A.md) (measurements).

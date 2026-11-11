# capture-helper

## T3Capture (production)
A .NET console app (`net7.0-windows10.0.22621.0`; builds with the .NET SDK 7 or newer). It uses **Windows.Graphics.Capture** for read-only
capture of the WoW window (the same API class OBS uses). It never injects input and never reads process memory.

- Finds the window of `Wow.exe` (or `--process`, `--hwnd`, `--title`) and re-attaches when the window goes away.
- Crops the **client-area** origin (removes title bar and border), then copies only the top-left region
  (`--region 1100x200`) from GPU to CPU and converts it to luma.
- Pre-detects the T3Bridge sync row. Only crops that contain a matrix go to stdout, and identical crops are skipped.
- Adaptive rate: `--idle-fps 10`, and `--active-fps 30` for `--active-hold-ms 3000` after a sync row was seen.
- Cursor capture is off. The yellow capture border is off where the OS allows it.
- stdout: binary records (`"T3CF"` header + luma; see `Program.cs` / `companion/src/wow/captureClient.ts`).
  stderr: JSON status lines (`attached`, `stats` with fps, CPU and readback ms, `error`).
- Exits when its stdin closes (parent died). `--keep-alive` disables that for manual runs.

```
dotnet build -c Release T3Capture
T3Capture\bin\Release\net7.0-windows10.0.22621.0\T3Capture.exe --list                       # windows
T3Capture\bin\Release\net7.0-windows10.0.22621.0\T3Capture.exe --process Wow --keep-alive    # stats on stderr
```

## T3TestWindow (test only)
A synthetic WoW stand-in for end-to-end tests without the game. It renders through a D3D11 flip-model swapchain
(`--renderer d3d`, the default; `gdi` is also available) and draws matrix frames from a JSON file made by
the companion's reference encoder. It logs show/hide timestamps. The companion's
`dist/testing/e2eCapture.js` and `dist/testing/e2eLoop.js` drive it.
Options: `--cell`, `--scale` (non-integer cell pitch), `--dpi unaware`, `--hold-ms`, `--gap-ms`, `--repeat`, `--topmost 1`.

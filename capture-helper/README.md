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

### One-shot image tools (images in chat, PROTOCOL rev 1.3)
`T3Capture <tool> ...` runs one tool, prints one JSON line on stdout and exits (see `Tools.cs`). The companion
starts them on demand; none of them captures the screen or touches the game.

| Tool | What it does | Exit codes |
|---|---|---|
| `version` | `{"version":2,"tools":[...]}` (the companion uses it to skip an older helper build) | 0 |
| `clipboard --out <file.png>` | Reads the Windows clipboard (Win32, read-only): the `PNG` format, a copied image file, `CF_DIB`, `CF_DIBV5`; writes a PNG | 0 image, 2 no image, 1 error |
| `decode --in <file> --max 512 --out <raw>` | Decodes with Windows Imaging Component (PNG, JPEG, GIF first frame, BMP, TIFF, WebP/HEIF with the Windows codecs), applies EXIF orientation, fits into max x max (never upscales, Fant scaling), writes raw RGBA | 0 / 1 |
| `convert --in <file> --out <file.jpg> [--max-edge 4096] [--quality 90]` | Re-encodes as JPEG (uploads over T3's 10 MiB limit, formats T3 does not accept) | 0 / 1 |
| `procinfo --process Wow` | `[{"pid","startMs"}]`: tells the companion when WoW was restarted (which frees the image slots) | 0 |

## T3TestWindow (test only)
A synthetic WoW stand-in for end-to-end tests without the game. It renders through a D3D11 flip-model swapchain
(`--renderer d3d`, the default; `gdi` is also available) and draws matrix frames from a JSON file made by
the companion's reference encoder. It logs show/hide timestamps. The companion's
`dist/testing/e2eCapture.js` and `dist/testing/e2eLoop.js` drive it.
Options: `--cell`, `--scale` (non-integer cell pitch), `--dpi unaware`, `--hold-ms`, `--gap-ms`, `--repeat`, `--topmost 1`.

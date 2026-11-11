// T3Capture: read-only Windows.Graphics.Capture of the WoW window's top-left region.
// `T3Capture version|clipboard|decode|convert|procinfo` run one-shot image tools instead (Tools.cs).
// Streams luminance crops that contain the T3Bridge sync row to stdout (binary records);
// status and stats go to stderr as JSON lines. Never injects input, never reads process memory.
//
// Record (little endian):
//   magic "T3CF"(4) ver=1(1) kind=1(1) width(2) height(2) cropX(2) cropY(2) seq(4)
//   frameUnixUs(8: when DWM produced the frame) readyUnixUs(8: when the crop was ready) syncPitchMilli(4) = 38 bytes,
//   followed by width*height luma bytes (row-major). cropX/cropY are relative to the captured surface.
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;

namespace T3Capture;

internal sealed class Options
{
    public List<string> ProcessNames = new() { "Wow", "WowClassic", "WowT", "WowB" };
    public IntPtr Hwnd = IntPtr.Zero;
    public string? TitleContains;
    public int RegionW = 1100, RegionH = 200;
    public string Origin = "client"; // client | window
    public double IdleFps = 10, ActiveFps = 30;
    public int ActiveHoldMs = 3000;
    public int SearchX = 96, SearchY = 200;
    public bool EmitAll = false;    // emit every processed frame (diagnostics), not only sync-bearing ones
    public bool NoDedupe = false;
    public int StatsMs = 5000;
    public bool List = false;
    public int ExitAfterMs = 0;
    public bool WatchStdin = true;
    public bool KeepBorder = false;
    public bool Monitor = false;

    public static Options Parse(string[] a)
    {
        var o = new Options();
        for (int i = 0; i < a.Length; i++)
        {
            string Next() => i + 1 < a.Length ? a[++i] : throw new ArgumentException($"missing value for {a[i]}");
            switch (a[i])
            {
                case "--process": o.ProcessNames = Next().Split(',', StringSplitOptions.RemoveEmptyEntries).Select(s => s.Replace(".exe", "", StringComparison.OrdinalIgnoreCase)).ToList(); break;
                case "--hwnd": { var v = Next(); o.Hwnd = new IntPtr(v.StartsWith("0x") ? Convert.ToInt64(v[2..], 16) : long.Parse(v)); break; }
                case "--title": o.TitleContains = Next(); break;
                case "--region": { var p = Next().Split('x'); o.RegionW = int.Parse(p[0]); o.RegionH = int.Parse(p[1]); break; }
                case "--origin": o.Origin = Next(); break;
                case "--idle-fps": o.IdleFps = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--active-fps": o.ActiveFps = double.Parse(Next(), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--active-hold-ms": o.ActiveHoldMs = int.Parse(Next()); break;
                case "--search": { var p = Next().Split('x'); o.SearchX = int.Parse(p[0]); o.SearchY = int.Parse(p[1]); break; }
                case "--emit-all": o.EmitAll = true; break;
                case "--no-dedupe": o.NoDedupe = true; break;
                case "--stats-ms": o.StatsMs = int.Parse(Next()); break;
                case "--list": o.List = true; break;
                case "--exit-after-ms": o.ExitAfterMs = int.Parse(Next()); break;
                case "--keep-alive": o.WatchStdin = false; break;
                case "--keep-border": o.KeepBorder = true; break;
                case "--monitor": o.Monitor = true; break;
                case "--help": case "-h":
                    Console.Error.WriteLine("T3Capture [--process Wow,WowClassic] [--hwnd 0x..] [--title text] [--region 1100x200] [--origin client|window] [--idle-fps 10] [--active-fps 30] [--active-hold-ms 3000] [--search 96x200] [--emit-all] [--no-dedupe] [--list]");
                    Environment.Exit(0); break;
                default: throw new ArgumentException($"unknown option {a[i]}");
            }
        }
        return o;
    }
}

internal static class Program
{
    static readonly object OutLock = new();
    static Stream Stdout = null!;

    public static void Status(object o)
    {
        var s = JsonSerializer.Serialize(o);
        lock (OutLock) { Console.Error.WriteLine(s); Console.Error.Flush(); }
    }

    public static void WriteRecord(ReadOnlySpan<byte> header, ReadOnlySpan<byte> body)
    {
        lock (OutLock) { Stdout.Write(header); Stdout.Write(body); Stdout.Flush(); }
    }

    static int Main(string[] args)
    {
        // One-shot image/clipboard tools (Tools.cs) for the companion's image support.
        if (Tools.IsTool(args)) return Tools.Run(args);
        Native.SetProcessDpiAwarenessContext(Native.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        Options opt;
        try { opt = Options.Parse(args); } catch (Exception e) { Console.Error.WriteLine(e.Message); return 2; }
        Stdout = Console.OpenStandardOutput();
        if (opt.List)
        {
            foreach (var w in WindowFinder.All()) Status(new { ev = "window", hwnd = $"0x{w.Hwnd.ToInt64():X}", w.Pid, w.Process, w.Title, w.Class, w.ClientW, w.ClientH });
            return 0;
        }
        if (!GraphicsCaptureSession.IsSupported()) { Status(new { ev = "error", message = "Windows.Graphics.Capture is not supported on this system" }); return 3; }

        // Exit when the parent closes our stdin (companion died).
        var stdinThread = new Thread(() => { try { var s = Console.OpenStandardInput(); var b = new byte[64]; while (s.Read(b, 0, b.Length) > 0) { } } catch { } Environment.Exit(0); }) { IsBackground = true };
        if (opt.WatchStdin) stdinThread.Start();
        if (opt.ExitAfterMs > 0) new Timer(_ => Environment.Exit(0), null, opt.ExitAfterMs, Timeout.Infinite);

        Status(new { ev = "start", version = 1, opt.RegionW, opt.RegionH, opt.IdleFps, opt.ActiveFps, processes = opt.ProcessNames });
        using var cap = new Capturer(opt);
        cap.Run();
        return 0;
    }
}

internal sealed record WindowInfo(IntPtr Hwnd, uint Pid, string Process, string Title, string Class, int ClientW, int ClientH);

internal static class WindowFinder
{
    public static List<WindowInfo> All()
    {
        var list = new List<WindowInfo>();
        Native.EnumWindows((h, _) =>
        {
            if (!Native.IsWindowVisible(h)) return true;
            if (Native.GetWindow(h, 4 /* GW_OWNER */) != IntPtr.Zero) return true;
            Native.GetWindowThreadProcessId(h, out var pid);
            string pname = "";
            try { pname = Process.GetProcessById((int)pid).ProcessName; } catch { }
            Native.GetClientRect(h, out var rc);
            if (rc.Width <= 0 || rc.Height <= 0) return true;
            list.Add(new WindowInfo(h, pid, pname, Native.WindowText(h), Native.ClassName(h), rc.Width, rc.Height));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static WindowInfo? Find(Options o)
    {
        var all = All();
        if (o.Hwnd != IntPtr.Zero) return all.FirstOrDefault(w => w.Hwnd == o.Hwnd);
        IEnumerable<WindowInfo> c = all;
        if (o.TitleContains != null) c = c.Where(w => w.Title.Contains(o.TitleContains, StringComparison.OrdinalIgnoreCase));
        else c = c.Where(w => o.ProcessNames.Any(n => string.Equals(n, w.Process, StringComparison.OrdinalIgnoreCase)));
        return c.OrderByDescending(w => (long)w.ClientW * w.ClientH).FirstOrDefault();
    }
}

internal sealed class Capturer : IDisposable
{
    readonly Options _o;
    readonly IntPtr _device, _ctx;
    readonly Windows.Graphics.DirectX.Direct3D11.IDirect3DDevice _winrtDevice;
    readonly object _lock = new();
    GraphicsCaptureItem? _item;
    Direct3D11CaptureFramePool? _pool;
    GraphicsCaptureSession? _session;
    IntPtr _hwnd;
    IntPtr _staging; uint _stW, _stH;
    Windows.Graphics.SizeInt32 _lastSize;
    int _originX, _originY;
    long _lastProcessedTicks;
    long _lastSyncTicks = long.MinValue / 2;
    ulong _lastHash; long _lastEmitTicks;
    uint _seq;
    byte[] _luma = Array.Empty<byte>();
    readonly long _qpcToUnixOffsetUs;
    volatile bool _closed;
    // stats
    long _arrived, _processed, _emitted, _deduped, _syncFrames;
    double _readbackMsSum;

    public Capturer(Options o)
    {
        _o = o;
        (_device, _ctx, _winrtDevice) = Native.CreateDevice();
        long unixUs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1000 + (DateTime.UtcNow.Ticks % 10000) / 10;
        _qpcToUnixOffsetUs = unixUs - QpcToUs(Stopwatch.GetTimestamp());
    }

    static long QpcToUs(long qpc) => (long)(qpc * (1_000_000.0 / Stopwatch.Frequency));
    static long UnixUsNow() => (DateTime.UtcNow.Ticks - DateTime.UnixEpoch.Ticks) / 10;

    public void Run()
    {
        var statsSw = Stopwatch.StartNew();
        var proc = Process.GetCurrentProcess();
        var lastCpu = proc.TotalProcessorTime;
        long lastStats = 0;
        while (true)
        {
            if (_session == null || _closed || !Native.IsWindow(_hwnd))
            {
                Stop();
                var w = WindowFinder.Find(_o);
                if (w != null)
                {
                    try { Start(w); }
                    catch (Exception e) { Program.Status(new { ev = "error", message = $"attach failed: {e.Message}" }); Stop(); }
                }
            }
            Thread.Sleep(500);
            if (statsSw.ElapsedMilliseconds - lastStats >= _o.StatsMs)
            {
                proc.Refresh();
                var cpu = proc.TotalProcessorTime;
                double secs = (statsSw.ElapsedMilliseconds - lastStats) / 1000.0;
                lastStats = statsSw.ElapsedMilliseconds;
                long arrived, processed, emitted, deduped, sync; double rb;
                lock (_lock) { arrived = _arrived; processed = _processed; emitted = _emitted; deduped = _deduped; sync = _syncFrames; rb = _readbackMsSum; _arrived = _processed = _emitted = _deduped = _syncFrames = 0; _readbackMsSum = 0; }
                Program.Status(new
                {
                    ev = "stats", attached = _session != null, hwnd = $"0x{_hwnd.ToInt64():X}",
                    arrivedFps = Math.Round(arrived / secs, 1), processedFps = Math.Round(processed / secs, 1),
                    emitted, deduped, syncFrames = sync,
                    avgReadbackMs = processed > 0 ? Math.Round(rb / processed, 3) : 0,
                    cpuPct = Math.Round((cpu - lastCpu).TotalMilliseconds / (secs * 1000) * 100 / Environment.ProcessorCount, 2),
                    cpuPctOneCore = Math.Round((cpu - lastCpu).TotalMilliseconds / (secs * 1000) * 100, 2),
                    workingSetMB = Math.Round(proc.WorkingSet64 / 1048576.0, 1),
                });
                lastCpu = cpu;
            }
        }
    }

    void Start(WindowInfo w)
    {
        _hwnd = w.Hwnd;
        _closed = false;
        _item = _o.Monitor ? Native.CreateItemForMonitorOf(w.Hwnd) : Native.CreateItemForWindow(w.Hwnd);
        _item.Closed += (_, _) => { _closed = true; Program.Status(new { ev = "detached", reason = "item closed" }); };
        _lastSize = _item.Size;
        _pool = Direct3D11CaptureFramePool.CreateFreeThreaded(_winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, _lastSize);
        _pool.FrameArrived += OnFrameArrived;
        _session = _pool.CreateCaptureSession(_item);
        try { _session.IsCursorCaptureEnabled = false; } catch { }
        bool borderOff = false;
        try
        {
            if (!_o.KeepBorder && Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired"))
            {
                try { GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless).AsTask().Wait(2000); } catch { }
                _session.IsBorderRequired = false;
                borderOff = true;
            }
        }
        catch (Exception e) { Program.Status(new { ev = "warn", message = $"could not disable capture border: {e.Message}" }); }
        ComputeOrigin();
        _session.StartCapture();
        Program.Status(new { ev = "attached", hwnd = $"0x{w.Hwnd.ToInt64():X}", w.Pid, w.Process, w.Title, w.Class, w.ClientW, w.ClientH, itemW = _lastSize.Width, itemH = _lastSize.Height, originX = _originX, originY = _originY, borderOff, dpi = Native.GetDpiForWindow(w.Hwnd) });
    }

    void ComputeOrigin()
    {
        _originX = _originY = 0;
        if (_o.Origin != "client") return;
        if (Native.DwmGetWindowAttribute(_hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out var frame, Marshal.SizeOf<RECT>()) != 0) return;
        var p = new POINT();
        if (!Native.ClientToScreen(_hwnd, ref p)) return;
        _originX = Math.Max(0, p.X - frame.Left);
        _originY = Math.Max(0, p.Y - frame.Top);
    }

    void OnFrameArrived(Direct3D11CaptureFramePool sender, object _)
    {
        // Drain the pool and keep only the newest frame: TryGetNextFrame returns the OLDEST queued frame,
        // so taking one per event can leave us permanently one frame behind.
        Direct3D11CaptureFrame? frame = null;
        int drained = 0;
        for (var f = sender.TryGetNextFrame(); f != null; f = sender.TryGetNextFrame()) { frame?.Dispose(); frame = f; drained++; }
        if (frame == null) return;
        using var _frame = frame;
        long now = Stopwatch.GetTimestamp();
        lock (_lock)
        {
            _arrived += drained;
            var size = frame.ContentSize;
            if (size.Width != _lastSize.Width || size.Height != _lastSize.Height)
            {
                _lastSize = size;
                sender.Recreate(_winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
                ComputeOrigin();
                Program.Status(new { ev = "resized", w = size.Width, h = size.Height, originX = _originX, originY = _originY });
                return;
            }
            bool active = (now - _lastSyncTicks) < _o.ActiveHoldMs * Stopwatch.Frequency / 1000;
            double fps = active ? _o.ActiveFps : _o.IdleFps;
            long minTicks = (long)(Stopwatch.Frequency / fps * 0.9);
            if (now - _lastProcessedTicks < minTicks) return;
            _lastProcessedTicks = now;
            try { ProcessFrame(frame, size); }
            catch (Exception e) { Program.Status(new { ev = "error", message = $"frame: {e.Message}" }); }
        }
    }

    void ProcessFrame(Direct3D11CaptureFrame frame, Windows.Graphics.SizeInt32 size)
    {
        var t0 = Stopwatch.GetTimestamp();
        int x0 = Math.Min(_originX, Math.Max(0, size.Width - 1)), y0 = Math.Min(_originY, Math.Max(0, size.Height - 1));
        uint w = (uint)Math.Min(_o.RegionW, size.Width - x0), h = (uint)Math.Min(_o.RegionH, size.Height - y0);
        if (w == 0 || h == 0) return;
        if (_staging == IntPtr.Zero || _stW != w || _stH != h)
        {
            if (_staging != IntPtr.Zero) Marshal.Release(_staging);
            _staging = Native.CreateStagingTexture(_device, w, h);
            _stW = w; _stH = h;
            _luma = new byte[w * h];
        }
        // The surface RCW must be disposed promptly: an undisposed surface keeps the pool buffer busy and
        // WGC stops delivering frames until the GC finalizes it (observed: ~3 fps instead of 60).
        using (var surface = frame.Surface)
        {
            var tex = Native.TextureFromSurface(surface);
            try
            {
                Native.CopySubresourceRegion(_ctx, _staging, tex, new D3D11_BOX { Left = (uint)x0, Top = (uint)y0, Front = 0, Right = (uint)x0 + w, Bottom = (uint)y0 + h, Back = 1 });
            }
            finally { Marshal.Release(tex); }
        }
        var map = Native.Map(_ctx, _staging);
        try
        {
            unsafe
            {
                byte* src = (byte*)map.pData;
                fixed (byte* dst0 = _luma)
                {
                    for (int y = 0; y < h; y++)
                    {
                        byte* s = src + y * map.RowPitch;
                        byte* d = dst0 + y * w;
                        for (int x = 0; x < w; x++, s += 4) d[x] = (byte)((s[0] * 19 + s[1] * 183 + s[2] * 54) >> 8);
                    }
                }
            }
        }
        finally { Native.Unmap(_ctx, _staging); }
        _processed++;
        _readbackMsSum += (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;

        var sync = SyncDetector.Find(_luma, (int)w, (int)h, _o.SearchX, _o.SearchY);
        if (sync.HasValue) { _syncFrames++; _lastSyncTicks = Stopwatch.GetTimestamp(); }
        if (!sync.HasValue && !_o.EmitAll) return;

        // Crop to the matrix (+margin) so the companion gets a small image.
        int cx = 0, cy = 0, cw = (int)w, ch = (int)h;
        if (sync.HasValue)
        {
            var s = sync.Value;
            cx = Math.Max(0, (int)Math.Floor(s.X0) - 4);
            cy = Math.Max(0, s.Y0 - 4);
            cw = Math.Min((int)w - cx, (int)Math.Ceiling(256 * s.Pitch) + 12);
            ch = Math.Min((int)h - cy, (int)Math.Ceiling(33 * s.Pitch) + 12);
        }
        var crop = new byte[cw * ch];
        for (int y = 0; y < ch; y++) Buffer.BlockCopy(_luma, (cy + y) * (int)w + cx, crop, y * cw, cw);
        ulong hash = 14695981039346656037UL;
        for (int i = 0; i < crop.Length; i++) { hash ^= (crop[i] >= 128 ? 1UL : 0UL) | ((ulong)(uint)(i & 0xff) << 8); hash *= 1099511628211UL; }
        long nowT = Stopwatch.GetTimestamp();
        if (!_o.NoDedupe && hash == _lastHash && nowT - _lastEmitTicks < 2 * Stopwatch.Frequency) { _deduped++; return; }
        _lastHash = hash; _lastEmitTicks = nowT;
        long frameUs = _qpcToUnixOffsetUs + (long)(frame.SystemRelativeTime.Ticks / 10.0);
        long readyUs = UnixUsNow();
        Span<byte> hdr = stackalloc byte[38];
        "T3CF"u8.CopyTo(hdr);
        hdr[4] = 1; hdr[5] = 1;
        BitConverter.TryWriteBytes(hdr[6..], (ushort)cw);
        BitConverter.TryWriteBytes(hdr[8..], (ushort)ch);
        BitConverter.TryWriteBytes(hdr[10..], (ushort)(cx + x0));
        BitConverter.TryWriteBytes(hdr[12..], (ushort)(cy + y0));
        BitConverter.TryWriteBytes(hdr[14..], ++_seq);
        BitConverter.TryWriteBytes(hdr[18..], frameUs);
        BitConverter.TryWriteBytes(hdr[26..], readyUs);
        BitConverter.TryWriteBytes(hdr[34..], (uint)Math.Round((sync?.Pitch ?? 0) * 1000));
        Program.WriteRecord(hdr, crop);
        _emitted++;
    }

    void Stop()
    {
        lock (_lock)
        {
            try { _session?.Dispose(); } catch { }
            try { if (_pool != null) { _pool.FrameArrived -= OnFrameArrived; _pool.Dispose(); } } catch { }
            _session = null; _pool = null; _item = null;
        }
    }

    public void Dispose()
    {
        Stop();
        if (_staging != IntPtr.Zero) Marshal.Release(_staging);
        Marshal.Release(_ctx);
        Marshal.Release(_device);
    }
}

/// Same rule as companion/src/wow/frameDecoder.ts: 255 alternating runs (cells 0..254) of consistent length.
internal static class SyncDetector
{
    public readonly record struct Sync(double X0, int Y0, double Pitch);

    public static Sync? Find(byte[] img, int w, int h, int maxX, int maxY)
    {
        var starts = new int[w + 2];
        for (int y = 0; y < Math.Min(h, maxY + 1); y++)
        {
            int row = y * w, n = 0, prev = -1;
            for (int x = 0; x < w; x++)
            {
                int c = img[row + x] >= 128 ? 1 : 0;
                if (c != prev) { starts[n++] = x; prev = c; }
            }
            starts[n] = w;
            int firstColor = img[row] >= 128 ? 1 : 0;
            for (int j = 0; j + 255 <= n && starts[j] <= maxX; j++)
            {
                int color = (j % 2 == 0) ? firstColor : 1 - firstColor;
                if (color != 1) continue;
                double p = (starts[j + 255] - starts[j + 1]) / 254.0;
                if (p < 0.75 || p > 12) continue;
                double lo = Math.Min(p * 0.5, Math.Floor(p)), hi = Math.Max(p * 1.5, Math.Ceiling(p)) + 0.01;
                if (starts[j + 1] - starts[j] < lo) continue;
                bool ok = true;
                for (int k = 1; k < 255; k++) { int len = starts[j + k + 1] - starts[j + k]; if (len < lo || len > hi) { ok = false; break; } }
                if (!ok) continue;
                if (j + 255 < n && starts[j + 256] - starts[j + 255] < lo) continue;
                return new Sync(Math.Max(starts[j], starts[j + 1] - p), y, p);
            }
        }
        return null;
    }
}

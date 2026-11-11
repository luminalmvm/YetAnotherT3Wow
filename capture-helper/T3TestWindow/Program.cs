// T3TestWindow: synthetic stand-in for the WoW client. Paints T3Bridge matrix frames (cells from a JSON
// file produced by the companion's reference encoder) at the top-left of its client area, holds each
// for N ms, hides it, and logs precise show/hide timestamps to stdout (JSON lines) for latency measurement.
//
// Usage: T3TestWindow --frames frames.json [--cell 2] [--scale 1.0] [--dpi permonitor|unaware]
//        [--size 1280x720] [--pos 40,40] [--background game|black|white] [--start-delay-ms 1500]
//        [--hold-ms 200] [--gap-ms 120] [--repeat 1] [--exit-delay-ms 1500]
using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace T3TestWindow;

internal sealed class FrameSpec
{
    public string Label { get; set; } = "";
    public int Rows { get; set; }
    public string[] Cells { get; set; } = Array.Empty<string>();
    public int? HoldMs { get; set; }
}

internal static class Program
{
    public static long UnixUs() => (DateTime.UtcNow.Ticks - DateTime.UnixEpoch.Ticks) / 10;
    static readonly object OutLock = new();
    public static void Log(object o) { lock (OutLock) { Console.Out.WriteLine(JsonSerializer.Serialize(o)); Console.Out.Flush(); } }

    [STAThread]
    static int Main(string[] args)
    {
        var a = new Dictionary<string, string>();
        for (int i = 0; i + 1 < args.Length; i += 2) a[args[i]] = args[i + 1];
        string dpi = a.GetValueOrDefault("--dpi", "permonitor");
        Application.SetHighDpiMode(dpi == "unaware" ? HighDpiMode.DpiUnaware : HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        var frames = JsonSerializer.Deserialize<List<FrameSpec>>(File.ReadAllText(a["--frames"]), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        var form = new MatrixForm(frames,
            cell: int.Parse(a.GetValueOrDefault("--cell", "2")),
            scale: double.Parse(a.GetValueOrDefault("--scale", "1.0"), System.Globalization.CultureInfo.InvariantCulture),
            size: a.GetValueOrDefault("--size", "1280x720"),
            pos: a.GetValueOrDefault("--pos", "40,40"),
            background: a.GetValueOrDefault("--background", "game"),
            startDelayMs: int.Parse(a.GetValueOrDefault("--start-delay-ms", "1500")),
            holdMs: int.Parse(a.GetValueOrDefault("--hold-ms", "200")),
            gapMs: int.Parse(a.GetValueOrDefault("--gap-ms", "120")),
            repeat: int.Parse(a.GetValueOrDefault("--repeat", "1")),
            exitDelayMs: int.Parse(a.GetValueOrDefault("--exit-delay-ms", "1500")),
            dpiMode: dpi,
            animateFps: int.Parse(a.GetValueOrDefault("--animate-fps", "0")));
        form.TopMost = a.GetValueOrDefault("--topmost", "0") == "1";
        form.Renderer = a.GetValueOrDefault("--renderer", "d3d");
        Application.Run(form);
        return 0;
    }
}

internal sealed class MatrixForm : Form
{
    readonly List<FrameSpec> _frames;
    readonly int _cell; readonly double _scale; readonly string _bg;
    readonly int _startDelay, _hold, _gap, _repeat, _exitDelay;
    readonly string _dpiMode;
    readonly int _animateFps;
    int _animTick;
    Bitmap? _background;
    Bitmap? _matrix;
    readonly Random _rnd = new(3);
    public string Renderer = "d3d";
    D3DRenderer? _d3d;
    sealed class MatrixPx { public uint[] Px = Array.Empty<uint>(); public int W, H; }
    volatile MatrixPx? _want;
    volatile int _wantVersion;
    TaskCompletionSource<long>? _presentTcs;
    volatile bool _closing;
    uint[]? _bgPixels;

    public MatrixForm(List<FrameSpec> frames, int cell, double scale, string size, string pos, string background, int startDelayMs, int holdMs, int gapMs, int repeat, int exitDelayMs, string dpiMode, int animateFps)
    {
        _frames = frames; _cell = cell; _scale = scale; _bg = background;
        _startDelay = startDelayMs; _hold = holdMs; _gap = gapMs; _repeat = repeat; _exitDelay = exitDelayMs; _dpiMode = dpiMode; _animateFps = animateFps;
        Text = "T3TestWindow";
        var sz = size.Split('x'); var ps = pos.Split(',');
        StartPosition = FormStartPosition.Manual;
        Location = new Point(int.Parse(ps[0]), int.Parse(ps[1]));
        ClientSize = new Size(int.Parse(sz[0]), int.Parse(sz[1]));
        DoubleBuffered = true;
        FormBorderStyle = FormBorderStyle.Sizable;
        ShowInTaskbar = true;
        BackColor = Color.FromArgb(40, 60, 50);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        BuildBackground();
        if (Renderer == "d3d")
        {
            _d3d = new D3DRenderer(Handle, ClientSize.Width, ClientSize.Height);
            _bgPixels = ToPixels(_background!).Px;
            new Thread(RenderLoop) { IsBackground = true, Name = "render" }.Start();
        }
        else Invalidate();
        Program.Log(new { ev = "ready", hwnd = $"0x{Handle.ToInt64():X}", pid = Environment.ProcessId, clientW = ClientSize.Width, clientH = ClientSize.Height, dpi = DeviceDpi, dpiMode = _dpiMode, cell = _cell, scale = _scale, renderer = Renderer });
        _ = RunAsync();
        if (_animateFps > 0 && Renderer != "d3d")
        {
            // Game-like continuous rendering: repaint a moving bar below the matrix area every frame.
            var t = new System.Windows.Forms.Timer { Interval = Math.Max(1, 1000 / _animateFps) };
            t.Tick += (_, _) => { _animTick++; Invalidate(); };
            t.Start();
        }
    }

    void BuildBackground()
    {
        int w = Math.Max(1, ClientSize.Width), h = Math.Max(1, ClientSize.Height);
        _background = new Bitmap(w, h, PixelFormat.Format32bppRgb);
        var r = new Random(1);
        var data = _background.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
        unsafe
        {
            for (int y = 0; y < h; y++)
            {
                uint* row = (uint*)((byte*)data.Scan0 + y * data.Stride);
                for (int x = 0; x < w; x++)
                {
                    int v = _bg switch
                    {
                        "black" => 0,
                        "white" => 255,
                        _ => Math.Clamp((int)(90 + 70 * Math.Sin(x / 13.0) * Math.Cos(y / 9.0) + r.Next(60)), 0, 255),
                    };
                    int g = _bg == "game" ? Math.Clamp(v + 20, 0, 255) : v;
                    row[x] = (uint)((v << 16) | (g << 8) | (v / 2 + (_bg == "game" ? 30 : v / 2)));
                }
            }
        }
        _background.UnlockBits(data);
    }

    Bitmap RenderMatrix(FrameSpec f)
    {
        // Cell edges at round(k * cell * scale): with scale != 1 this mimics a UI scale that does not
        // map one cell to an integer number of physical pixels (nearest-neighbour rasterization).
        double pitch = _cell * _scale;
        int w = (int)Math.Round(256 * pitch), h = (int)Math.Round(f.Rows * pitch);
        var bmp = new Bitmap(Math.Max(1, w), Math.Max(1, h), PixelFormat.Format32bppRgb);
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
        unsafe
        {
            for (int row = 0; row < f.Rows; row++)
            {
                int y0 = (int)Math.Round(row * pitch), y1 = (int)Math.Round((row + 1) * pitch);
                string s = f.Cells[row];
                for (int cx = 0; cx < 256; cx++)
                {
                    int x0 = (int)Math.Round(cx * pitch), x1 = (int)Math.Round((cx + 1) * pitch);
                    uint col = s[cx] == '1' ? 0xFFFFFFu : 0x000000u;
                    for (int y = y0; y < y1 && y < bmp.Height; y++)
                    {
                        uint* p = (uint*)((byte*)data.Scan0 + y * data.Stride);
                        for (int x = x0; x < x1 && x < bmp.Width; x++) p[x] = col;
                    }
                }
            }
        }
        bmp.UnlockBits(data);
        return bmp;
    }

    static MatrixPx ToPixels(Bitmap b)
    {
        var px = new uint[b.Width * b.Height];
        var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
        unsafe { for (int y = 0; y < b.Height; y++) { uint* row = (uint*)((byte*)d.Scan0 + y * d.Stride); for (int x = 0; x < b.Width; x++) px[y * b.Width + x] = row[x] | 0xFF000000u; } }
        b.UnlockBits(d);
        return new MatrixPx { Px = px, W = b.Width, H = b.Height };
    }

    // Continuous vsync rendering, like a game: every frame = background + moving bar + current matrix.
    void RenderLoop()
    {
        int W = _d3d!.Width, H = _d3d.Height;
        var frame = new uint[W * H];
        int presentedVersion = 0, tick = 0, presents = 0;
        long winStart = Environment.TickCount64;
        while (!_closing)
        {
            Array.Copy(_bgPixels!, frame, frame.Length);
            int bx = (tick++ * 7) % Math.Max(1, W - 60);
            for (int y = Math.Max(0, H - 36); y < H - 4; y++) for (int x = bx; x < Math.Min(W, bx + 60); x++) frame[y * W + x] = 0xFFC8B428u;
            int ver = _wantVersion;
            var m = _want;
            if (m != null)
                for (int y = 0; y < Math.Min(H, m.H); y++) Array.Copy(m.Px, y * m.W, frame, y * W, Math.Min(W, m.W));
            try { _d3d.Present(frame); } catch (Exception e) { Program.Log(new { ev = "error", message = e.Message }); return; }
            presents++;
            if (Environment.TickCount64 - winStart >= 1000) { Program.Log(new { ev = "paints", perSec = presents }); presents = 0; winStart = Environment.TickCount64; }
            if (ver != presentedVersion)
            {
                presentedVersion = ver;
                Interlocked.Exchange(ref _presentTcs, null)?.TrySetResult(Program.UnixUs());
            }
        }
    }

    async Task<long> PresentD3D(MatrixPx? m)
    {
        var tcs = new TaskCompletionSource<long>(TaskCreationOptions.RunContinuationsAsynchronously);
        _presentTcs = tcs;
        _want = m;
        Interlocked.Increment(ref _wantVersion);
        return await tcs.Task;
    }

    async Task RunAsync()
    {
        await Task.Delay(_startDelay);
        if (Renderer == "d3d")
        {
            for (int rep = 0; rep < _repeat; rep++)
                foreach (var f in _frames)
                {
                    using var bmp = RenderMatrix(f);
                    long shown = await PresentD3D(ToPixels(bmp));
                    Program.Log(new { ev = "shown", label = f.Label, rep, rows = f.Rows, unixUs = shown });
                    await Task.Delay(f.HoldMs ?? _hold);
                    long hidden = await PresentD3D(null);
                    Program.Log(new { ev = "hidden", label = f.Label, rep, unixUs = hidden });
                    await Task.Delay(_gap);
                }
            Program.Log(new { ev = "done", unixUs = Program.UnixUs() });
            await Task.Delay(_exitDelay);
            _closing = true;
            await Task.Delay(100);
            Close();
            return;
        }
        for (int rep = 0; rep < _repeat; rep++)
        {
            foreach (var f in _frames)
            {
                _matrix = RenderMatrix(f);
                Invalidate(new Rectangle(0, 0, _matrix.Width, _matrix.Height));
                Update(); // synchronous WM_PAINT: the pixels are in the window's surface when this returns
                long shown = Program.UnixUs();
                Program.Log(new { ev = "shown", label = f.Label, rep, rows = f.Rows, unixUs = shown });
                await Task.Delay(f.HoldMs ?? _hold);
                var old = _matrix; _matrix = null;
                Invalidate(new Rectangle(0, 0, old.Width, old.Height));
                Update();
                Program.Log(new { ev = "hidden", label = f.Label, rep, unixUs = Program.UnixUs() });
                old.Dispose();
                await Task.Delay(_gap);
            }
        }
        Program.Log(new { ev = "done", unixUs = Program.UnixUs() });
        await Task.Delay(_exitDelay);
        Close();
    }

    int _paints; long _paintWindowStart = Environment.TickCount64;
    protected override void OnPaint(PaintEventArgs e)
    {
        if (Renderer == "d3d") return;
        _paints++;
        if (Environment.TickCount64 - _paintWindowStart >= 1000) { Program.Log(new { ev = "paints", perSec = _paints }); _paints = 0; _paintWindowStart = Environment.TickCount64; }
        var g = e.Graphics;
        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
        g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
        // Explicit pixel rectangles: never let GDI+ rescale by bitmap DPI.
        if (_background != null) g.DrawImage(_background, new Rectangle(0, 0, _background.Width, _background.Height), 0, 0, _background.Width, _background.Height, GraphicsUnit.Pixel);
        if (_matrix != null) g.DrawImage(_matrix, new Rectangle(0, 0, _matrix.Width, _matrix.Height), 0, 0, _matrix.Width, _matrix.Height, GraphicsUnit.Pixel);
        if (_animateFps > 0)
        {
            int x = (_animTick * 7) % Math.Max(1, ClientSize.Width - 60);
            using var b = new SolidBrush(Color.FromArgb(200, 180, 40));
            g.FillRectangle(Brushes.DarkSlateGray, 0, ClientSize.Height - 40, ClientSize.Width, 40);
            g.FillRectangle(b, x, ClientSize.Height - 36, 60, 32);
        }
    }

    protected override void OnPaintBackground(PaintEventArgs e) { if (_background == null && Renderer != "d3d") base.OnPaintBackground(e); }
}

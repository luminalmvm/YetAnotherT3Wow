// T3Capture one-shot tools for the companion's image support (PROTOCOL rev 1.3). Each runs, prints one JSON
// line on stdout and exits. Nothing here captures the screen or touches the game.
//
//   T3Capture version                                   {"version":2,"tools":[...]}
//   T3Capture clipboard --out <file.png>                image on the clipboard -> PNG. Exit 0 written, 2 no image, 1 error.
//                                                       Formats, in order: "PNG" (keeps alpha), a copied image file
//                                                       (CF_HDROP), CF_DIB, CF_DIBV5.
//   T3Capture decode --in <file> --max 512 --out <raw> decoded, EXIF-rotated, scaled to fit max x max (never up)
//                                                       -> raw RGBA (straight alpha, top row first). {"w","h","srcW","srcH"}
//   T3Capture convert --in <file> --out <file.jpg> [--max-edge 4096] [--quality 90]
//                                                       re-encode as JPEG (for uploads over T3's size limit)
//   T3Capture procinfo --process Wow                    [{"pid","startMs","name"}] running processes with that name
//
// Decoding uses Windows Imaging Component through Windows.Graphics.Imaging: PNG, JPEG, GIF (first frame),
// BMP, TIFF, ICO, JPEG XR, and WebP/HEIF when the Windows codecs are installed. TGA is decoded by the companion.
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace T3Capture;

internal static class Tools
{
    public static readonly string[] Names = { "version", "clipboard", "decode", "convert", "procinfo" };

    public static bool IsTool(string[] args) => args.Length > 0 && Array.IndexOf(Names, args[0]) >= 0;

    static void Json(object o) { Console.Out.WriteLine(JsonSerializer.Serialize(o)); Console.Out.Flush(); }

    static string? Arg(string[] a, string name)
    {
        for (int i = 1; i < a.Length - 1; i++) if (a[i] == name) return a[i + 1];
        return null;
    }

    /// <summary>Runs a tool on an STA thread (the clipboard prefers one) and returns its exit code.</summary>
    public static int Run(string[] args)
    {
        int code = 1;
        var t = new Thread(() =>
        {
            try { code = RunInner(args); }
            catch (Exception e) { Json(new { error = e.Message }); code = 1; }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
        return code;
    }

    static int RunInner(string[] a)
    {
        switch (a[0])
        {
            case "version":
                Json(new { version = 2, tools = Names });
                return 0;
            case "clipboard":
                return Clipboard(Arg(a, "--out") ?? throw new ArgumentException("--out required"));
            case "decode":
                {
                    var input = Arg(a, "--in") ?? throw new ArgumentException("--in required");
                    var output = Arg(a, "--out") ?? throw new ArgumentException("--out required");
                    int max = int.Parse(Arg(a, "--max") ?? "512");
                    var r = Decode(File.ReadAllBytes(input), max);
                    File.WriteAllBytes(output, r.Rgba);
                    Json(new { w = r.W, h = r.H, srcW = r.SrcW, srcH = r.SrcH });
                    return 0;
                }
            case "convert":
                {
                    var input = Arg(a, "--in") ?? throw new ArgumentException("--in required");
                    var output = Arg(a, "--out") ?? throw new ArgumentException("--out required");
                    int maxEdge = int.Parse(Arg(a, "--max-edge") ?? "4096");
                    double q = double.Parse(Arg(a, "--quality") ?? "90", System.Globalization.CultureInfo.InvariantCulture) / 100.0;
                    var r = Decode(File.ReadAllBytes(input), maxEdge);
                    // JPEG has no alpha: composite onto white.
                    for (int i = 0; i < r.Rgba.Length; i += 4)
                    {
                        int al = r.Rgba[i + 3];
                        for (int c = 0; c < 3; c++) r.Rgba[i + c] = (byte)((r.Rgba[i + c] * al + 255 * (255 - al) + 127) / 255);
                        r.Rgba[i + 3] = 255;
                    }
                    File.WriteAllBytes(output, Encode(BitmapEncoder.JpegEncoderId, r.Rgba, r.W, r.H, q));
                    Json(new { w = r.W, h = r.H, bytes = new FileInfo(output).Length });
                    return 0;
                }
            case "procinfo":
                {
                    var name = (Arg(a, "--process") ?? "Wow").Replace(".exe", "", StringComparison.OrdinalIgnoreCase);
                    var list = new List<object>();
                    foreach (var p in Process.GetProcessesByName(name))
                    {
                        long start = 0;
                        try { start = new DateTimeOffset(p.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds(); } catch { }
                        list.Add(new { pid = p.Id, startMs = start, name = p.ProcessName });
                    }
                    Json(list);
                    return 0;
                }
        }
        return 1;
    }

    // ------------------------------------------------------------------------------------------
    // Imaging
    // ------------------------------------------------------------------------------------------

    public sealed record Decoded(byte[] Rgba, int W, int H, int SrcW, int SrcH);

    /// <summary>Fit (w, h) inside max x max keeping the aspect ratio; never upscales. Same rule as the companion's fitSize().</summary>
    public static (int w, int h) Fit(int w, int h, int max)
    {
        double s = Math.Min(1.0, Math.Min((double)max / w, (double)max / h));
        int tw = Math.Clamp((int)Math.Round(w * s, MidpointRounding.AwayFromZero), 1, max);
        int th = Math.Clamp((int)Math.Round(h * s, MidpointRounding.AwayFromZero), 1, max);
        return (tw, th);
    }

    static IRandomAccessStream ToStream(byte[] bytes)
    {
        var ms = new InMemoryRandomAccessStream();
        using (var w = new DataWriter(ms.GetOutputStreamAt(0)))
        {
            w.WriteBytes(bytes);
            w.StoreAsync().AsTask().GetAwaiter().GetResult();
            w.FlushAsync().AsTask().GetAwaiter().GetResult();
            w.DetachStream();
        }
        ms.Seek(0);
        return ms;
    }

    public static Decoded Decode(byte[] bytes, int max)
    {
        using var stream = ToStream(bytes);
        var dec = BitmapDecoder.CreateAsync(stream).AsTask().GetAwaiter().GetResult();
        int ow = (int)dec.OrientedPixelWidth, oh = (int)dec.OrientedPixelHeight;
        var (tw, th) = Fit(ow, oh, max);
        // The scale applies to the stored frame, before the EXIF rotation.
        bool swapped = dec.OrientedPixelWidth != dec.PixelWidth && dec.PixelWidth != dec.PixelHeight;
        var tf = new BitmapTransform
        {
            ScaledWidth = (uint)(swapped ? th : tw),
            ScaledHeight = (uint)(swapped ? tw : th),
            InterpolationMode = BitmapInterpolationMode.Fant,
        };
        PixelDataProvider pd;
        try
        {
            pd = dec.GetPixelDataAsync(BitmapPixelFormat.Rgba8, BitmapAlphaMode.Straight, tf, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb).AsTask().GetAwaiter().GetResult();
        }
        catch
        {
            pd = dec.GetPixelDataAsync(BitmapPixelFormat.Rgba8, BitmapAlphaMode.Straight, tf, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage).AsTask().GetAwaiter().GetResult();
        }
        var px = pd.DetachPixelData();
        if (px.Length != tw * th * 4) throw new InvalidDataException($"decoder returned {px.Length} bytes for {tw}x{th}");
        return new Decoded(px, tw, th, ow, oh);
    }

    public static byte[] Encode(Guid encoderId, byte[] rgba, int w, int h, double jpegQuality = 0.9)
    {
        var ms = new InMemoryRandomAccessStream();
        BitmapEncoder enc;
        if (encoderId == BitmapEncoder.JpegEncoderId)
        {
            var props = new BitmapPropertySet { { "ImageQuality", new BitmapTypedValue(jpegQuality, Windows.Foundation.PropertyType.Single) } };
            enc = BitmapEncoder.CreateAsync(encoderId, ms, props).AsTask().GetAwaiter().GetResult();
        }
        else enc = BitmapEncoder.CreateAsync(encoderId, ms).AsTask().GetAwaiter().GetResult();
        enc.SetPixelData(BitmapPixelFormat.Rgba8, encoderId == BitmapEncoder.JpegEncoderId ? BitmapAlphaMode.Ignore : BitmapAlphaMode.Straight, (uint)w, (uint)h, 96, 96, rgba);
        enc.FlushAsync().AsTask().GetAwaiter().GetResult();
        var outBytes = new byte[ms.Size];
        using (var r = new DataReader(ms.GetInputStreamAt(0)))
        {
            r.LoadAsync((uint)ms.Size).AsTask().GetAwaiter().GetResult();
            r.ReadBytes(outBytes);
        }
        return outBytes;
    }

    static byte[] ToPng(byte[] imageBytes)
    {
        var d = Decode(imageBytes, 16384);
        return Encode(BitmapEncoder.PngEncoderId, d.Rgba, d.W, d.H);
    }

    // ------------------------------------------------------------------------------------------
    // Clipboard (Win32; read-only)
    // ------------------------------------------------------------------------------------------

    const uint CF_DIB = 8, CF_HDROP = 15, CF_DIBV5 = 17;
    static readonly string[] ImageExt = { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".jxr", ".heic" };

    [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr hWndNewOwner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormatW(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr h);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern uint DragQueryFileW(IntPtr hDrop, uint iFile, StringBuilder? lpszFile, uint cch);

    static byte[]? GlobalBytes(IntPtr h)
    {
        if (h == IntPtr.Zero) return null;
        var size = (long)GlobalSize(h).ToUInt64();
        if (size <= 0 || size > 512L * 1024 * 1024) return null;
        var p = GlobalLock(h);
        if (p == IntPtr.Zero) return null;
        try { var b = new byte[size]; Marshal.Copy(p, b, 0, (int)size); return b; }
        finally { GlobalUnlock(h); }
    }

    /// <summary>A CF_DIB/CF_DIBV5 block (BITMAPINFOHEADER/V5 + optional masks/palette + bits) as a .bmp file.</summary>
    public static byte[] DibToBmp(byte[] dib)
    {
        int biSize = BitConverter.ToInt32(dib, 0);
        int bitCount = BitConverter.ToUInt16(dib, 14);
        int compression = BitConverter.ToInt32(dib, 16);
        int clrUsed = BitConverter.ToInt32(dib, 32);
        int colors = clrUsed != 0 ? clrUsed : (bitCount <= 8 ? 1 << bitCount : 0);
        int masks = (compression == 3 && biSize == 40) ? 12 : 0;
        int offBits = 14 + biSize + masks + colors * 4;
        var bmp = new byte[14 + dib.Length];
        bmp[0] = (byte)'B'; bmp[1] = (byte)'M';
        BitConverter.GetBytes(bmp.Length).CopyTo(bmp, 2);
        BitConverter.GetBytes(offBits).CopyTo(bmp, 10);
        System.Buffer.BlockCopy(dib, 0, bmp, 14, dib.Length);
        return bmp;
    }

    static int Clipboard(string outPath)
    {
        bool open = false;
        for (int i = 0; i < 20 && !open; i++) { open = OpenClipboard(IntPtr.Zero); if (!open) Thread.Sleep(50); }
        if (!open) { Json(new { error = "clipboard is busy" }); return 1; }
        byte[]? png = null; string source = "";
        string? fileName = null;
        try
        {
            uint pngFmt = RegisterClipboardFormatW("PNG");
            if (pngFmt != 0 && IsClipboardFormatAvailable(pngFmt))
            {
                var b = GlobalBytes(GetClipboardData(pngFmt));
                if (b != null && b.Length > 8 && b[0] == 0x89 && b[1] == 0x50) { png = b; source = "png"; }
            }
            if (png == null && IsClipboardFormatAvailable(CF_HDROP))
            {
                var h = GetClipboardData(CF_HDROP);
                uint n = h == IntPtr.Zero ? 0 : DragQueryFileW(h, 0xFFFFFFFF, null, 0);
                for (uint k = 0; k < n && png == null; k++)
                {
                    var sb = new StringBuilder(1024);
                    DragQueryFileW(h, k, sb, (uint)sb.Capacity);
                    var path = sb.ToString();
                    if (Array.IndexOf(ImageExt, Path.GetExtension(path).ToLowerInvariant()) < 0 || !File.Exists(path)) continue;
                    var info = new FileInfo(path);
                    if (info.Length > 64L * 1024 * 1024) continue;
                    var bytes = File.ReadAllBytes(path);
                    png = Path.GetExtension(path).Equals(".png", StringComparison.OrdinalIgnoreCase) ? bytes : ToPng(bytes);
                    source = "file";
                    fileName = Path.GetFileName(path);
                }
            }
            foreach (var fmt in new[] { CF_DIB, CF_DIBV5 })
            {
                if (png != null || !IsClipboardFormatAvailable(fmt)) continue;
                var dib = GlobalBytes(GetClipboardData(fmt));
                if (dib == null || dib.Length < 40) continue;
                try { png = ToPng(DibToBmp(dib)); source = fmt == CF_DIB ? "dib" : "dibv5"; } catch { png = null; }
            }
        }
        finally { CloseClipboard(); }
        if (png == null) { Json(new { image = false }); return 2; }
        File.WriteAllBytes(outPath, png);
        Json(new { image = true, source, bytes = png.Length, name = fileName });
        return 0;
    }
}

// Win32 / D3D11 / WinRT interop for T3Capture. Raw vtable calls keep the helper dependency-free.
using System.Runtime.InteropServices;
using System.Text;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;

namespace T3Capture;

[StructLayout(LayoutKind.Sequential)]
internal struct RECT { public int Left, Top, Right, Bottom; public int Width => Right - Left; public int Height => Bottom - Top; }

[StructLayout(LayoutKind.Sequential)]
internal struct POINT { public int X, Y; }

[StructLayout(LayoutKind.Sequential)]
internal struct D3D11_TEXTURE2D_DESC
{
    public uint Width, Height, MipLevels, ArraySize;
    public uint Format; // DXGI_FORMAT
    public uint SampleCount, SampleQuality;
    public uint Usage, BindFlags, CPUAccessFlags, MiscFlags;
}

[StructLayout(LayoutKind.Sequential)]
internal struct D3D11_BOX { public uint Left, Top, Front, Right, Bottom, Back; }

[StructLayout(LayoutKind.Sequential)]
internal struct D3D11_MAPPED_SUBRESOURCE { public IntPtr pData; public uint RowPitch; public uint DepthPitch; }

internal static class Native
{
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new(-4);

    [DllImport("combase.dll", CharSet = CharSet.Unicode)] public static extern int WindowsCreateString(string src, uint length, out IntPtr hstring);
    [DllImport("combase.dll")] public static extern int WindowsDeleteString(IntPtr hstring);
    [DllImport("combase.dll")] public static extern int RoGetActivationFactory(IntPtr activatableClassId, ref Guid iid, out IntPtr factory);

    [DllImport("d3d11.dll")]
    public static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr featureLevels,
        uint numFeatureLevels, uint sdkVersion, out IntPtr device, out int featureLevel, out IntPtr immediateContext);

    [DllImport("d3d11.dll")]
    public static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    public static readonly Guid IID_IDXGIDevice = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    public static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    public static readonly Guid IID_IDirect3DDxgiInterfaceAccess = new("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1");
    public static readonly Guid IID_IGraphicsCaptureItemInterop = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    public static readonly Guid IID_IGraphicsCaptureItem = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    public static void Check(int hr, string what) { if (hr < 0) throw new COMException($"{what} failed (0x{hr:X8})", hr); }

    public static IntPtr QI(IntPtr unk, Guid iid)
    {
        Check(Marshal.QueryInterface(unk, ref iid, out var p), "QueryInterface");
        return p;
    }

    public static (IntPtr device, IntPtr context, IDirect3DDevice winrtDevice) CreateDevice()
    {
        const int D3D_DRIVER_TYPE_HARDWARE = 1;
        const uint D3D11_CREATE_DEVICE_BGRA_SUPPORT = 0x20;
        int hr = D3D11CreateDevice(IntPtr.Zero, D3D_DRIVER_TYPE_HARDWARE, IntPtr.Zero, D3D11_CREATE_DEVICE_BGRA_SUPPORT, IntPtr.Zero, 0, 7,
            out var device, out _, out var ctx);
        if (hr < 0)
        {
            const int D3D_DRIVER_TYPE_WARP = 5;
            Check(D3D11CreateDevice(IntPtr.Zero, D3D_DRIVER_TYPE_WARP, IntPtr.Zero, D3D11_CREATE_DEVICE_BGRA_SUPPORT, IntPtr.Zero, 0, 7,
                out device, out _, out ctx), "D3D11CreateDevice");
        }
        var dxgi = QI(device, IID_IDXGIDevice);
        try
        {
            Check(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out var insp), "CreateDirect3D11DeviceFromDXGIDevice");
            var winrt = WinRT.MarshalInterface<IDirect3DDevice>.FromAbi(insp);
            Marshal.Release(insp);
            return (device, ctx, winrt);
        }
        finally { Marshal.Release(dxgi); }
    }

    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    public static unsafe GraphicsCaptureItem CreateItemForWindow(IntPtr hwnd) => CreateItem(hwnd, false);
    public static unsafe GraphicsCaptureItem CreateItemForMonitorOf(IntPtr hwnd) => CreateItem(MonitorFromWindow(hwnd, 2 /* NEAREST */), true);

    static unsafe GraphicsCaptureItem CreateItem(IntPtr handle, bool monitor)
    {
        const string cls = "Windows.Graphics.Capture.GraphicsCaptureItem";
        Check(WindowsCreateString(cls, (uint)cls.Length, out var hs), "WindowsCreateString");
        IntPtr interop;
        try { var iidF = IID_IGraphicsCaptureItemInterop; Check(RoGetActivationFactory(hs, ref iidF, out interop), "RoGetActivationFactory"); }
        finally { WindowsDeleteString(hs); }
        try
        {
            var vtbl = *(IntPtr**)interop;
            var create = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)vtbl[monitor ? 4 : 3];
            Guid iid = IID_IGraphicsCaptureItem;
            IntPtr itemPtr;
            Check(create(interop, handle, &iid, &itemPtr), monitor ? "CreateForMonitor" : "CreateForWindow");
            var item = GraphicsCaptureItem.FromAbi(itemPtr);
            Marshal.Release(itemPtr);
            return item;
        }
        finally { Marshal.Release(interop); }
    }

    /** ID3D11Texture2D* behind a WinRT IDirect3DSurface (caller releases). */
    public static unsafe IntPtr TextureFromSurface(IDirect3DSurface surface)
    {
        var obj = (WinRT.IWinRTObject)surface;
        var access = QI(obj.NativeObject.ThisPtr, IID_IDirect3DDxgiInterfaceAccess);
        try
        {
            var vtbl = *(IntPtr**)access;
            var getInterface = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)vtbl[3];
            Guid iid = IID_ID3D11Texture2D;
            IntPtr tex;
            Check(getInterface(access, &iid, &tex), "IDirect3DDxgiInterfaceAccess.GetInterface");
            return tex;
        }
        finally { Marshal.Release(access); }
    }

    // ID3D11Device::CreateTexture2D = vtable slot 5
    public static unsafe IntPtr CreateStagingTexture(IntPtr device, uint w, uint h)
    {
        var desc = new D3D11_TEXTURE2D_DESC
        {
            Width = w, Height = h, MipLevels = 1, ArraySize = 1, Format = 87 /* B8G8R8A8_UNORM */, SampleCount = 1, SampleQuality = 0,
            Usage = 3 /* STAGING */, BindFlags = 0, CPUAccessFlags = 0x20000 /* READ */, MiscFlags = 0,
        };
        var vtbl = *(IntPtr**)device;
        var fn = (delegate* unmanaged[Stdcall]<IntPtr, D3D11_TEXTURE2D_DESC*, IntPtr, IntPtr*, int>)vtbl[5];
        IntPtr tex;
        Check(fn(device, &desc, IntPtr.Zero, &tex), "CreateTexture2D");
        return tex;
    }

    // ID3D11DeviceContext: Map = 14, Unmap = 15, CopySubresourceRegion = 46
    public static unsafe void CopySubresourceRegion(IntPtr ctx, IntPtr dst, IntPtr src, D3D11_BOX box)
    {
        var vtbl = *(IntPtr**)ctx;
        var fn = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, uint, uint, uint, IntPtr, uint, D3D11_BOX*, void>)vtbl[46];
        fn(ctx, dst, 0, 0, 0, 0, src, 0, &box);
    }

    public static unsafe D3D11_MAPPED_SUBRESOURCE Map(IntPtr ctx, IntPtr res)
    {
        var vtbl = *(IntPtr**)ctx;
        var fn = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, uint, uint, D3D11_MAPPED_SUBRESOURCE*, int>)vtbl[14];
        D3D11_MAPPED_SUBRESOURCE m;
        Check(fn(ctx, res, 0, 1 /* D3D11_MAP_READ */, 0, &m), "Map");
        return m;
    }

    public static unsafe void Unmap(IntPtr ctx, IntPtr res)
    {
        var vtbl = *(IntPtr**)ctx;
        var fn = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, void>)vtbl[15];
        fn(ctx, res, 0);
    }

    public static string WindowText(IntPtr h) { var sb = new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }
    public static string ClassName(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
}

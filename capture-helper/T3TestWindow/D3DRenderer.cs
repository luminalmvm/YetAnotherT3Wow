// Game-like presenter for T3TestWindow: D3D11 device + FLIP_DISCARD swapchain, vsync Present every frame,
// CPU-composed BGRA image uploaded with UpdateSubresource. This is what WGC sees from a real game (WoW
// presents a D3D12 flip-model swapchain), unlike GDI painting.
using System.Runtime.InteropServices;

namespace T3TestWindow;

[StructLayout(LayoutKind.Sequential)]
internal struct DXGI_SWAP_CHAIN_DESC
{
    public uint Width, Height, RefreshNum, RefreshDen, Format, ScanlineOrdering, Scaling;
    public uint SampleCount, SampleQuality;
    public uint BufferUsage, BufferCount;
    public IntPtr OutputWindow;
    public int Windowed;
    public uint SwapEffect, Flags;
}

internal sealed unsafe class D3DRenderer : IDisposable
{
    [DllImport("d3d11.dll")]
    static extern int D3D11CreateDeviceAndSwapChain(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr featureLevels, uint numFeatureLevels,
        uint sdkVersion, ref DXGI_SWAP_CHAIN_DESC desc, out IntPtr swapChain, out IntPtr device, out int featureLevel, out IntPtr context);

    static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    readonly IntPtr _swap, _device, _ctx;
    public readonly int Width, Height;

    public D3DRenderer(IntPtr hwnd, int width, int height)
    {
        Width = width; Height = height;
        var desc = new DXGI_SWAP_CHAIN_DESC
        {
            Width = (uint)width, Height = (uint)height, RefreshNum = 0, RefreshDen = 1, Format = 87 /* B8G8R8A8_UNORM */,
            SampleCount = 1, SampleQuality = 0, BufferUsage = 0x20 /* RENDER_TARGET_OUTPUT */, BufferCount = 2,
            OutputWindow = hwnd, Windowed = 1, SwapEffect = 4 /* FLIP_DISCARD */, Flags = 0,
        };
        int hr = D3D11CreateDeviceAndSwapChain(IntPtr.Zero, 1 /* HARDWARE */, IntPtr.Zero, 0x20 /* BGRA */, IntPtr.Zero, 0, 7, ref desc, out _swap, out _device, out _, out _ctx);
        if (hr < 0) throw new COMException($"D3D11CreateDeviceAndSwapChain 0x{hr:X8}", hr);
    }

    /** Uploads a full BGRA frame (Width*Height*4) to the back buffer and presents with vsync. */
    public void Present(uint[] bgra)
    {
        var sv = *(IntPtr**)_swap;
        var getBuffer = (delegate* unmanaged[Stdcall]<IntPtr, uint, Guid*, IntPtr*, int>)sv[9];
        Guid iid = IID_ID3D11Texture2D;
        IntPtr back;
        int hr = getBuffer(_swap, 0, &iid, &back);
        if (hr < 0) throw new COMException($"GetBuffer 0x{hr:X8}", hr);
        try
        {
            var cv = *(IntPtr**)_ctx;
            var update = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, IntPtr, void*, uint, uint, void>)cv[48];
            fixed (uint* p = bgra) update(_ctx, back, 0, IntPtr.Zero, p, (uint)(Width * 4), 0);
        }
        finally { Marshal.Release(back); }
        var present = (delegate* unmanaged[Stdcall]<IntPtr, uint, uint, int>)sv[8];
        present(_swap, 1, 0);
    }

    public void Dispose()
    {
        Marshal.Release(_ctx); Marshal.Release(_device); Marshal.Release(_swap);
    }
}

using System;
using System.IO;
using System.Runtime.InteropServices;
class Hfa {
    [StructLayout(LayoutKind.Sequential)] struct V2 { public float x, y; public V2(float x, float y) { this.x = x; this.y = y; } }
    [StructLayout(LayoutKind.Sequential)] struct V4 { public float x, y, z, w; public V4(float x, float y, float z, float w) { this.x = x; this.y = y; this.z = z; this.w = w; } }
    const CallingConvention C = CallingConvention.Cdecl;
    [UnmanagedFunctionPointer(C)] delegate float CbV2(V2 v, float k);
    [UnmanagedFunctionPointer(C)] delegate float CbV4(V4 v, long a, long b, long c, long d);
    [UnmanagedFunctionPointer(C)] delegate V2 CbMkV2(float x, float y);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float cb_v2_call(CbV2 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float cb_v4_call(CbV4 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float cb_mkv2_call(CbMkV2 f);
    static void Dump(string name, Delegate d) {
        IntPtr e = Marshal.GetFunctionPointerForDelegate(d);
        int off = Marshal.ReadInt32(e, -4);
        IntPtr thunk = (IntPtr)((long)e + (off & ~3));
        int len = -(off & ~3) - 4;
        byte[] b = new byte[len]; Marshal.Copy(thunk, b, 0, len);
        File.WriteAllBytes(name + ".thunk.bin", b);
        Console.WriteLine("{0}: entry=0x{1:x} off={2} thunk=0x{3:x} len={4}", name, (long)e, off, (long)thunk, len);
    }
    static void Main(string[] args) {
        CbV2 c2 = (v, k) => { Console.WriteLine("  cb V2: x={0} y={1} k={2}", v.x, v.y, k); return v.x + 10*v.y + 100*k; };
        CbV4 c4 = (v, a, b, c, d) => { Console.WriteLine("  cb V4: {0} {1} {2} {3} | {4} {5} {6} {7}", v.x, v.y, v.z, v.w, a, b, c, d); return v.x + 10*v.y + 100*v.z + 1000*v.w + a + 2*b + 3*c + 4*d; };
        CbMkV2 m2 = (x, y) => { Console.WriteLine("  cb MkV2: {0} {1}", x, y); return new V2(x, y); };
        Dump("v2", c2); Dump("v4", c4); Dump("mkv2", m2);
        if (args.Length == 0 || args[0] == "v2") Console.WriteLine("cb_v2_call -> " + cb_v2_call(c2));
        if (args.Length == 0 || args[0] == "v4") Console.WriteLine("cb_v4_call -> " + cb_v4_call(c4));
        if (args.Length == 0 || args[0] == "mkv2") Console.WriteLine("cb_mkv2_call -> " + cb_mkv2_call(m2));
    }
}

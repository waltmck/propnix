using System;
using System.Runtime.InteropServices;
using System.Text;
class Probe {
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetModuleHandleA(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr LoadLibraryA(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr mod, string name);
    [DllImport("ntdll.dll")] static extern byte RtlIsEcCode(IntPtr addr);
    [DllImport("kernel32.dll")] static extern int MultiByteToWideChar(uint cp, uint flags, byte[] src, int srclen, [Out] char[] dst, int dstlen);
    [DllImport("kernel32.dll")] static extern uint GetLastError();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)] static extern double pow(double x, double y);
    [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)] static extern double ldexp(double x, int exp);
    [DllImport("ucrtbase.dll", CallingConvention = CallingConvention.Cdecl)] static extern double fma(double x, double y, double z);
    [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr memset(byte[] dst, int c, IntPtr n);
    static void Show(string dll, string fn) {
        IntPtr m = LoadLibraryA(dll); IntPtr p = GetProcAddress(m, fn);
        uint b0 = (uint)Marshal.ReadInt32(p);
        Console.WriteLine("{0,-12} {1,-22} addr=0x{2:x} ec={3} first-insn=0x{4:x8}", dll, fn, (long)p, RtlIsEcCode(p), b0);
    }
    static void Main() {
        Show("kernel32.dll", "MultiByteToWideChar");
        Show("kernelbase.dll", "MultiByteToWideChar");
        Show("msvcrt.dll", "qsort");
        Show("msvcrt.dll", "pow");
        Show("ntdll.dll", "RtlIsEcCode");
        Show("ucrtbase.dll", "pow");
        byte[] src = Encoding.ASCII.GetBytes("hello");
        char[] dst = new char[16];
        int n = MultiByteToWideChar(0, 0, src, src.Length, dst, dst.Length);
        Console.WriteLine("MultiByteToWideChar -> {0} (lasterr={1}) '{2}'", n, GetLastError(), new string(dst, 0, Math.Max(n,0)));
        int n2 = MultiByteToWideChar(65001, 0, src, 5, dst, 16);
        Console.WriteLine("MultiByteToWideChar(65001) -> {0} (lasterr={1}) dst[0]={2}", n2, GetLastError(), (int)dst[0]);
        byte[] zz = new byte[8]; memset(zz, 0x41, (IntPtr)8); Console.WriteLine("memset(int in pos 2) -> {0}", Encoding.ASCII.GetString(zz));
        IntPtr h = CreateFileW("C:\\windows\\system32\\kernel32.dll", 0x80000000, 1, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
        Console.WriteLine("CreateFileW(7 args) -> 0x{0:x} (lasterr={1})", (long)h, GetLastError());
        if (h != (IntPtr)(-1)) CloseHandle(h);
        Console.WriteLine("pow(2,10)={0} ldexp(1.5,4)={1} (int in pos 2) fma(2,3,4)={2}", pow(2,10), ldexp(1.5,4), fma(2,3,4));
    }
}

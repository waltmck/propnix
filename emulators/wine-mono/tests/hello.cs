using System;
using System.Runtime.InteropServices;
class Hello {
    [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
    static int Fib(int n) => n < 2 ? n : Fib(n - 1) + Fib(n - 2);
    static void Main() {
        Console.WriteLine("hello from managed code, pid " + GetCurrentProcessId());
        var sw = System.Diagnostics.Stopwatch.StartNew();
        int f = Fib(32);
        Console.WriteLine("fib(32)=" + f + " in " + sw.ElapsedMilliseconds + " ms");
        Console.WriteLine("runtime: " + typeof(object).Assembly.ImageRuntimeVersion + " ptr=" + IntPtr.Size);
    }
}

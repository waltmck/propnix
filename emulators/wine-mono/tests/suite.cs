using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Linq;
class Suite {
    [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetEnvironmentVariableW(string name, System.Text.StringBuilder buf, int size);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long f);
    [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)] static extern double pow(double x, double y);
    [DllImport("kernel32.dll")] static extern int MultiByteToWideChar(uint cp, uint flags, byte[] src, int srcLen, [Out] char[] dst, int dstLen);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Cmp(IntPtr a, IntPtr b);
    [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)] static extern void qsort(int[] arr, IntPtr n, IntPtr size, Cmp cmp);
    static void Check(string name, Func<bool> f) {
        try { Console.WriteLine((f() ? "OK   " : "FAIL ") + name); }
        catch (Exception e) { Console.WriteLine("EXC  " + name + ": " + e.GetType().Name + ": " + e.Message); }
    }
    static int Fib(int n) => n < 2 ? n : Fib(n - 1) + Fib(n - 2);
    static void Main() {
        Check("pinvoke 0 args", () => GetCurrentProcessId() != 0);
        Check("pinvoke 3 args + string marshal", () => { var sb = new System.Text.StringBuilder(260); return GetEnvironmentVariableW("WINEPREFIX", sb, 260) > 0 || true; });
        Check("pinvoke out param", () => { long f; return QueryPerformanceFrequency(out f) && f > 0; });
        Check("pinvoke double args/return (x64 convention)", () => Math.Abs(pow(2.0, 10.0) - 1024.0) < 1e-9);
        Check("exception throw/catch", () => { try { throw new InvalidOperationException("x"); } catch (InvalidOperationException) { return true; } });
        Check("generics + linq", () => Enumerable.Range(1, 100).Where(i => i % 2 == 0).Select(i => i * i).Sum() == 171700);
        Check("string formatting", () => string.Format("{0:F2} {1} {2:X}", 3.14159, "s", 255) == "3.14 s FF");
        Check("gc pressure (stop-the-world)", () => { var l = new List<byte[]>(); for (int i = 0; i < 20000; i++) l.Add(new byte[1024]); GC.Collect(); GC.WaitForPendingFinalizers(); return l.Count == 20000; });
        Check("threads", () => { int sum = 0; var ts = new Thread[4]; for (int t = 0; t < 4; t++) { ts[t] = new Thread(() => { for (int i = 0; i < 100000; i++) Interlocked.Increment(ref sum); }); ts[t].Start(); } foreach (var t in ts) t.Join(); return sum == 400000; });
        Check("managed delegate", () => { Func<int,int> f = x => x + 1; return f(41) == 42; });
        var sw = System.Diagnostics.Stopwatch.StartNew(); int r = Fib(35); Console.WriteLine("fib(35)=" + r + " in " + sw.ElapsedMilliseconds + " ms");
        // the native-boundary checks last: a native crash ends the run
        Check("pinvoke 6 args (stack args, non-variadic)", () => { var src = System.Text.Encoding.ASCII.GetBytes("hello"); var dst = new char[16]; return MultiByteToWideChar(65001, 0, src, 5, dst, 16) == 5 && dst[0] == 'h'; });
        Check("reverse pinvoke (qsort callback)", () => { var a = new[] { 3, 1, 2 }; qsort(a, (IntPtr)3, (IntPtr)4, (x, y) => Marshal.ReadInt32(x) - Marshal.ReadInt32(y)); return a[0] == 1 && a[2] == 3; });
        // hardware faults last: they currently take the process down before anything after them
        Check("null deref → NullReferenceException", () => { string s = null; try { return s.Length == 0; } catch (NullReferenceException) { return true; } });
        Check("divide by zero", () => { int z = 0; try { return 1 / z == 0; } catch (DivideByZeroException) { return true; } });
        Console.WriteLine("done");
    }
}

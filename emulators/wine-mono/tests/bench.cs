// bench.cs — managed micro-benchmarks for comparing the x86_64 runtime (under FEX) with the ARM64EC runtime.
// Prints one line per benchmark: "<name> <ms>". Deterministic workloads, checksums printed to keep the JIT honest.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

static class Bench {
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long v);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();

    static long T(string name, Func<long> f) {
        f(); // warm-up (JIT + caches)
        var best = long.MaxValue; long chk = 0;
        for (int i = 0; i < 3; i++) { var sw = Stopwatch.StartNew(); chk = f(); sw.Stop(); if (sw.ElapsedMilliseconds < best) best = sw.ElapsedMilliseconds; }
        Console.WriteLine("{0,-22} {1,7} ms   chk={2}", name, best, chk);
        return best;
    }

    static int Fib(int n) { return n < 2 ? n : Fib(n - 1) + Fib(n - 2); }

    // --- nbody (Benchmarks Game), 2,000,000 steps
    struct Body { public double x, y, z, vx, vy, vz, mass; }
    static long NBody() {
        const double PI = 3.141592653589793, SOLAR = 4 * PI * PI, DPY = 365.24;
        var b = new Body[] {
            new Body { mass = SOLAR },
            new Body { x = 4.84143144246472090e+00, y = -1.16032004402742839e+00, z = -1.03622044471123109e-01, vx = 1.66007664274403694e-03 * DPY, vy = 7.69901118419740425e-03 * DPY, vz = -6.90460016972063023e-05 * DPY, mass = 9.54791938424326609e-04 * SOLAR },
            new Body { x = 8.34336671824457987e+00, y = 4.12479856412430479e+00, z = -4.03523417114321381e-01, vx = -2.76742510726862411e-03 * DPY, vy = 4.99852801234917238e-03 * DPY, vz = 2.30417297573763929e-05 * DPY, mass = 2.85885980666130812e-04 * SOLAR },
            new Body { x = 1.28943695621391310e+01, y = -1.51111514016986312e+01, z = -2.23307578892655734e-01, vx = 2.96460137564761618e-03 * DPY, vy = 2.37847173959480950e-03 * DPY, vz = -2.96589568540237556e-05 * DPY, mass = 4.36624404335156298e-05 * SOLAR },
            new Body { x = 1.53796971148509165e+01, y = -2.59193146099879641e+01, z = 1.79258772950371181e-01, vx = 2.68067772490389322e-03 * DPY, vy = 1.62824170038242295e-03 * DPY, vz = -9.51592254519715870e-05 * DPY, mass = 5.15138902046611451e-05 * SOLAR } };
        double px = 0, py = 0, pz = 0;
        for (int i = 0; i < b.Length; i++) { px += b[i].vx * b[i].mass; py += b[i].vy * b[i].mass; pz += b[i].vz * b[i].mass; }
        b[0].vx = -px / SOLAR; b[0].vy = -py / SOLAR; b[0].vz = -pz / SOLAR;
        for (int step = 0; step < 2000000; step++) {
            for (int i = 0; i < b.Length; i++) {
                for (int j = i + 1; j < b.Length; j++) {
                    double dx = b[i].x - b[j].x, dy = b[i].y - b[j].y, dz = b[i].z - b[j].z;
                    double d2 = dx * dx + dy * dy + dz * dz, mag = 0.01 / (d2 * Math.Sqrt(d2));
                    b[i].vx -= dx * b[j].mass * mag; b[i].vy -= dy * b[j].mass * mag; b[i].vz -= dz * b[j].mass * mag;
                    b[j].vx += dx * b[i].mass * mag; b[j].vy += dy * b[i].mass * mag; b[j].vz += dz * b[i].mass * mag;
                }
            }
            for (int i = 0; i < b.Length; i++) { b[i].x += 0.01 * b[i].vx; b[i].y += 0.01 * b[i].vy; b[i].z += 0.01 * b[i].vz; }
        }
        double e = 0;
        for (int i = 0; i < b.Length; i++) {
            e += 0.5 * b[i].mass * (b[i].vx * b[i].vx + b[i].vy * b[i].vy + b[i].vz * b[i].vz);
            for (int j = i + 1; j < b.Length; j++) { double dx = b[i].x - b[j].x, dy = b[i].y - b[j].y, dz = b[i].z - b[j].z; e -= b[i].mass * b[j].mass / Math.Sqrt(dx * dx + dy * dy + dz * dz); }
        }
        return (long)(e * 1e9);
    }

    // --- spectral-norm n = 1000
    static double A(int i, int j) { return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1); }
    static void MulAv(int n, double[] v, double[] av) { for (int i = 0; i < n; i++) { double s = 0; for (int j = 0; j < n; j++) s += A(i, j) * v[j]; av[i] = s; } }
    static void MulAtv(int n, double[] v, double[] atv) { for (int i = 0; i < n; i++) { double s = 0; for (int j = 0; j < n; j++) s += A(j, i) * v[j]; atv[i] = s; } }
    static long Spectral() {
        int n = 1000; var u = new double[n]; var v = new double[n]; var t = new double[n];
        for (int i = 0; i < n; i++) u[i] = 1;
        for (int i = 0; i < 10; i++) { MulAv(n, u, t); MulAtv(n, t, v); MulAv(n, v, t); MulAtv(n, t, u); }
        double vBv = 0, vv = 0; for (int i = 0; i < n; i++) { vBv += u[i] * v[i]; vv += v[i] * v[i]; }
        return (long)(Math.Sqrt(vBv / vv) * 1e9);
    }

    // --- binary-trees depth 16 (allocation + GC)
    class Node { public Node l, r; }
    static Node Make(int d) { return d == 0 ? new Node() : new Node { l = Make(d - 1), r = Make(d - 1) }; }
    static int Check(Node n) { return n.l == null ? 1 : 1 + Check(n.l) + Check(n.r); }
    static long Trees() {
        int max = 16; var longLived = Make(max); long total = 0;
        for (int d = 4; d <= max; d += 2) { int iters = 1 << (max - d + 4); for (int i = 0; i < iters; i++) total += Check(Make(d)); }
        return total + Check(longLived);
    }

    // --- fannkuch-redux n = 10
    static long Fannkuch() {
        int n = 10; var perm = new int[n]; var perm1 = new int[n]; var count = new int[n];
        int maxFlips = 0, checksum = 0, r = n, permCount = 0;
        for (int i = 0; i < n; i++) perm1[i] = i;
        while (true) {
            while (r != 1) { count[r - 1] = r; r--; }
            for (int i = 0; i < n; i++) perm[i] = perm1[i];
            int flips = 0, k;
            while ((k = perm[0]) != 0) { int i2 = k + 1 >> 1; for (int i = 0; i < i2; i++) { int t = perm[i]; perm[i] = perm[k - i]; perm[k - i] = t; } flips++; }
            if (flips > maxFlips) maxFlips = flips;
            checksum += (permCount % 2 == 0) ? flips : -flips;
            while (true) {
                if (r == n) return (long)checksum * 1000 + maxFlips;
                int p0 = perm1[0]; for (int i = 0; i < r; i++) perm1[i] = perm1[i + 1]; perm1[r] = p0;
                if (--count[r] > 0) break; r++;
            }
            permCount++;
        }
    }

    // --- mandelbrot 1600
    static long Mandelbrot() {
        int n = 1600; long acc = 0;
        for (int y = 0; y < n; y++) {
            double ci = 2.0 * y / n - 1.0;
            for (int x = 0; x < n; x++) {
                double cr = 2.0 * x / n - 1.5, zr = 0, zi = 0; int i = 0;
                for (; i < 50 && zr * zr + zi * zi <= 4.0; i++) { double t = zr * zr - zi * zi + cr; zi = 2 * zr * zi + ci; zr = t; }
                acc += i;
            }
        }
        return acc;
    }

    // --- dictionary + strings (typical game-logic shapes)
    static long DictStrings() {
        var d = new Dictionary<string, int>(); var sb = new StringBuilder(); long acc = 0;
        for (int i = 0; i < 400000; i++) { string k = "key" + (i % 50000); int v; if (d.TryGetValue(k, out v)) d[k] = v + 1; else d[k] = 1; }
        for (int i = 0; i < 200000; i++) { sb.Length = 0; sb.Append("item ").Append(i).Append(' ').Append(i * 0.5); acc += sb.Length; }
        var list = new List<int>(); for (int i = 0; i < 2000000; i++) list.Add(i ^ 0x5555); list.Sort((a, b) => b.CompareTo(a)); acc += list[7];
        return acc + d.Count;
    }

    // --- allocation churn: 20M short-lived objects (nursery pressure, no retention)
    static long Alloc() { long acc = 0; for (int i = 0; i < 20000000; i++) { var o = new int[4]; o[1] = i; acc += o[1] & 7; } return acc; }

    // --- virtual/interface dispatch + generics
    interface IShape { double Area(); }
    class Sq : IShape { public double s; public double Area() { return s * s; } }
    class Ci : IShape { public double r; public double Area() { return 3.14159 * r * r; } }
    static long Dispatch() { var shapes = new IShape[1000]; for (int i = 0; i < 1000; i++) shapes[i] = (i & 1) == 0 ? (IShape)new Sq { s = i } : new Ci { r = i }; double a = 0; for (int k = 0; k < 20000; k++) for (int i = 0; i < 1000; i++) a += shapes[i].Area(); return (long)a; }

    // --- p/invoke into a system DLL (EC code both ways; under the x64 runtime each call crosses the emulator)
    static long PInvoke() { long v; long acc = 0; for (int i = 0; i < 1000000; i++) { QueryPerformanceCounter(out v); acc += v & 1; acc += GetTickCount() & 1; } return acc; }

    // --- exceptions: throw/catch 200k
    static long Exceptions() { long c = 0; for (int i = 0; i < 200000; i++) { try { if ((i & 1) == 0) throw new InvalidOperationException("x"); c++; } catch (InvalidOperationException) { c += 2; } } return c; }

    static void Main() {
        Console.WriteLine("runtime: {0}  ptr={1}  policy={2}", Environment.Version, IntPtr.Size, Environment.GetEnvironmentVariable("MONO_THREADS_SUSPEND") ?? "(default)");
        long total = 0;
        total += T("fib(35)", () => Fib(35));
        total += T("nbody 2M", NBody);
        total += T("spectral-norm 1000", Spectral);
        total += T("binary-trees 16", Trees);
        total += T("fannkuch 10", Fannkuch);
        total += T("mandelbrot 1600", Mandelbrot);
        total += T("dict+strings+sort", DictStrings);
        total += T("alloc 20M", Alloc);
        total += T("interface dispatch", Dispatch);
        total += T("pinvoke 2M calls", PInvoke);
        total += T("exceptions 200k", Exceptions);
        Console.WriteLine("{0,-22} {1,7} ms", "TOTAL", total);
    }
}

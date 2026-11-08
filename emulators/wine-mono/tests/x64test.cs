using System;
using System.Runtime.InteropServices;
class X64Test {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long Cb6(long a,long b,long c,long d,long e,long f);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate double CbMix(long a,double b,long c,double d,long e);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long Cb12(long a,long b,long c,long d,long e,long f,long g,long h,long i,long j,long k,long l);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern long sum6(long a,long b,long c,long d,long e,long f);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern double mix5(long a,double b,long c,double d,long e);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern long sum12(long a,long b,long c,long d,long e,long f,long g,long h,long i,long j,long k,long l);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern float fmix(float a,int b,float c,int d,float e);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern long invoke6(Cb6 f);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern double invokemix(CbMix f);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern long invoke12(Cb12 f);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern long invoke6_twice(Cb6 f);
    [DllImport("x64test.dll", CallingConvention = CallingConvention.Cdecl)] static extern int where_am_i();
    [StructLayout(LayoutKind.Sequential)] struct S8 { public int a, b; public S8(int a, int b) { this.a = a; this.b = b; } }
    [StructLayout(LayoutKind.Sequential)] struct S12 { public int a, b, c; public S12(int a, int b, int c) { this.a = a; this.b = b; this.c = c; } }
    [StructLayout(LayoutKind.Sequential)] struct S16 { public long a, b; public S16(long a, long b) { this.a = a; this.b = b; } }
    [StructLayout(LayoutKind.Sequential)] struct S24 { public long a, b, c; public S24(long a, long b, long c) { this.a = a; this.b = b; this.c = c; } }
    [StructLayout(LayoutKind.Sequential)] struct V2 { public float x, y; public V2(float x, float y) { this.x = x; this.y = y; } }
    [StructLayout(LayoutKind.Sequential)] struct V3 { public float x, y, z; public V3(float x, float y, float z) { this.x = x; this.y = y; this.z = z; } }
    [StructLayout(LayoutKind.Sequential)] struct V4 { public float x, y, z, w; public V4(float x, float y, float z, float w) { this.x = x; this.y = y; this.z = z; this.w = w; } }
    [StructLayout(LayoutKind.Sequential)] struct D2 { public double x, y; public D2(double x, double y) { this.x = x; this.y = y; } }
    const CallingConvention C = CallingConvention.Cdecl;
    [DllImport("x64test.dll", CallingConvention = C)] static extern long s8_sum(S8 s, long k);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long s12_sum(long k, S12 s);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long s16_sum(S16 s, S16 t);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long s24_sum(S24 s);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float v2_sum(V2 v, float k);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float v3_sum(V3 v);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float v4_sum(V4 v, long a, long b, long c, long d);
    [DllImport("x64test.dll", CallingConvention = C)] static extern double d2_sum(D2 v);
    [DllImport("x64test.dll", CallingConvention = C)] static extern S8 s8_make(int a, int b);
    [DllImport("x64test.dll", CallingConvention = C)] static extern S12 s12_make(int a, int b, int c);
    [DllImport("x64test.dll", CallingConvention = C)] static extern S16 s16_make(long a, long b);
    [DllImport("x64test.dll", CallingConvention = C)] static extern S24 s24_make(long a, long b, long c);
    [DllImport("x64test.dll", CallingConvention = C)] static extern V2 v2_make(float x, float y);
    [DllImport("x64test.dll", CallingConvention = C)] static extern V3 v3_make(float x, float y, float z);
    [DllImport("x64test.dll", CallingConvention = C)] static extern V4 v4_make(float x, float y, float z, float w);
    [DllImport("x64test.dll", CallingConvention = C)] static extern D2 d2_make(double x, double y);
    [UnmanagedFunctionPointer(C)] delegate long CbS8(S8 s, long k);
    [UnmanagedFunctionPointer(C)] delegate long CbS12(long k, S12 s);
    [UnmanagedFunctionPointer(C)] delegate float CbV2(V2 v, float k);
    [UnmanagedFunctionPointer(C)] delegate float CbV4(V4 v, long a, long b, long c, long d);
    [UnmanagedFunctionPointer(C)] delegate S8 CbMk8(int a, int b);
    [UnmanagedFunctionPointer(C)] delegate S12 CbMk12(int a, int b, int c);
    [UnmanagedFunctionPointer(C)] delegate V2 CbMkV2(float x, float y);
    [UnmanagedFunctionPointer(C)] delegate V4 CbMkV4(float x, float y, float z, float w);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long cb_s8_call(CbS8 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long cb_s12_call(CbS12 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float cb_v2_call(CbV2 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float cb_v4_call(CbV4 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long cb_mk8_call(CbMk8 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long cb_mk12_call(CbMk12 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float cb_mkv2_call(CbMkV2 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float cb_mkv4_call(CbMkV4 f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long s16_then_ints(S16 s, long a, long b, long c);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float v2_then_floats(V2 v, float a, float b, float c);
    [DllImport("x64test.dll", CallingConvention = C)] static extern double v4_then_mixed(V4 v, double a, long b, double c);
    [UnmanagedFunctionPointer(C)] delegate long CbS16I(S16 s, long a, long b, long c);
    [UnmanagedFunctionPointer(C)] delegate float CbV2F(V2 v, float a, float b, float c);
    [UnmanagedFunctionPointer(C)] delegate double CbV4M(V4 v, double a, long b, double c);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long cb_s16i_call(CbS16I f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern float cb_v2f_call(CbV2F f);
    [DllImport("x64test.dll", CallingConvention = C)] static extern double cb_v4m_call(CbV4M f);
    [StructLayout(LayoutKind.Sequential)] struct V3S { public short x, y, z; public V3S(short x, short y, short z) { this.x = x; this.y = y; this.z = z; } }
    [DllImport("x64test.dll", CallingConvention = C)] static extern void v3s_add(IntPtr a, IntPtr b, uint n, V3S p, V3S q);
    [DllImport("x64test.dll", CallingConvention = C)] static extern long v3s_get();
    [DllImport("x64test.dll", CallingConvention = C)] static extern V3S v3s_make(short x, short y, short z);
    [UnmanagedFunctionPointer(C)] delegate void CbV3S(IntPtr a, IntPtr b, uint n, V3S p, V3S q);
    [DllImport("x64test.dll", CallingConvention = C)] static extern void cb_v3s_call(CbV3S f);
    static int fails = 0;
    static void Check(string name, Func<bool> f) {
        bool ok; try { ok = f(); } catch (Exception e) { Console.WriteLine("EXC  " + name + ": " + e.GetType().Name + " " + e.Message); fails++; return; }
        Console.WriteLine((ok ? "OK   " : "FAIL ") + name); if (!ok) fails++;
    }
    static void Main() {
        Check("x64 dll loads (where_am_i)", () => where_am_i() == 64);
        Check("exit: 6 int args (2 on stack)", () => sum6(1,2,3,4,5,6) == 654321);
        Check("exit: mixed int/double positional", () => Math.Abs(mix5(1,2.0,3,4.0,5) - 54321.0) < 1e-9);
        Check("exit: 12 int args (8 on stack)", () => sum12(1,2,3,4,5,6,7,8,9,10,11,12) == 78);
        Check("exit: mixed float/int32", () => Math.Abs(fmix(1f,2,3f,4,5f) - 54321f) < 1e-3);
        Cb6 c6 = (a,b,c,d,e,f) => a + 10*b + 100*c + 1000*d + 10000*e + 100000*f;
        Check("entry: callback with 6 int args", () => invoke6(c6) == 654321);
        Check("entry: callback called twice", () => invoke6_twice(c6) == 654321 + 123456);
        CbMix cm = (a,b,c,d,e) => a + 10*b + 100*c + 1000*d + 10000*e;
        Check("entry: callback mixed int/double", () => Math.Abs(invokemix(cm) - 54321.0) < 1e-9);
        Cb12 c12 = (a,b,c,d,e,f,g,h,i,j,k,l) => a+b+c+d+e+f+g+h+i+j+k+l;
        Check("entry: callback with 12 int args", () => invoke12(c12) == 78);
        Check("entry: callback that throws+catches", () => invoke6((a,b,c,d,e,f) => { try { throw new Exception("x"); } catch (Exception) { return a+f; } }) == 7);
        Check("exit: 8-byte struct by value + int", () => s8_sum(new S8(1,2), 3) == 321);
        Check("exit: 12-byte struct (x64 by pointer, EC in 2 regs)", () => s12_sum(4, new S12(1,2,3)) == 4321);
        Check("exit: two 16-byte structs", () => s16_sum(new S16(1,2), new S16(3,4)) == 4321);
        Check("exit: 24-byte struct (by ref both sides)", () => s24_sum(new S24(1,2,3)) == 321);
        Check("exit: 8-byte HFA (V2) + float", () => Math.Abs(v2_sum(new V2(1,2), 3) - 321f) < 1e-3);
        Check("exit: 12-byte HFA (V3)", () => Math.Abs(v3_sum(new V3(1,2,3)) - 321f) < 1e-3);
        Check("exit: 16-byte HFA (V4) + 4 ints (stack)", () => Math.Abs(v4_sum(new V4(1,2,3,4), 5,6,7,8) - (4321f + 5 + 12 + 21 + 32)) < 1e-3);
        Check("exit: 16-byte double HFA (D2)", () => Math.Abs(d2_sum(new D2(1,2)) - 21.0) < 1e-9);
        Check("exit: return 8-byte struct", () => { var s = s8_make(1,2); return s.a == 1 && s.b == 2; });
        Check("exit: return 12-byte struct (hidden retbuf)", () => { var s = s12_make(1,2,3); return s.a == 1 && s.b == 2 && s.c == 3; });
        Check("exit: return 16-byte struct", () => { var s = s16_make(1,2); return s.a == 1 && s.b == 2; });
        Check("exit: return 24-byte struct", () => { var s = s24_make(1,2,3); return s.a == 1 && s.b == 2 && s.c == 3; });
        Check("exit: return V2 (HFA in rax)", () => { var v = v2_make(1,2); return v.x == 1 && v.y == 2; });
        Check("exit: return V3 (HFA via retbuf)", () => { var v = v3_make(1,2,3); return v.x == 1 && v.y == 2 && v.z == 3; });
        Check("exit: return V4", () => { var v = v4_make(1,2,3,4); return v.x == 1 && v.y == 2 && v.z == 3 && v.w == 4; });
        Check("exit: return D2", () => { var v = d2_make(1,2); return v.x == 1 && v.y == 2; });
        Check("entry: callback 8-byte struct + int", () => cb_s8_call((s, k) => s.a + 10*s.b + 100*k) == 321);
        Check("entry: callback 12-byte struct by pointer", () => cb_s12_call((k, s) => s.a + 10*s.b + 100*s.c + 1000*k) == 4321);
        Check("entry: callback V2 + float", () => Math.Abs(cb_v2_call((v, k) => v.x + 10*v.y + 100*k) - 321f) < 1e-3);
        Check("entry: callback V4 + 4 ints", () => Math.Abs(cb_v4_call((v, a, b, c, d) => v.x + 10*v.y + 100*v.z + 1000*v.w + a + 2*b + 3*c + 4*d) - (4321f + 5 + 12 + 21 + 32)) < 1e-3);
        Check("entry: callback returning 8-byte struct", () => cb_mk8_call((a, b) => new S8(a, b)) == 21);
        Check("entry: callback returning 12-byte struct", () => cb_mk12_call((a, b, c) => new S12(a, b, c)) == 321);
        Check("entry: callback returning V2", () => Math.Abs(cb_mkv2_call((x, y) => new V2(x, y)) - 21f) < 1e-3);
        Check("entry: callback returning V4", () => Math.Abs(cb_mkv4_call((x, y, z, w) => new V4(x, y, z, w)) - 4321f) < 1e-3);
        Check("exit: 16-byte struct then ints (index shift)", () => s16_then_ints(new S16(1,2), 3,4,5) == 54321);
        Check("exit: V2 then floats (fp index shift)", () => Math.Abs(v2_then_floats(new V2(1,2), 3,4,5) - 54321f) < 1e-2);
        Check("exit: V4 then double/int/double", () => Math.Abs(v4_then_mixed(new V4(1,2,3,4), 5,6,7) - 7654321.0) < 1e-6);
        Check("entry: callback 16-byte struct then ints", () => cb_s16i_call((s,a,b,c) => s.a + 10*s.b + 100*a + 1000*b + 10000*c) == 54321);
        Check("entry: callback V2 then floats", () => Math.Abs(cb_v2f_call((v,a,b,c) => v.x + 10*v.y + 100*a + 1000*b + 10000*c) - 54321f) < 1e-2);
        Check("entry: callback V4 then double/int/double", () => Math.Abs(cb_v4m_call((v,a,b,c) => v.x + 10*v.y + 100*v.z + 1000*v.w + 10000*a + 100000*b + 1000000*c) - 7654321.0) < 1e-6);
        Check("exit: Havok shape (ptr,ptr,u32,V3S,V3S)", () => { v3s_add((IntPtr)7, (IntPtr)8, 9, new V3S(1,2,3), new V3S(4,5,6)); return v3s_get() == 654321987; });
        Check("exit: return 6-byte struct", () => { var v = v3s_make(1,2,3); return v.x == 1 && v.y == 2 && v.z == 3; });
        Check("entry: callback Havok shape", () => { long got = 0; cb_v3s_call((a,b,n,p,q) => { got = (long)a + 10*(long)b + 100*n + 1000*p.x + 10000*p.y + 100000*p.z + 1000000*q.x + 10000000*q.y + 100000000*q.z; }); return got == 654321987; });
        Check("entry: managed exception thrown THROUGH x64 frames", () => { try { invoke6((a,b,c,d,e,f) => { throw new InvalidOperationException("through"); }); return false; } catch (InvalidOperationException) { return true; } });
        Check("entry: x64 call still works after that unwind", () => invoke6_twice((a,b,c,d,e,f) => a + 10*b + 100*c + 1000*d + 10000*e + 100000*f) == 654321 + 123456);
        Check("entry: nested x64->managed->x64->managed", () => invoke6((a,b,c,d,e,f) => invoke6((g,h,i,j,k,l) => g+h+i+j+k+l) + a) == 22);
        Console.WriteLine(fails == 0 ? "ALL OK" : fails + " FAILED");
    }
}

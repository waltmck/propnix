/* x86_64 native test DLL: exercises EC->x64 exit thunks and x64->EC entry thunks under FEX. */
#include <stdint.h>
#define EXPORT __declspec(dllexport)
typedef int64_t (*cb6)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t);
typedef double  (*cbmix)(int64_t,double,int64_t,double,int64_t);
typedef int64_t (*cb12)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t);
EXPORT int64_t sum6(int64_t a,int64_t b,int64_t c,int64_t d,int64_t e,int64_t f) { return a + 10*b + 100*c + 1000*d + 10000*e + 100000*f; }
EXPORT double  mix5(int64_t a,double b,int64_t c,double d,int64_t e) { return a + 10*b + 100*c + 1000*d + 10000*e; }
EXPORT int64_t sum12(int64_t a,int64_t b,int64_t c,int64_t d,int64_t e,int64_t f,int64_t g,int64_t h,int64_t i,int64_t j,int64_t k,int64_t l) { return a+b+c+d+e+f+g+h+i+j+k+l; }
EXPORT float   fmix(float a,int32_t b,float c,int32_t d,float e) { return a + 10*b + 100*c + 1000*d + 10000*e; }
EXPORT int64_t invoke6(cb6 f) { return f(1,2,3,4,5,6); }
EXPORT double  invokemix(cbmix f) { return f(1,2.0,3,4.0,5); }
EXPORT int64_t invoke12(cb12 f) { return f(1,2,3,4,5,6,7,8,9,10,11,12); }
EXPORT int64_t invoke6_twice(cb6 f) { return f(1,2,3,4,5,6) + f(6,5,4,3,2,1); }
EXPORT int32_t where_am_i(void) { return 64; }

/* ---- aggregates: x64 passes 1/2/4/8-byte structs by value in a register, everything else by pointer ---- */
typedef struct { int32_t a, b; } S8;
typedef struct { int32_t a, b, c; } S12;
typedef struct { int64_t a, b; } S16;
typedef struct { int64_t a, b, c; } S24;
typedef struct { float x, y; } V2;
typedef struct { float x, y, z; } V3;
typedef struct { float x, y, z, w; } V4;
typedef struct { double x, y; } D2;
EXPORT int64_t s8_sum(S8 s, int64_t k) { return s.a + 10*s.b + 100*k; }
EXPORT int64_t s12_sum(int64_t k, S12 s) { return s.a + 10*s.b + 100*s.c + 1000*k; }
EXPORT int64_t s16_sum(S16 s, S16 t) { return s.a + 10*s.b + 100*t.a + 1000*t.b; }
EXPORT int64_t s24_sum(S24 s) { return s.a + 10*s.b + 100*s.c; }
EXPORT float v2_sum(V2 v, float k) { return v.x + 10*v.y + 100*k; }
EXPORT float v3_sum(V3 v) { return v.x + 10*v.y + 100*v.z; }
EXPORT float v4_sum(V4 v, int64_t a, int64_t b, int64_t c, int64_t d) { return v.x + 10*v.y + 100*v.z + 1000*v.w + a + 2*b + 3*c + 4*d; }
EXPORT double d2_sum(D2 v) { return v.x + 10*v.y; }
EXPORT S8  s8_make(int32_t a, int32_t b) { S8 s = {a, b}; return s; }
EXPORT S12 s12_make(int32_t a, int32_t b, int32_t c) { S12 s = {a, b, c}; return s; }
EXPORT S16 s16_make(int64_t a, int64_t b) { S16 s = {a, b}; return s; }
EXPORT S24 s24_make(int64_t a, int64_t b, int64_t c) { S24 s = {a, b, c}; return s; }
EXPORT V2  v2_make(float x, float y) { V2 v = {x, y}; return v; }
EXPORT V3  v3_make(float x, float y, float z) { V3 v = {x, y, z}; return v; }
EXPORT V4  v4_make(float x, float y, float z, float w) { V4 v = {x, y, z, w}; return v; }
EXPORT D2  d2_make(double x, double y) { D2 v = {x, y}; return v; }
typedef int64_t (*cb_s8)(S8, int64_t);
typedef int64_t (*cb_s12)(int64_t, S12);
typedef float   (*cb_v2)(V2, float);
typedef float   (*cb_v4)(V4, int64_t, int64_t, int64_t, int64_t);
typedef S8  (*cb_mk8)(int32_t, int32_t);
typedef S12 (*cb_mk12)(int32_t, int32_t, int32_t);
typedef V2  (*cb_mkv2)(float, float);
typedef V4  (*cb_mkv4)(float, float, float, float);
EXPORT int64_t cb_s8_call(cb_s8 f)   { S8 s = {1, 2}; return f(s, 3); }
EXPORT int64_t cb_s12_call(cb_s12 f) { S12 s = {1, 2, 3}; return f(4, s); }
EXPORT float   cb_v2_call(cb_v2 f)   { V2 v = {1, 2}; return f(v, 3); }
EXPORT float   cb_v4_call(cb_v4 f)   { V4 v = {1, 2, 3, 4}; return f(v, 5, 6, 7, 8); }
EXPORT int64_t cb_mk8_call(cb_mk8 f)   { S8 s = f(1, 2); return s.a + 10*s.b; }
EXPORT int64_t cb_mk12_call(cb_mk12 f) { S12 s = f(1, 2, 3); return s.a + 10*s.b + 100*s.c; }
EXPORT float   cb_mkv2_call(cb_mkv2 f) { V2 v = f(1, 2); return v.x + 10*v.y; }
EXPORT float   cb_mkv4_call(cb_mkv4 f) { V4 v = f(1, 2, 3, 4); return v.x + 10*v.y + 100*v.z + 1000*v.w; }

/* ---- ordering hazards: an aggregate consumes more EC registers than its x64 position implies ---- */
EXPORT int64_t s16_then_ints(S16 s, int64_t a, int64_t b, int64_t c) { return s.a + 10*s.b + 100*a + 1000*b + 10000*c; }
EXPORT float   v2_then_floats(V2 v, float a, float b, float c) { return v.x + 10*v.y + 100*a + 1000*b + 10000*c; }
EXPORT double  v4_then_mixed(V4 v, double a, int64_t b, double c) { return v.x + 10*v.y + 100*v.z + 1000*v.w + 10000*a + 100000*b + 1000000*c; }
typedef int64_t (*cb_s16i)(S16, int64_t, int64_t, int64_t);
typedef float   (*cb_v2f)(V2, float, float, float);
typedef double  (*cb_v4m)(V4, double, int64_t, double);
EXPORT int64_t cb_s16i_call(cb_s16i f) { S16 s = {1, 2}; return f(s, 3, 4, 5); }
EXPORT float   cb_v2f_call(cb_v2f f)   { V2 v = {1, 2}; return f(v, 3, 4, 5); }
EXPORT double  cb_v4m_call(cb_v4m f)   { V4 v = {1, 2, 3, 4}; return f(v, 5, 6, 7); }

/* ---- the Havok shape: void f(ptr, ptr, u32, Vector3S, Vector3S) with Vector3S = 3 shorts (6 bytes: x64 by pointer) ---- */
typedef struct { int16_t x, y, z; } V3S;
static int64_t v3s_acc;
EXPORT void v3s_add(void *a, void *b, uint32_t n, V3S p, V3S q) { v3s_acc = (int64_t)(intptr_t)a + 10*(int64_t)(intptr_t)b + 100*n + 1000*p.x + 10000*p.y + 100000*p.z + 1000000*q.x + 10000000*q.y + 100000000*q.z; }
EXPORT int64_t v3s_get(void) { return v3s_acc; }
EXPORT V3S v3s_make(int16_t x, int16_t y, int16_t z) { V3S v = {x, y, z}; return v; }
typedef void (*cb_v3s)(void*, void*, uint32_t, V3S, V3S);
EXPORT void cb_v3s_call(cb_v3s f) { V3S p = {1, 2, 3}, q = {4, 5, 6}; f((void*)7, (void*)8, 9, p, q); }

/* ---- a deliberate native crash, to study the runtime's crash path ---- */
EXPORT void crash_null(void) { *(volatile int *)0 = 1; }

/* spin.c — does SuspendThread+GetThreadContext complete while the target spins in x64 code?
 * Each variant is a tight loop on a flag, shaped so the back-edge is a specific branch kind. */
#include <windows.h>
#include <stdio.h>
static volatile LONG flag;
static DWORD WINAPI spin_cond(void *p)   /* back-edge = conditional branch (je 1b) */
{ __asm__ volatile("1:\n\tmovl %0, %%eax\n\ttestl %%eax, %%eax\n\tje 1b" : : "m"(flag) : "eax", "memory"); return 0; }
static DWORD WINAPI spin_pause(void *p)  /* same, with pause (the canonical spin-wait) */
{ __asm__ volatile("1:\n\tpause\n\tmovl %0, %%eax\n\ttestl %%eax, %%eax\n\tje 1b" : : "m"(flag) : "eax", "memory"); return 0; }
static DWORD WINAPI spin_uncond(void *p) /* back-edge = unconditional jmp */
{ __asm__ volatile("1:\n\tmovl %0, %%eax\n\ttestl %%eax, %%eax\n\tjne 2f\n\tjmp 1b\n2:" : : "m"(flag) : "eax", "memory"); return 0; }
static void __attribute__((noinline)) nop_call(void) { __asm__ volatile("" ::: "memory"); }
static DWORD WINAPI spin_call(void *p)   /* loop body contains a call (block boundary) */
{ while (!flag) nop_call(); return 0; }
static DWORD WINAPI watchdog(void *p) { Sleep(3000); flag = 1; return 0; }
static void run(const char *name, LPTHREAD_START_ROUTINE fn)
{
    CONTEXT ctx; DWORD ret, ok; LARGE_INTEGER f, t0, t1; HANDLE h, wd;
    flag = 0;
    h = CreateThread(NULL, 0, fn, NULL, 0, NULL);
    Sleep(200);
    QueryPerformanceFrequency(&f);
    wd = CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
    QueryPerformanceCounter(&t0);
    ret = SuspendThread(h);
    memset(&ctx, 0, sizeof(ctx)); ctx.ContextFlags = CONTEXT_FULL;
    ok = GetThreadContext(h, &ctx);
    QueryPerformanceCounter(&t1);
    printf("%-12s SuspendThread=%lu GetThreadContext=%lu Rip=%p after %.0f ms (%s)\n", name, ret, ok, (void *)ctx.Rip,
           (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart,
           (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart < 1000 ? "doorbell polled" : "NOT polled until the loop ended");
    fflush(stdout);
    ResumeThread(h); flag = 1; WaitForSingleObject(h, 5000); WaitForSingleObject(wd, 5000); CloseHandle(h); CloseHandle(wd);
}
int main(void)
{
    run("cond", spin_cond); run("pause", spin_pause); run("uncond", spin_uncond); run("call", spin_call);
    return 0;
}

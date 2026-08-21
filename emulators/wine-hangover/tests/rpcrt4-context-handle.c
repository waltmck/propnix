/*
 * Reproducer for the ARM64EC rpcrt4 stubless-client argument bug that
 * ../patches/0003-rpcrt4-arm64ec-stubless-client-home-space.patch fixes.
 *
 * WHY THIS PARTICULAR CALL. OpenSCManagerW is the smallest ordinary Win32 call that reaches the
 * stubless interpreter with BOTH more than four arguments AND an [out] context handle:
 *
 *   svcctl_OpenSCManagerW(MachineName, DatabaseName, dwAccessMask, [out] SC_RPC_HANDLE *handle)
 *     -> NdrClientCall2(desc, fmt, MachineName, DatabaseName, dwAccessMask, &handle)
 *
 * Counting NdrClientCall2's own two named parameters, dwAccessMask and &handle are arguments 5 and
 * 6 — the first two that travel on the stack, i.e. exactly the ones the thunk locates through x4.
 * The context handle is what turns a silently-wrong argument into a crash: with a garbage pointer in
 * the [out] slot, NdrContextHandleUnmarshall stores through it.
 *
 * Nothing else here touches RPC, so a fault is unambiguous.
 *
 * BUILD (an x86_64 Windows PE — any mingw):
 *   x86_64-w64-mingw32-gcc -O0 -g -o scmtest.exe rpcrt4-context-handle.c -ladvapi32
 *
 * RUN under the wine being tested, on an aarch64 host:
 *   WINEPREFIX=<scratch dir you own> wine ./scmtest.exe
 *
 * BROKEN — dies before printing the [1] result:
 *   wine: Unhandled page fault on write access to 0000000000000010
 *   NdrContextHandleUnmarshall+0xcc [dlls/rpcrt4/ndr_marshall.c:7024]  `str xzr, [x19]`  x19 = 0x10
 *   client_do_args                 [dlls/rpcrt4/ndr_stubless.c:529]
 *
 * FIXED — prints a non-NULL manager handle and reaches [3].
 *
 * HOW THE OFFSET WAS PINNED DOWN, if this ever needs redoing: pass a distinctive access mask
 * (0x12345678) and a non-NULL database name, run with WINEDEBUG=+rpc to get the interpreter's
 * "param[N]: <addr>" lines (which reveal StackTop and each parameter's slot), then dump the slots in
 * winedbg with `print *(long long*)<addr>`. The marker turned up 0x20 above the param[2] slot the
 * interpreter was reading — the size of the x64 home space. `b <symbol>` does not work on ARM64EC
 * code in a hybrid module, so continue to the fault and read memory from there instead.
 */
#include <windows.h>
#include <stdio.h>

int main(void)
{
    SC_HANDLE scm, svc;

    printf("[1] OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT)...\n");
    fflush(stdout);
    scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    printf("[1] -> %p  err=%lu\n", (void *)scm, GetLastError());
    fflush(stdout);
    if (!scm)
        return 1;

    /* A second context-handle call, this time with one as an [in] parameter too. */
    printf("[2] OpenServiceW(scm, L\"Spooler\", SERVICE_QUERY_STATUS)...\n");
    fflush(stdout);
    svc = OpenServiceW(scm, L"Spooler", SERVICE_QUERY_STATUS);
    printf("[2] -> %p  err=%lu\n", (void *)svc, GetLastError());
    fflush(stdout);
    if (svc)
        CloseServiceHandle(svc);

    CloseServiceHandle(scm);
    printf("[3] done, no fault\n");
    fflush(stdout);
    return 0;
}

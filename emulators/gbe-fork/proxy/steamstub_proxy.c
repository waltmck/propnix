/* steamstub_proxy.c — the DllMain half of gbe-fork/steamstub-proxy.nix.
 *
 * This DLL is placed AT a game's shipped `steam_api(64).dll` path. Every one of its exports is a PE
 * FORWARDER to the real gbe_fork shim sitting beside it (the .def is generated at build time from that
 * shim's own export table), so the Steamworks surface is unchanged — the only thing this body adds is one
 * LoadLibrary in DllMain.
 *
 * WHY THAT ONE LoadLibrary HAS TO BE HERE. gbe_fork ships `steamclient_extra_x64.dll`, whose whole job is
 * to patch SteamStub v3.1 (Valve's exe wrapper) in the process's own memory. Upstream loads it by
 * INJECTING it into a suspended process from their ColdClientLoader, because the patch must land before
 * the wrapper's entry-point code runs. propnix has no injector and does not want one: the launcher waits
 * on the process it spawns, so a loader that spawns-and-exits would end the launch, and gbe_fork's
 * persistent modes hold the loader open behind a "press OK" MessageBox.
 *
 * A STATIC IMPORT gets us the same timing for free. The wrapped exe imports `steam_api64.dll` statically,
 * so ntdll runs this DllMain during LdrInitializeThunk — before the exe's entry point, i.e. before the
 * wrapper. MEASURED both ways on civilization-6 (x86_64-linux, 2026-09-03): with this DllMain the game
 * boots to its front end; with gbe_fork's own `steam_settings/load_dlls/` mechanism instead (the
 * experimental shim's documented way to load an extra dll) the process exits 53 with Valve's
 * "Application load error 3:0000065432", because that load happens inside SteamAPI_Init — after the
 * wrapper has already given up.
 *
 * The sibling is resolved from THIS module's own path rather than by bare name: LoadLibrary's search order
 * starts at the EXE's directory, which is only coincidentally the same directory for a game whose steam lib
 * sits beside its exe. Resolving off GetModuleFileNameW makes the pairing structural — the patcher that
 * gets loaded is the one this proxy was staged beside.
 *
 * Failure is deliberately SILENT. A missing/unloadable patcher must not take down a process that would
 * otherwise run: an unwrapped game with this proxy staged simply behaves as the plain shim, and the
 * wrapped one fails later with the wrapper's own error dialog, which is the more legible symptom.
 */
#include <windows.h>

#ifndef PROPNIX_EXTRA_DLL
#error "PROPNIX_EXTRA_DLL (the sibling patcher's file name) must be defined by the build"
#endif

static void load_sibling(HINSTANCE self, const wchar_t *name)
{
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    size_t len;

    /* n == MAX_PATH means truncation (this API does not fail loudly on Windows < 10 semantics). */
    if (n == 0 || n >= MAX_PATH)
        return;
    /* Strip back to and including the last separator, leaving "…\dir\". */
    while (n > 0 && path[n - 1] != L'\\' && path[n - 1] != L'/')
        n--;
    path[n] = L'\0';

    for (len = 0; name[len]; len++)
        ;
    if (n + len + 1 > MAX_PATH)
        return;

    for (size_t i = 0; i <= len; i++)
        path[n + i] = name[i];

    LoadLibraryW(path);
}

BOOL WINAPI DllMain(HINSTANCE self, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
    {
        /* Nothing here is per-thread, and the forwarders carry no state of their own. */
        DisableThreadLibraryCalls(self);
        load_sibling(self, PROPNIX_EXTRA_DLL);
    }
    return TRUE;
}

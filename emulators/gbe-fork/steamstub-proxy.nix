# emulators/gbe-fork/steamstub-proxy.nix — the STEAMSTUB arm of the Windows entitlement shim: a tiny PE
# that goes AT the game's shipped `steam_api(64).dll` path, forwards the whole Steamworks surface to the
# real gbe_fork shim beside it, and — the entire point — loads gbe_fork's `steamclient_extra_*.dll` from
# its own DllMain.
#
# ── WHAT IT SOLVES ────────────────────────────────────────────────────────────────────────────────────
# Valve's SteamStub wraps a shipped exe: a `.bind` section holds the wrapper, the PE entry point is inside
# it, and the real code is encrypted at rest. The wrapper decrypts, then MANUALLY MAPS an embedded copy of
# Valve's own Steam API (`SteamDRMP.dll`) and asks IT whether the app is owned. That code is NOT the
# `steam_api64.dll` on disk, so replacing that file — which is all `steam.emu` normally does — cannot
# answer it. MEASURED on civilization-6 (x86_64-linux, 2026-09-03) with a targeted wine `+relay`:
#
#     Call KERNEL32.OutputDebugStringA("[S_API] SteamAPI_Init(): SteamAPI_IsSteamRunning() …") ret=01054a4e
#     Call shell32.ShellExecuteA(0,"open","steam://run/289070//",…)                             ret=01053ec2
#
# — caller addresses in an anonymous ~0x0105xxxx mapping, in no loaded module (the exe is at 0x140000000,
# every DLL at 0x6FFF…/0x7FFF…). Binding gbe_fork's shim over the shipped dll changed those lines not at
# all; binding a non-PE over it produced a hard `import_dll … failed` instead, which is the control that
# proves the bind was live. So: the wrapper talks only to itself.
#
# gbe_fork's answer is `steamclient_extra_(x64|x86).dll`, which patches SteamStub v3.1 in memory
# ("a new experimental dll (which must be injected first) to patch Stub drm v3.1 in memory" — their
# CHANGELOG). Upstream injects it into a SUSPENDED process from `steamclient_loader_*.exe`. propnix does
# not, for two reasons that are structural rather than aesthetic: the launcher waits on the process it
# spawns (run.rs) and tears the prefix down with `wineserver -k` when it exits, so a loader that
# spawns-and-exits (`[Persistence] Mode=0`) would end the launch immediately; and gbe_fork's persistent
# modes keep the loader alive behind a "Press OK when you have finished playing" MessageBox, i.e. a second
# window on the user's desktop and a launch that never ends on its own.
#
# A STATIC IMPORT reaches the same point in time with no new process machinery: the wrapped exe imports
# `steam_api64.dll` statically, so this DllMain runs inside LdrInitializeThunk, BEFORE the exe's entry
# point — before the wrapper. VERIFIED on civilization-6: proxy staged, no loader, no registry, no
# `steamclient64.dll` → the game reaches its rendered front end. Two things were measured NOT to work and
# are recorded so nobody re-tries them:
#   * gbe_fork's own `steam_settings/load_dlls/` (the experimental shim's documented extra-dll hook) loads
#     the patcher inside SteamAPI_Init — far too late; exit 53 and Valve's "Application load error
#     3:0000065432" dialog.
#   * Satisfying the wrapper instead of patching it — `HKCU\Software\Valve\Steam\ActiveProcess\
#     SteamClientDll64` pointed at gbe_fork's steamclient, which the wrapper DID load ("[S_API]
#     SteamAPI_Init(): Loaded '…\steamclient64.dll' OK."), with the loader's own env/registry setup — still
#     ends at the same "Application load error 3" dialog. The in-memory patch is what the wrapper needs.
#
# ── WHY A FORWARDER .def AND NOT A HAND-WRITTEN SURFACE ────────────────────────────────────────────────
# The proxy must be a DROP-IN for the shim it hides: a game resolves ~17 entry points statically and may
# GetProcAddress more, and a single miss is a hard loader failure. `proxy/gen-def.py` therefore reads the
# PINNED shim's own export table out of the PE and emits one forwarder per name, so the surface tracks the
# gbe_fork pin automatically — unlike galaxy-stub's checked-in `symbols64.txt`, which can be static because
# those symbols are the GAMES' imports, fixed by the GOG SDK.
#
# ── TOOLCHAIN ─────────────────────────────────────────────────────────────────────────────────────────
# Plain C targeting x86_64/i686 Windows, so any mingw cross-compiler builds it; the host leg picks the one
# it already has, exactly as emulators/galaxy-stub argues at length — llvm-mingw on aarch64 (the ARM64EC
# toolchain that leg carries anyway), nixpkgs' cached `pkgsCross.mingwW64` GCC on x86_64, where the
# ARM64EC prebuilt does not exist.
{
  lib,
  runCommand,
  python3,
  # The ARM64EC toolchain: present on aarch64, null on x86_64 (see the header).
  llvmMingw ? null,
  # nixpkgs cross-mingw GCCs, used when llvmMingw is absent. Derivations, not paths.
  mingwGccW64 ? null,
  mingwGcc32 ? null,
  # mcfgthreads import libs for those GCCs (their driver emits a bare -lmcfgthread).
  mingwThreads64 ? null,
  mingwThreads32 ? null,
}:
let
  useLlvm = llvmMingw != null;
  ccFor = {
    x64 =
      if useLlvm then
        "${llvmMingw}/bin/x86_64-w64-mingw32-clang"
      else
        "${mingwGccW64}/bin/x86_64-w64-mingw32-gcc -L${mingwThreads64}/lib";
    x86 =
      if useLlvm then
        "${llvmMingw}/bin/i686-w64-mingw32-clang"
      else
        "${mingwGcc32}/bin/i686-w64-mingw32-gcc -L${mingwThreads32}/lib";
  };
  # Pin the C + generator to a CONTENT-ADDRESSED store path (keyed only by proxy/'s bytes), so unrelated
  # repo edits never rebuild the proxy — the same treatment galaxy-stub gives its src/.
  srcDir = builtins.path {
    path = ./proxy;
    name = "gbe-fork-steamstub-proxy-src";
  };
in
# `dllName` is the SHIPPED name the proxy takes over (steam_api64.dll / steam_api.dll); `shim` is the
# gbe_fork PE it forwards to and `realName` the name that shim is staged under beside it; `extraName` is
# the patcher staged beside them both. The caller (builders/steam-offline-entitlement.nix) owns all three
# placements — this derivation only produces the proxy itself, at `$out/<dllName>`.
{
  shim,
  dllName,
  realName,
  extraName,
  arch ? "x64",
}:
let
  cc =
    ccFor.${arch}
      or (throw "propnix: steamstub-proxy has no toolchain for arch '${arch}' (want x64/x86)");
in
runCommand "gbe-fork-steamstub-proxy-${arch}-${dllName}"
  {
    nativeBuildInputs = [
      python3
    ]
    ++ lib.optional useLlvm llvmMingw;
    meta.description = "SteamStub-aware ${dllName} proxy: forwards to ${realName}, loads ${extraName} from DllMain";
  }
  ''
    set -euo pipefail
    mkdir -p "$out" build && cd build

    # One PE forwarder per export of the PINNED shim (see the header for why this is derived, not listed).
    python3 ${srcDir}/gen-def.py ${lib.escapeShellArg shim} \
      ${lib.escapeShellArg (lib.removeSuffix ".dll" realName)} proxy.def

    # -nostartfiles/-nostdlib would drop the CRT's DllMain wiring, so link normally; the body pulls in
    # nothing but kernel32. The .def is an ordinary link input for both drivers.
    ${cc} -O2 -Wall -Wextra -shared \
      -DPROPNIX_EXTRA_DLL='L"${extraName}"' \
      -o "$out/${dllName}" ${srcDir}/steamstub_proxy.c proxy.def

    # A forwarder-only image is easy to get silently wrong — a .def the driver ignored still links, and the
    # result is a DLL that satisfies no import, i.e. a HARD loader failure in the game with nothing here to
    # point at it. So re-read the BUILT proxy with the same parser and require it to carry exactly the
    # surface the .def asked for, before anything stages it over a game's real dll.
    python3 ${srcDir}/gen-def.py "$out/${dllName}" \
      ${lib.escapeShellArg (lib.removeSuffix ".dll" realName)} built.def
    if ! cmp -s proxy.def built.def; then
      echo "steamstub-proxy: ${dllName}'s export table does not match the generated .def" >&2
      diff proxy.def built.def | head -20 >&2 || true
      exit 1
    fi
    echo "steamstub-proxy: built ${dllName} (-> ${realName}, loads ${extraName})"
  ''

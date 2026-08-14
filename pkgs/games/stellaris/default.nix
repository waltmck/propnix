# Stellaris (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. ARCH-AGNOSTIC: this spec is identical on both hosts; makeAppWine + the scope pick the
# arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across
# arches. Payload = the pinned GOG Galaxy build fetched with gogdl (D15), delivered as the game tree
# directly (no InnoSetup). Stellaris is a Paradox grand-strategy title on the Clausewitz engine (D3D11/D3D9).
#
#   nix run .#stellaris --extra-sandbox-paths /propnix=/var/tmp/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  tuning = (import ./tuning.nix) // {
    # Stellaris (like Prison Architect) STATICALLY imports GOG's Galaxy SDK from the exe's own directory
    # (stellaris.exe → Galaxy64.dll, verified in the PE import table); the SDK's offline RPC init faults wine's
    # builtin rpcrt4 before the first frame. Because it's a static import in the app dir, wine's loader resolves
    # it there first (a system32/WINEDLLOVERRIDES stub can't shadow it), so bind a graceful no-op stub over it
    # via a mount row (aarch64 only; on x86_64 native wine it's omitted). Only Galaxy64.dll is imported here —
    # no Galaxy.dll / pops_api.dll in this build. (nakama-cpp.dll, also a static import, is Paradox's on-demand
    # multiplayer client with no offline-RPC init, so it needs no stub. PDXSDK.dll's MSVCP140/VCRUNTIME140/UCRT
    # imports resolve to wine's builtins, which — unlike Outlast's VC10 msvcp100 — work under FEX, so no
    # extraSystem32 is needed.)
    galaxyStubDlls = [ "Galaxy64.dll" ];
  };
in
makeAppWine {
  pname = "stellaris";
  appid = "stellaris";
  name = "Stellaris";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "stellaris-win"; });
  # Launch the actual game binary DIRECTLY, NOT the goggame.info isPrimary FileTask "dowser.exe" — dowser is
  # Paradox's launcher-bootstrapper (it locates/installs the Paradox launcher, which then spawns the game and
  # exits; a launcher-that-exits trips the propnix launcher's primary-child teardown, like Outlast's
  # OutlastLauncher / KSP's Launcher.exe). stellaris.exe is the 46 MB x86_64 Clausewitz game binary (imports
  # PDXSDK.dll + d3d11/dxgi/d3d9 → DXVK). Content is resolved relative to the game root (= C:\game = payload),
  # so cwd = payload root is correct.
  exe = "stellaris.exe";
  inherit tuning;
  # Broken on aarch64 (runtime-diagnosed): startup gets DEEP into engine init — the Galaxy64 stub works,
  # PDXSDK/nakama load and their MSVCP140/VCRUNTIME140/UCRT/CONCRT140 imports resolve to wine builtins with
  # no loader_init failures, and d3d11/dxgi/d3d9/opengl32 all map — then, BEFORE the first window, a Clausewitz
  # worker thread the game creates with an explicit ~1 MB stack (dwStackSize; the exe's main-thread reserve is
  # 4 MB) OVERFLOWS its stack under FEX: the per-call ARM64EC-transition overhead inflates guest stack use past
  # the native x86_64 need (~1.07 MB used vs the ~1.03 MB the emulated+guard-patched stack gives — a ~40 KB
  # overrun). The guest calls abort(), which wine can't dispatch (its SEH frame is below the thread's stack
  # limits), wedging the thread while it holds a game critical section → the ntdll loader lock deadlocks and the
  # whole process HANGS (deterministic). DISTINCT from KSP's FEX-codegen crash (FEX raises no fault of its own
  # here — it's a genuine guest stack overflow). Same failure CLASS the wine stack-guard-headroom patch
  # (emulators/wine-hangover/patches/0001) mitigates, but this tightly-sized worker needs more; there is NO
  # per-game knob to enlarge a thread the game sizes itself, so the only fix is a larger wine thread-stack
  # reserve at the emulator layer (affects all titles → needs suite-wide re-validation). Native x86_64 (no FEX)
  # is unaffected.
  brokenSystems = [ "aarch64-linux" ];
  brokenReason = "FEX stack pressure overflows a Clausewitz engine worker thread's ~1MB stack during early init (before any window) → guest abort() wine can't dispatch → loader-lock deadlock/hang. No per-game thread-stack knob; needs a larger wine thread-stack reserve at the emulator layer. Runs on native x86_64.";
}

# Kerbal Space Program (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC
# DXVK, on x86_64 natively. ARCH-AGNOSTIC: this spec is identical on both hosts; makeAppWine + the scope
# pick the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared
# across arches. Payload = the pinned GOG Galaxy build fetched with gogdl (D15), delivered as the game tree
# directly (no InnoSetup). KSP is a Unity title.
#
#   nix run .#kerbal-space-program --extra-sandbox-paths /propnix=/var/tmp/propnix   # aarch64/x86_64
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  tuning = import ./tuning.nix;
in
makeAppWine {
  pname = "kerbal-space-program";
  appid = "kerbal-space-program";
  name = "Kerbal Space Program";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "kerbal-space-program-win"; });
  # The GOG build ships a 64-bit-only tree: KSP_x64.exe is the goggame.info isPrimary FileTask (there is no
  # 32-bit KSP.exe at the root). Launcher.exe is the separate Private Division launcher, not the game.
  exe = "KSP_x64.exe";
  inherit tuning;
  # Broken on aarch64: the Unity/Mono payload gets past mscorlib (seeded writable Managed tmpfs) and renders
  # the loading screen, but ~90% of launches the main thread dies at the main-menu canvas build via a FEX
  # codegen bug — a wild write to a fixed address from FEX-translated guest code → recursive AV. Not fixable
  # at the propnix/wine/FEX-config layer; needs an upstream FEX fix. See the ksp-fex-blockers note. Native
  # x86_64 wine (no FEX) is unaffected, so the package still builds and runs there.
  brokenSystems = [ "aarch64-linux" ];
  brokenReason = "FEX codegen bug crashes the Unity/Mono menu build on aarch64 (renders loading screen, then dies); needs upstream FEX. Runs on native x86_64.";
}

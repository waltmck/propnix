# Prison Architect (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on
# x86_64 natively. ARCH-AGNOSTIC: this spec is identical on both hosts; makeAppWine + the scope pick the
# arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across
# arches. Payload = the pinned GOG Galaxy build fetched with gogdl (D15), delivered as the game tree
# directly (no InnoSetup). Prison Architect (Introversion) is a 2D management sim on a custom engine.
#
#   nix run .#prison-architect --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  tuning = (import ./tuning.nix) // {
    # PA statically imports the GOG Galaxy SDK + POPS client (its offline RPC init faults wine's rpcrt4);
    # stub all three (aarch64) via mount rows so the SDK never runs.
    galaxyStubDlls = [
      "Galaxy64.dll"
      "Galaxy.dll"
      "pops_api.dll"
    ];
  };
in
makeAppWine {
  pname = "prison-architect";
  appid = "prison-architect";
  name = "Prison Architect";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "prison-architect-win"; });
  exe = "Prison Architect64.exe";
  inherit tuning;
}

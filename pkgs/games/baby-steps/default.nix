# Baby Steps (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. ARCH-AGNOSTIC: identical on both hosts; makeAppWine + the scope pick the arch-appropriate
# emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across arches. Payload =
# the pinned GOG Galaxy build fetched with gogdl (D15), the game tree directly (no InnoSetup).
#
#   nix run .#baby-steps --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
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
  pname = "baby-steps";
  appid = "baby-steps";
  name = "Baby Steps";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "baby-steps-win"; });
  exe = "BabySteps.exe";
  inherit tuning;
}

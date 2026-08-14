# Outlast 2 (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Unreal Engine 3 survival-horror (Red Barrels; same studio + engine family as Outlast).
# ARCH-AGNOSTIC: the same spec runs on both hosts; makeAppWine + the scope pick the arch-appropriate
# emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across arches. Windows-only
# title (no native Linux build), so it follows the Outlast template. Payload = the pinned GOG Galaxy build
# fetched with gogdl (D15), delivered as the game tree directly (no InnoSetup).
#
#   nix run .#outlast-2 --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "outlast-2-win"; });
in
makeAppWine {
  pname = "outlast-2";
  appid = "outlast-2";
  name = "Outlast 2";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  inherit payload;
  # The single x86_64 UE3 game binary (goggame-*.info isPrimary FileTask; there is NO separate 32-bit launcher
  # stub in this build — Outlast2.bat just `start`s this exe). UE3 resolves content relative to the exe
  # location, and goggame declares workingDir Binaries/Win64; the propnix launcher runs from the payload root,
  # which UE3 handles fine. PE machine 0x8664 confirmed.
  exe = "Binaries/Win64/Outlast2.exe";
  tuning = import ./tuning.nix;
}

# Hollow Knight: Silksong (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC
# DXVK, on x86_64 natively. Team Cherry's Unity sequel to Hollow Knight; ARCH-AGNOSTIC like the HK spec:
# makeAppWine + the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a
# content-addressed FOD) is shared across arches. Payload = the pinned GOG Galaxy build fetched with gogdl
# (D15), delivered as the game tree directly (no InnoSetup).
#
#   nix run .#hollow-knight-silksong --extra-sandbox-paths /propnix=/var/tmp/propnix   # aarch64/x86_64-linux
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
  pname = "hollow-knight-silksong";
  appid = "hollow-knight-silksong";
  name = "Hollow Knight: Silksong";
  # gogdl takes the NUMERIC productId (not the slug).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "hollow-knight-silksong-win"; });
  exe = "Hollow Knight Silksong.exe";
  # Full-color icon is auto-extracted from the exe's PE resources (autoIcon defaults true) into a
  # freedesktop hicolor theme. The symbolic variant is vendored (CC BY-SA 4.0; see the .svg header).
  iconSymbolic = ./hollow-knight-silksong-symbolic.svg;
  inherit tuning;
}

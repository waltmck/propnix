# Hollow Knight (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on
# x86_64 natively. ARCH-AGNOSTIC: this spec is identical on both hosts; makeAppWine + the scope pick the
# arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across
# arches. The template for Windows-only titles (e.g. Baldur's Gate 3) that have no Linux build. Payload =
# the pinned GOG Galaxy build fetched with gogdl (D15), delivered as the game tree directly (no InnoSetup).
#
#   nix run .#hollow-knight --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  tuning = (import ./tuning.nix) // {
    # HK bundles the GOG Galaxy SDK in two spots (both statically imported); stub them (aarch64) via mount rows.
    galaxyStubDlls = [
      "Galaxy64.dll"
      "Hollow Knight_Data/Plugins/x86_64/Galaxy64.dll"
    ];
  };
in
makeAppWine {
  pname = "hollow-knight";
  appid = "hollow-knight";
  name = "Hollow Knight";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "hollow-knight-win"; });
  exe = "Hollow Knight.exe";
  # Full-color icon is auto-extracted from Hollow Knight.exe's PE resources (autoIcon defaults true) into a
  # freedesktop hicolor theme. The symbolic variant is vendored (CC BY-SA 4.0; see the .svg header).
  iconSymbolic = ./hollow-knight-symbolic.svg;
  inherit tuning;
}

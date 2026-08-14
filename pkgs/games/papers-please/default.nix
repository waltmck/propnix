# Papers, Please (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on
# x86_64 natively. ARCH-AGNOSTIC: identical on both hosts; makeAppWine + the scope pick the
# arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across
# arches. Papers, Please (1.4.x GOG) is a Unity IL2CPP title (GameAssembly.dll + UnityPlayer.dll,
# rendering D3D11 → DXVK → Vulkan; NOT the original custom engine, and NOT Mono — so no managed-assembly
# overlay issue). Payload = the pinned GOG Galaxy build fetched with gogdl (D15), the game tree directly.
#
#   nix run .#papers-please --extra-sandbox-paths /propnix=/var/tmp/propnix   # aarch64-linux or x86_64-linux
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
  pname = "papers-please";
  appid = "papers-please";
  name = "Papers, Please";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "papers-please-win"; });
  exe = "PapersPlease.exe";
  # (Fullscreen is forced via the persisted Unity PlayerPref in tuning.nix `userReg`, NOT a `-screen-fullscreen`
  # exe arg: the CLI arg is applied at startup but the game's own persisted setting then overrides it back to
  # windowed — a fullscreen window flashes and drops to windowed. Setting the pref itself leaves nothing to
  # revert to.)
  # Full-color icon is auto-extracted from the exe's PE resources (autoIcon defaults true) into a
  # freedesktop hicolor theme. The symbolic variant is vendored (CC BY-SA 4.0; see the .svg header).
  iconSymbolic = ./papers-please-symbolic.svg;
  inherit tuning;
}

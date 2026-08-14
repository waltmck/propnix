# No Man's Sky (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Hello Games' custom engine, Vulkan-first (also D3D11/12). ARCH-AGNOSTIC: the same spec runs on
# both hosts; makeAppWine + the scope pick the arch-appropriate emulator set, and the SAME Windows payload
# (a content-addressed FOD) is shared across arches. Windows-only title (no native Linux build), so it
# follows the Hollow Knight template. Payload = the pinned GOG Galaxy build fetched with gogdl (D15),
# delivered as the game tree directly (no InnoSetup).
#
#   nix run .#no-mans-sky --extra-sandbox-paths /propnix=/var/tmp/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  tuning = (import ./tuning.nix) // {
    # NMS.exe STATICALLY imports Galaxy64.dll (the GOG Galaxy SDK, bundled beside it in Binaries/ — confirmed
    # in the PE import table). Its offline RPC init faults wine's builtin rpcrt4 (null write to 0x10) before the
    # first frame (the Prison Architect / Hollow Knight failure mode), so bind the graceful no-op stub over it
    # (aarch64 only; x86_64 runs it under native wine). The DRM-free GOG build plays fully offline without it.
    galaxyStubDlls = [ "Binaries/Galaxy64.dll" ];
    # NB: NMS also imports MSVCP140/VCRUNTIME140(_1) (VC++ 2015-2022) — NOT staged via extraSystem32. Wine's
    # ARM64EC builtins for the modern VC140/UCRT runtime load cleanly under FEX (used by HK/Papers Please/
    # Silksong on this same stack); only the OLD VC++ 2010 msvcp100 builtin access-violates (the Outlast case).
  };
in
makeAppWine {
  pname = "no-mans-sky";
  appid = "no-mans-sky";
  name = "No Man's Sky";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "no-mans-sky-win"; });
  exe = "Binaries/NMS.exe";
  # Full-color icon is auto-extracted from the exe's PE resources (autoIcon defaults true) into a
  # freedesktop hicolor theme. The symbolic variant is vendored (CC BY-SA 4.0; see the .svg header).
  iconSymbolic = ./no-mans-sky-symbolic.svg;
  inherit tuning;
}

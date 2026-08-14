# Iron Lung (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Iron Lung (David Szymanski) is a tiny Unity submarine-horror title (D3D11 → DXVK → Vulkan).
# ARCH-AGNOSTIC: identical on both hosts; makeAppWine + the scope pick the arch-appropriate emulator set,
# and the SAME Windows payload (a content-addressed FOD) is shared across arches. Windows-only title (no
# native Linux build in the GOG Galaxy content system), so it follows the Hollow Knight template. Payload =
# the pinned GOG Galaxy build fetched with gogdl (D15), delivered as the game tree directly (no InnoSetup).
#
#   nix run .#iron-lung --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
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
  pname = "iron-lung";
  appid = "iron-lung";
  name = "Iron Lung";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "iron-lung-win"; });
  # Primary task from goggame-1310178756.info (isPrimary FileTask), x86_64 PE — the real Unity player, not a
  # launcher stub, so launched directly.
  exe = "Iron Lung.exe";
  # Full-color icon is auto-extracted from the exe's PE resources (autoIcon defaults true) into a
  # freedesktop hicolor theme.
  inherit tuning;

  # BROKEN on aarch64 (wine+FEX). With the per-title tuning in tuning.nix (writable-Managed mscorlib seed +
  # steam_api64 disabled + Galaxy stub) the Unity *Mono* engine initializes, DXVK creates a D3D11 swapchain
  # and PRESENTS its first frame — but at Unity's first-scene / menu construction a worker thread dies with a
  # FEX codegen ABORT (EXCEPTION_WINE_ASSERTION raised on FEX's alt-stack → "exception frame not in stack
  # limits" → process abort/zombie). Intermittent (crash 8-100 s in, or a frozen last frame) and INDEPENDENT
  # of every lever tried: graphics wayland|x11, d3d dxvk|wined3d, and thread stack size (the crashing thread
  # was given a full 8 MB stack and still aborts at the same FEX-JIT PC — so it is NOT a stack overflow). It
  # never renders menu content. This is the SAME FEX-2607-class codegen bug that blocks KSP at its menu-canvas
  # build; not fixable at the propnix/wine/FEX-config layer — needs an upstream FEX fix. Native x86_64 wine
  # (no FEX) is unaffected, and the tuning above is arch-agnostic, so the spec is kept intact and only BUILDING
  # on aarch64 is refused (the derivation still evaluates → discoverable + inspectable).
  brokenSystems = [ "aarch64-linux" ];
  brokenReason = "Unity Mono first-scene/menu build hits a FEX codegen abort after the first swapchain present (KSP-class FEX-2607 bug); mscorlib/steam/galaxy tuning gets it to present a frame but it never renders a menu. Needs an upstream FEX fix. Runs on native x86_64.";
}

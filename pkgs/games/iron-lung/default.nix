# Iron Lung (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Iron Lung (David Szymanski) is a tiny Unity submarine-horror title (D3D11 → DXVK → Vulkan).
# ARCH-AGNOSTIC: identical on both hosts; the wine backend + the scope pick the arch-appropriate emulator
# set, and the SAME Windows payload (a content-addressed FOD) is shared across arches. Windows-only title
# (no native Linux build in the GOG Galaxy content system), so it follows the Hollow Knight template.
# Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild (D15), delivered as the game tree directly (no
# InnoSetup).
#
#   nix run .#iron-lung --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
}:
mkApp (
  { config, lib, ... }:
  {
    pname = "iron-lung";
    appid = "iron-lung";
    name = "Iron Lung";
    # GOG-Windows only (no native Linux build in the GOG Galaxy content system).
    # the fetcher takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    # Primary task from goggame-1310178756.info (isPrimary FileTask), x86_64 PE — the real Unity player, not a
    # launcher stub. Full-color icon auto-extracted from its PE resources (icon.auto default).
    exe = "Iron Lung.exe";
    # BROKEN on aarch64 (wine+FEX): with the tuning below (writable-Managed mscorlib seed + steam_api64 disabled
    # + Galaxy stub) Unity Mono inits and DXVK presents its first frame, but at first-scene/menu construction a
    # worker thread dies with a FEX codegen ABORT (KSP-class FEX-2607 bug) — independent of graphics/d3d/stack
    # levers. Needs an upstream FEX fix; native x86_64 wine is unaffected, so only BUILDING on aarch64 is refused.
    broken.systems = [ "aarch64-linux" ];
    broken.reason = "Unity Mono first-scene/menu build hits a FEX codegen abort after the first swapchain present (KSP-class FEX-2607 bug); mscorlib/steam/galaxy tuning gets it to present a frame but it never renders a menu. Needs an upstream FEX fix. Runs on native x86_64.";

    # Save: Iron Lung is a Unity title, so persistent data (settings + Player.log) go to Unity's LocalLow
    # persistentDataPath HKCU\...\AppData\LocalLow\<company>\<product>. Company/product confirmed from the
    # payload's Unity data folder (Iron Lung_Data/app.info) — "David Szymanski"/"Iron Lung". Bound out of the
    # rebuildable prefix to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default
    # $XDG_DATA_HOME/propnix-saves/iron-lung).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/LocalLow/David Szymanski/Iron Lung";
      }
    ];

    # function-tuning: wine-tuning.nix is a FUNCTION of `payload` (the Managed-assemblies seed references
    # the payload's store path directly), applied here to the payload store path.
    wine = (import ./wine-tuning.nix) { payload = lib.head config.payloads; };
  }
)

# Outlast 2 (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Unreal Engine 3 survival-horror (Red Barrels; same studio + engine family as Outlast), renders
# D3D11 → native ARM64EC DXVK → Vulkan. ARCH-AGNOSTIC: the same spec runs on both hosts; the wine backend +
# the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD)
# is shared across arches. Windows-only title (no native Linux build), so it follows the Outlast template.
# Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild (D15), delivered as the game tree directly (no
# InnoSetup).
#
# Stock wine defaults (graphics=wayland, d3d=dxvk). It imports the VC++ 2015+ runtime
# (MSVCP140/VCRUNTIME140), whose wine ARM64EC builtins load cleanly under FEX, so unlike Outlast it
# needs no `extraSystem32`. It needs no Galaxy SDK stub either: offline is enforced by
# `online = false`. Only the save bind is game-specific. The repeated "Clamping massive framebuffer"
# driver log on Asahi is cosmetic (docs/research/honeykrisp-occlusion-query-cap.md).
#
#   nix run .#outlast-2 --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
}:
mkApp {
  pname = "outlast-2";
  maintainers = [ "waltmck" ];
  appid = "outlast-2";
  name = "Outlast 2";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
  # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
  # because this game is single-player, same engine family as Outlast: its only matchmaking symbols are UE3
  # class boilerplate (`UOnlineMatchmakingStats`), not a multiplayer mode.
  online = false;
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  # The single x86_64 UE3 game binary (goggame-*.info isPrimary FileTask; no separate 32-bit launcher stub —
  # Outlast2.bat just `start`s this exe). UE3 resolves content relative to the exe location, so cwd = payload
  # root is fine (PE machine 0x8664).
  exe = "Binaries/Win64/Outlast2.exe";

  # Save: UE3 (shipping) redirects user config + saves + logs to Documents\My Games\Outlast2 (the
  # game writes OLGame\Config\OL*.ini + saves there). Bind the whole folder so saves + settings
  # travel together, out to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default
  # …/propnix-saves/outlast-2).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Documents/My Games/Outlast2";
    }
  ];
}

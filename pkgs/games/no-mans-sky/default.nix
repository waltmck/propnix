# No Man's Sky (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Hello Games' custom engine, Vulkan-first (also D3D11/12; renders through winevulkan → host
# Vulkan directly), so the global wine defaults (d3d=dxvk, graphics=wayland) are left in place. ARCH-
# AGNOSTIC: the same spec runs on both hosts; the wine backend + the scope pick the arch-appropriate
# emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across arches. Windows-only
# title (no native Linux build), so it follows the Hollow Knight template. Payload = the pinned GOG Galaxy
# build fetched by fetchGogGalaxyBuild (D15), delivered as the game tree directly (no InnoSetup).
#
#   nix run .#no-mans-sky --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
}:
mkApp (
  { config, lib, ... }:
  {
    pname = "no-mans-sky";
    maintainers = [ "waltmck" ];
    appid = "no-mans-sky";
    name = "No Man's Sky";
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    exe = "Binaries/NMS.exe";
    # Full-color icon auto-extracted from the exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
    icon.symbolic = ./no-mans-sky-symbolic.svg;

    # HDR. NMS renders through winevulkan directly, but like most Windows titles it asks DXGI whether the
    # display is HDR-capable — and wine never reports HDR (winewayland writes no EDID into the registry, so
    # DXVK's dxgi has nothing to auto-detect from). DXVK_HDR=1 is DXVK-dxgi's stand-in for the Windows
    # "HDR on" toggle (d3d=dxvk installs its dxgi on this backend even though the renderer is Vulkan);
    # with it set, NMS offers/enables HDR and creates an HDR10 Vulkan swapchain via mesa's Wayland color
    # management. Safe on SDR sessions: the Vulkan surface offers no HDR10 colorspace there, so the
    # game stays SDR.
    env.DXVK_HDR = "1";

    # Plays on aarch64. Occlusion culling is dead on stock Honeykrisp and shows as flicker: NMS asks
    # for 262144 occlusion queries, eight times the driver's 32768-slot table, and the failed pools
    # fault on every use. Workaround: a mesa with the table raised, selected per-app through
    # VK_DRIVER_FILES (recipe in docs/research/honeykrisp-occlusion-query-cap.md).

    # Save: NMS writes its local save + settings under AppData/Roaming/HelloGames/NMS (the GOG local-save
    # location, from the payload's goggame-*.script savePath). Bound to the app's host save dir
    # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/no-mans-sky).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/Roaming/HelloGames/NMS";
      }
    ];

    wine = {
      # NMS.exe STATICALLY imports Galaxy64.dll (the GOG Galaxy SDK, bundled in Binaries/), so the
      # no-op stub is bound over it on every arch — offline policy, see emulators/galaxy-stub.
      galaxyStubDlls = [ "Binaries/Galaxy64.dll" ];

      # NMS WRITES INSIDE ITS OWN INSTALL DIR: graphics init creates GAMEDATA/SHADERCACHE there,
      # which the default READ-ONLY `drive_c/game` bind refuses, and the failure path takes the
      # engine down. A PERSISTENT COW OVERLAY (as KSP): reads come straight from the store payload
      # (the 28 GB of .pak files stay shared) and the shader cache persists to app state. The
      # payload is only 155 files, so the data-only skeleton is tiny
      # (docs/research/writable-game-dir.md).
      mounts."drive_c/game" = {
        type = "overlay";
        lower = "${lib.head config.payloads}";
        upper = "$PROPNIX_STATE/gamedir";
        createIfNotExist = true;
      };
    };
  }
)

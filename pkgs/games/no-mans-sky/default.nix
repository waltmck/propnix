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
    appid = "no-mans-sky";
    name = "No Man's Sky";
    # the fetcher takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    exe = "Binaries/NMS.exe";
    # Full-color icon auto-extracted from the exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
    icon.symbolic = ./no-mans-sky-symbolic.svg;

    # HDR. NMS renders through winevulkan directly, but like most Windows titles it asks DXGI whether the
    # display is HDR-capable — and wine never reports HDR (winewayland writes no EDID into the registry, so
    # DXVK's dxgi has nothing to auto-detect from). DXVK_HDR=1 is DXVK-dxgi's stand-in for the Windows
    # "HDR on" toggle (d3d=dxvk installs its dxgi on this backend even though the renderer is Vulkan);
    # with it set, NMS offers/enables HDR and creates an HDR10 Vulkan swapchain via mesa's Wayland color
    # management. VERIFIED on x86_64 (Hyprland HDR session): this alone makes HDR work. Safe on SDR
    # sessions: the Vulkan surface offers no HDR10 colorspace there, so the game stays SDR.
    env.DXVK_HDR = "1";

    # PLAYS on aarch64 (title screen, load-in, walking around), with ONE outstanding rendering defect that
    # belongs to the GPU driver, not to this package or the emulation stack.
    #
    # THE DEFECT — occlusion query pools exceed what Honeykrisp can back. NMS asks for FOUR 65536-entry
    # VK_QUERY_TYPE_OCCLUSION pools (262144 queries). hk_CreateQueryPool eagerly reserves one HARDWARE occlusion
    # slot per query in the pool, from a device-wide table of AGX_MAX_OCCLUSION_QUERIES = 32768 (mesa
    # src/asahi/lib/agx_helpers.h; 32768 because the AGX per-draw "Fragment occlusion query" packet field is 15
    # bits — src/asahi/genxml/cmdbuf.xml), so every pool fails with VK_ERROR_OUT_OF_DEVICE_MEMORY
    # (hk_query_pool.c:309). NMS does not check the result and goes on using the unwritten handle, so the driver
    # NULL-derefs on each use; wine catches the unix-side SIGSEGV and turns it into STATUS_ACCESS_VIOLATION
    # returned from the syscall (`trace:seh:handle_syscall_fault`) rather than a crash. The game therefore runs
    # but its occlusion culling is dead, which shows up as MAJOR FLICKERING. Measured over one boot-to-gameplay
    # run: 12762 such faults on the stock driver vs 0 with the table raised.
    #
    # To make NMS use a patched mesa to work on Honeykrisp, you can try (on NixOS)
    #
    # no-mans-sky.apply {
    #   env.VK_DRIVER_FILES = "${pkgs.mesa.overrideAttrs (old: {
    #     postPatch =
    #       (old.postPatch or "")
    #       + ''
    #         substituteInPlace src/asahi/lib/agx_helpers.h \
    #         --replace-fail "#define AGX_MAX_OCCLUSION_QUERIES (32768)" \
    #                        "#define AGX_MAX_OCCLUSION_QUERIES (1048576)"
    #       '';
    #   })}/share/vulkan/icd.d/asahi_icd.aarch64.json";
    # }
    #
    # NOTHING about this is page-size, FEX, wine, ARM64EC, DXVK, Streamline or XeSS related. The cap is a
    # compile-time constant, identical in every mesa 24.3 → 26.1 and in Asahi's own fork, so a 4K-page muvm
    # guest — same Honeykrisp, same GPU — hits the same wall; muvm is not a workaround. No other mesa Vulkan
    # driver has any occlusion-query cap at all: AMD/Intel/NVIDIA/Adreno program a full 64-bit result address
    # per query instead of an index into one device-global table, so their only limit is memory. The upstream
    # fix is to allocate hardware slots lazily per submission (the 15-bit index is relative to a per-submit
    # `isp_oclqry_base`, so a pool bigger than the window is representable); simply raising the constant cannot
    # be right in general, since NMS alone wants 4× the addressable range.
    #
    # Until that lands, correct rendering needs a Honeykrisp whose table covers the request, selected per-app:
    #   VK_DRIVER_FILES=<patched-mesa>/share/vulkan/icd.d/asahi_icd.aarch64.json nix run .#no-mans-sky
    # (a mesa built with AGX_MAX_OCCLUSION_QUERIES raised; the slots above 32768 alias in hardware because the
    # packet field truncates, which is memory-safe — the write stays inside the table.)

    # Save: NMS writes its local save + settings under AppData/Roaming/HelloGames/NMS (the GOG local-save
    # location; confirmed from the payload's goggame-*.script savePath). Bound to the app's host save dir
    # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/no-mans-sky).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/Roaming/HelloGames/NMS";
      }
    ];

    wine = {
      # NMS.exe STATICALLY imports Galaxy64.dll (the GOG Galaxy SDK, bundled beside it in Binaries/ —
      # confirmed in the PE import table), so bind the no-op stub over it (aarch64 only; x86_64 runs it under
      # native wine). The DRM-free GOG build plays fully offline without the SDK, which is exactly the
      # guarantee propnix wants — see emulators/galaxy-stub for the policy.
      galaxyStubDlls = [ "Binaries/Galaxy64.dll" ];
      # NB: NMS also imports MSVCP140/VCRUNTIME140(_1) (VC++ 2015-2022) — NOT staged via extraSystem32. Wine's
      # ARM64EC builtins for the modern VC140/UCRT runtime load cleanly under FEX (used by HK/Papers Please/

      # Silksong on this same stack); only the OLD VC++ 2010 msvcp100 builtin access-violates (the Outlast case).

      # NMS WRITES INSIDE ITS OWN INSTALL DIR: at the end of graphics init cGcGraphicsManager::Prepare calls
      # std::filesystem::create_directories on GAMEDATA/SHADERCACHE (traced: `CreateDirectoryW
      # L"C:/GAME/GAMEDATA/SHADERCACHE"` is the last file op before the crash). The default `drive_c/game` row
      # is a READ-ONLY bind of the payload, so that mkdir cannot succeed and the failure path takes the engine
      # down. Override it with a PERSISTENT COW OVERLAY, exactly as KSP does: reads come straight from the store
      # payload (no copy — the 28 GB of .pak files stay shared), and the shader cache persists to app state.
      # Cheap here: the whole payload is only 155 files, so the data-only skeleton is tiny.
      mounts."drive_c/game" = {
        type = "overlay";
        lower = "${lib.head config.payloads}";
        upper = "$PROPNIX_STATE/gamedir";
        createIfNotExist = true;
      };
    };
  }
)

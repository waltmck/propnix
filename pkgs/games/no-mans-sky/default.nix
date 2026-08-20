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
mkApp {
  pname = "no-mans-sky";
  appid = "no-mans-sky";
  name = "No Man's Sky";
  # the fetcher takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "Binaries/NMS.exe";
  # Full-color icon auto-extracted from the exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
  icon.symbolic = ./no-mans-sky-symbolic.svg;

  # Broken on aarch64 (runtime-diagnosed): NMS reaches graphics init — DXVK 2.7.1 inits, picks the Apple M2
  # (Honeykrisp) Vulkan device, loads its Streamline/XeSS upscaling middleware — then the engine's OWN crash
  # reporter fires a Win32 dialog and self-aborts with a "GX" crash code. `+seh` proves it is NOT a CPU fault
  # (no c0000005 / handle_syscall_fault) and NOT the winevulkan swapchain NULL-deref (Skyrim) nor a FEX
  # CPU-fault (KSP wild-write / Stellaris stack-overflow): a Vulkan/upscaler-capability mismatch against the
  # Honeykrisp driver in NMS's own engine init. Tested on BOTH winewayland (oversized-window white hang) and
  # x11 (correctly-sized window → GX self-abort) — neither renders. Needs deeper AAA-engine-specific graphics
  # work. Native x86_64 (standard Vulkan driver) is unaffected.
  broken.systems = [ "aarch64-linux" ];
  broken.reason = "NMS's own engine crash reporter self-aborts during graphics init on aarch64 (a \"GX\" Vulkan/upscaler-capability crash against the Asahi Honeykrisp driver — not a FEX CPU fault, not the winevulkan swapchain NULL-deref); neither winewayland nor x11 renders. Needs AAA-engine-specific graphics work. Runs on native x86_64.";

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
    # NMS.exe STATICALLY imports Galaxy64.dll (the GOG Galaxy SDK, bundled beside it in Binaries/ — confirmed
    # in the PE import table). Its offline RPC init faults wine's builtin rpcrt4 (null write to 0x10) before the
    # first frame (the Prison Architect / Hollow Knight failure mode), so bind the graceful no-op stub over it
    # (aarch64 only; x86_64 runs it under native wine). The DRM-free GOG build plays fully offline without it.
    galaxyStubDlls = [ "Binaries/Galaxy64.dll" ];
    # NB: NMS also imports MSVCP140/VCRUNTIME140(_1) (VC++ 2015-2022) — NOT staged via extraSystem32. Wine's
    # ARM64EC builtins for the modern VC140/UCRT runtime load cleanly under FEX (used by HK/Papers Please/
    # Silksong on this same stack); only the OLD VC++ 2010 msvcp100 builtin access-violates (the Outlast case).
  };
}

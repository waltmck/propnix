# Cyberpunk 2077 (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK/vkd3d,
# on x86_64 natively. CD Projekt Red's REDengine 4, a D3D12-ONLY renderer (see below), so D3D goes
# game → vkd3d-proton (d3d12) → DXVK's dxgi (presentation) → Vulkan. ARCH-AGNOSTIC: this spec is
# identical on both hosts; mkApp + the scope pick the arch-appropriate emulator set, and the SAME
# Windows payload (a content-addressed FOD) is shared across arches. Windows-only title (CDPR ships
# no Linux build), so the payload is the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild
# (D15) — the game tree directly, no InnoSetup.
#
#   nix run .#cyberpunk-2077 --extra-sandbox-paths /propnix=/var/lib/propnix  # base game
#   nix run '.#cyberpunk-2077.withDlc [ "phantom-liberty" ]'                    # + the expansion
#
# Launch bin/x64/Cyberpunk2077.exe directly (launcher-configuration.json's executablePath).
# REDprelauncher.exe only installs and runs the 687 MB REDlauncher MSI, which spawns this exe and
# exits, tripping the launcher's primary-child teardown
# (docs/research/publisher-launcher-bypass.md).
#
# One game binary. It loads D3D12 dynamically (bundled d3d12on7, Agility SDK D3D12Core.dll), so the
# renderer is vkd3d-proton.
#
# cwd = payload root: the GOG play task declares no workingDir, and REDengine resolves archive/,
# r6/, engine/ from it.
#
# Run record: docs/verified/cyberpunk-2077-win.json. Hang diagnosis on this title (`+winsock`, the
# watchdog minidump): docs/research/wine-hang-diagnosis.md.
{
  lib,
  mkApp,
  fetchGogGalaxyBuild,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp {
  pname = "cyberpunk-2077";
  maintainers = [ "waltmck" ];
  appid = "cyberpunk-2077";
  name = "Cyberpunk 2077";

  fetchInfo = versions.fetchInfo;
  exe = "bin/x64/Cyberpunk2077.exe";

  # Single-player. The netns holds the marketing/telemetry endpoint and both GOG SDK copies to
  # loopback; the exe's Multiplayer strings are scaffolding from the cancelled mode.
  online = false;

  # DXVK_HDR=1 is the D3D12 knob too: vkd3d-proton has no dxgi and presents through DXVK's dxgi
  # (IDXGIVkSwapChainFactory), the DLL that reads DXVK_HDR. Needed because winewayland exposes no
  # EDID, so DXVK never detects HDR itself. SDR surfaces stay sRGB. Open questions are in
  # docs/research/dxvk-hdr-under-winewayland.md.
  env.DXVK_HDR = "1";

  # Full-colour icon auto-extracted from Cyberpunk2077.exe's PE resources (icon.auto default).

  # REDengine writes saves and UserSettings.json under the Saved Games known folder, in
  # `CD Projekt Red\Cyberpunk 2077`, bound whole.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Saved Games/CD Projekt Red/Cyberpunk 2077";
    }
  ];

  # ── DLC ── GOG DLC are dlcId depots of the same build (each row is fetchGogGalaxyBuild with
  # `dlcId`), unioned read-only above the base payload; all are pure unions (no base file shadowed).
  #   * phantom-liberty — the expansion; whether it needs a Galaxy entitlement too is unknown.
  #   * redmod — the modding toolkit only, not content. Modding is not wired: it needs REDlauncher's
  #     modded flag in exeArgs and a writable r6/cache/modded/, i.e. a persistent CoW `drive_c/game`
  #     overlay that also carries the DLC lowers (docs/research/writable-game-dir.md).
  # Not in the base package: `.withDlc [ "phantom-liberty" ]` / `.withAllDlc` select.
  dlc.available = lib.mapAttrs (_: fetchGogGalaxyBuild) versions.dlc;

  wine = {
    # REDGalaxy64.dll (static import) is CDPR's `redgalaxy`-namespace SDK; the stub exports only
    # `galaxy::`, so it cannot be stubbed (a redgalaxy variant in emulators/galaxy-stub is the fix).
    # Galaxy64.dll's only importer is GameServicesGOG.dll, whose 10 imports the stub covers.
    # `online = false` enforces offline for both: connect fails fast, though DNS still resolves via
    # the host resolver socket. Masking GameServicesGOG.dll removes a DLL, not the GOG stack. Import
    # graph and stub evidence: docs/research/galaxy-sdk-offline.md.
    galaxyStubDlls = [ "bin/x64/Galaxy64.dll" ];

    # No `extraSystem32`: the exe and REDGalaxy64.dll link the CRT statically, and
    # GameServicesGOG.dll's VC140 imports load from wine's builtins (ARM64EC under FEX included).
  };
}

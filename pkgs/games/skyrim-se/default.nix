# The Elder Scrolls V: Skyrim Special Edition (GOG, Windows build) via wine — on aarch64 through FEX +
# native ARM64EC DXVK, on x86_64 natively. Bethesda Creation Engine (the 64-bit "Special Edition" remaster),
# renders D3D11 → DXVK → Vulkan. ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope
# pick the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared
# across arches. Windows-only title (no native Linux build). Payload = the pinned GOG Galaxy build fetched
# with gogdl (D15), delivered as the game tree directly (no InnoSetup).
#
# The Creation Engine needs SkyrimPrefs.ini's `iSize` to equal the actual display resolution for correct
# fullscreen (it renders its backbuffer at iSize even in fullscreen — see setup.sh). We launch SkyrimSE.exe
# directly (bypassing SkyrimSELauncher.exe, which normally writes the resolution + a quality preset), so we
# supply a `setupScript` (setup.sh) that the launcher runs before wine: it seeds SkyrimPrefs.ini's iSize from
# the compositor-derived PROPNIX_WIDTH/HEIGHT facts + the chosen PROPNIX_QUALITY preset.
#
#   nix run .#skyrim-se --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  mkSetupScript,
  presets,
}:
mkApp {
  pname = "skyrim-se";
  appid = "skyrim-se";
  name = "Skyrim Special Edition";
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  # Launch the actual x86_64 game exe DIRECTLY, NOT the isPrimary SkyrimSELauncher.exe (a 32-bit settings stub
  # that spawns SkyrimSE.exe and exits → trips the propnix launcher's primary-child teardown). SkyrimSE.exe is
  # the 64-bit Creation Engine binary; it resolves Data/, *.ini, and the game root relative to its own location,
  # so cwd = payload root is fine.
  exe = "SkyrimSE.exe";
  # Full-color icon auto-extracted from SkyrimSE.exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
  # VC++ runtime (MSVCP140/VCRUNTIME140) loads on wine's ARM64EC UCRT builtins under FEX (no extraSystem32 needed).
  icon.symbolic = ./skyrim-se-symbolic.svg;

  # Save: the Creation Engine writes saves + Skyrim.ini/SkyrimPrefs.ini under
  # Documents\My Games\Skyrim Special Edition GOG — this GOG build uses the " GOG"-suffixed folder (verified
  # via a +file trace: SkyrimSE.exe reads/writes exactly that path), NOT the Steam "Skyrim Special Edition".
  # The earlier (Steam) name silently dropped saves + hid config. Bind the whole folder (saves + .ini
  # config together) out to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Documents/My Games/Skyrim Special Edition GOG";
    }
  ];

  wine = presets.mergeTuning [
    (import ./wine-tuning.nix)
    {
      # Run setup.sh before wine: seed SkyrimPrefs.ini display (iSize/fullscreen) + the PROPNIX_QUALITY
      # preset. setup.sh uses the shared `ini_set` (withIniLib) at its plain-LF `key=value` defaults.
      setupScript = mkSetupScript {
        name = "skyrim-se-setup";
        script = ./setup.sh;
        withIniLib = true;
      };
      # SkyrimSE.exe STATICALLY imports the GOG Galaxy SDK (Galaxy64.dll, at the payload root — verified via the
      # PE import table); its offline RPC init faults wine's builtin rpcrt4 before the first frame, so bind the
      # graceful no-op stub over it (aarch64) via a mount row (same de-Galaxy pattern as HK / Prison Architect;
      # a no-op on x86_64 native wine).
      galaxyStubDlls = [ "Galaxy64.dll" ];
    }
  ];
}

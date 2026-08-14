# The Elder Scrolls V: Skyrim Special Edition (GOG, Windows build) via wine — on aarch64 through FEX +
# native ARM64EC DXVK, on x86_64 natively. Bethesda Creation Engine (the 64-bit "Special Edition" remaster),
# renders D3D11 → DXVK → Vulkan. ARCH-AGNOSTIC: this spec is identical on both hosts; makeAppWine + the
# scope pick the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is
# shared across arches. Windows-only title (no native Linux build). Payload = the pinned GOG Galaxy build
# fetched with gogdl (D15), delivered as the game tree directly (no InnoSetup).
#
# The Creation Engine needs SkyrimPrefs.ini's `iSize` to equal the actual display resolution for correct
# fullscreen (it renders its backbuffer at iSize even in fullscreen — see tuning.nix). We launch SkyrimSE.exe
# directly (bypassing SkyrimSELauncher.exe, which normally writes the resolution + a quality preset), so we
# supply a `setupScript` (setup.sh) that the launcher runs before wine: it seeds SkyrimPrefs.ini's iSize from
# the compositor-derived PROPNIX_WIDTH/HEIGHT facts + the chosen PROPNIX_QUALITY preset. The game builds the
# script here with `writeShellScript` (its own toolset + `set -euo pipefail`); makeAppWine just runs the path.
#
#   nix run .#skyrim-se --extra-sandbox-paths /propnix=/var/tmp/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
  writeShellScript,
  coreutils,
  gnused,
  gawk,
  gnugrep,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  tuning = (import ./tuning.nix) // {
    # Run setup.sh before wine: seed SkyrimPrefs.ini display (iSize/fullscreen) + the PROPNIX_QUALITY preset
    # (`setup` is defined below — `let` is recursive).
    setupScript = setup;
    # SkyrimSE.exe STATICALLY imports the GOG Galaxy SDK (Galaxy64.dll, at the payload root — verified via the
    # PE import table); its offline RPC init faults wine's builtin rpcrt4 before the first frame, so bind the
    # graceful no-op stub over it (aarch64) via a mount row (same de-Galaxy pattern as HK / Prison Architect;
    # a no-op on x86_64 native wine).
    galaxyStubDlls = [ "Galaxy64.dll" ];
  };
  # The setup script the launcher runs before wine (see setup.sh). Wrapped here so the game controls its own
  # toolset + failure semantics: `set -euo pipefail` (a mid-script error aborts → the launcher aborts) + a
  # fixed coreutils/sed/awk/grep PATH (hermetic, independent of the caller's env).
  setup = writeShellScript "skyrim-se-setup" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ coreutils gnused gawk gnugrep ]}:$PATH
    ${builtins.readFile ./setup.sh}
  '';
in
makeAppWine {
  pname = "skyrim-se";
  appid = "skyrim-se";
  name = "Skyrim Special Edition";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "skyrim-se-win"; });
  # Launch the actual x86_64 game exe DIRECTLY, NOT the isPrimary SkyrimSELauncher.exe. SkyrimSELauncher.exe
  # is a 32-bit settings/launch stub that reads Skyrim*.ini, then SPAWNS SkyrimSE.exe and EXITS — the propnix
  # launcher waits on its primary child, so the stub exiting would trigger prefix teardown while the real game
  # is still starting (the same launcher-stub pattern as Outlast's OutlastLauncher.exe). SkyrimSE.exe is the
  # 64-bit Creation Engine game binary our aarch64 wine+FEX path targets; it resolves Data/, *.ini, and the
  # game root relative to its own location, so cwd = payload root is fine.
  exe = "SkyrimSE.exe";
  # Full-color icon is auto-extracted from SkyrimSE.exe's PE resources (autoIcon defaults true) into a
  # freedesktop hicolor theme. The symbolic variant is vendored (CC BY-SA 4.0; see the .svg header).
  iconSymbolic = ./skyrim-se-symbolic.svg;
  inherit tuning;
  # VC++ runtime: SkyrimSE.exe imports MSVCP140.dll + VCRUNTIME140.dll (MSVC 2015-2019 / UCRT). This GOG
  # build ships no vcredist in the tree, but wine's ARM64EC UCRT-era builtins load + init these cleanly under
  # FEX (verified: they reach PROCESS_DETACH, no loader_init failure) — unlike Outlast's older msvcp100
  # (whose builtin DllMain faults) — so no `extraSystem32` is needed (tuning default {}).
}

# Factorio (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Wube Software's factory-automation sim on its own engine (D3D/OpenGL). ARCH-AGNOSTIC: the same
# spec runs on both hosts; makeAppWine + the scope pick the arch-appropriate emulator set, and the SAME
# Windows payload (a content-addressed FOD) is shared across arches. GOG's Galaxy content-system has NO Linux
# build for Factorio (Windows + Mac only), so like the other titles we package the Windows build via wine.
# Payload = the pinned GOG Galaxy build fetched with gogdl (D15), delivered as the game tree directly.
#
#   nix run .#factorio --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
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
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "factorio-win"; });
  # DLC — defined inline (no separate file). Each entry is a DLC-only FOD: the SAME base build fetched with a
  # `dlcId`, yielding just that DLC's game-relative overlay tree (e.g. `data/space-age/…`), no base exe. It is
  # NOT part of the base package: `factorio` ships vanilla; `factorio.withDlc (dlc: [ dlc.space-age ])` (or
  # `factorio.withAllDlc`) flips the game mount to a read-only overlay unioning base + selected DLC at runtime
  # — so an enabled DLC costs no second copy of the base payload in the store. Space Age (GOG DLC 1831417704)
  # is Wube's 2.0 expansion (space platforms, new planets, quality/elevated-rails); requires the base game.
  dlc = {
    space-age = fetchGogGalaxyBuild (pins.components.space-age // { pname = "factorio-space-age-win"; });
  };
  # Run setup.sh before wine: assert `[other] check-updates=false` in config.ini so Factorio's in-game
  # auto-update check is off by default (moot for a read-only store payload — see setup.sh). Factorio keeps
  # this in config.ini, NOT the registry, so a `userReg` entry cannot express it. Wrapped here so the game
  # controls its own toolset + failure semantics: `set -euo pipefail` (a mid-script error aborts → the launcher
  # aborts) + a fixed coreutils/sed/awk/grep PATH (hermetic, independent of the caller's env).
  setup = writeShellScript "factorio-setup" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ coreutils gnused gawk gnugrep ]}:$PATH
    ${builtins.readFile ./setup.sh}
  '';
in
makeAppWine {
  pname = "factorio";
  appid = "factorio";
  name = "Factorio";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  inherit payload;
  # The 64-bit game binary (goggame-*.info isPrimary FileTask, PE32+ x86-64). Factorio resolves read-data +
  # its %APPDATA%\Factorio write dir from the EXECUTABLE location (via GetModuleFileName → bin/x64/../..),
  # NOT the cwd, so no `workingDir` is needed (goggame declares workingDir=bin/x64, but VERIFIED: launching
  # with cwd = payload root renders in-game fine). No Galaxy SDK in the tree (no galaxyStubDlls), and the
  # modern VC++/UCRT runtime loads on wine's ARM64EC builtins under FEX (no extraSystem32).
  exe = "bin/x64/factorio.exe";
  # Full-color icon: factorio.exe's PE resources top out at 48px (pixelated upscaled) AND the high-res game
  # asset is off-centre in its canvas, so use the 1024px icon Wube ships in the game data via `iconPng` —
  # mkAppIcon autocrops + recentres it into a crisp, centred hicolor theme + splash png. The symbolic variant
  # is a vendored gear (Font Awesome 6 Solid, CC BY 4.0 — attribution in the .svg header).
  iconPng = "${payload}/data/core/graphics/factorio.icon/Assets/factorio.png";
  iconSymbolic = ./factorio-symbolic.svg;
  # `setup` is defined above (recursive `let`); merged into tuning so the launcher runs it pre-wine.
  tuning = (import ./tuning.nix) // {
    setupScript = setup;
  };
  # Inline DLC set (above). makeAppWine exposes `factorio.dlc`, `factorio.withDlc (dlc: […])`, and
  # `factorio.withAllDlc`; the base package here ships no DLC (empty `enabledDlc`).
  inherit dlc;
}

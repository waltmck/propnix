# Fallout: New Vegas Ultimate Edition (GOG, Windows build) via wine — on aarch64 through box64 + wined3d, on
# x86_64 natively. Obsidian/Bethesda 2010 title on the Gamebryo/NetImmerse engine (Direct3D 9). ARCH-AGNOSTIC
# spec: makeAppWine + the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a
# content-addressed FOD) is shared across arches. Windows-only title. Payload = the pinned GOG Galaxy build
# fetched with gogdl (D15), delivered as the game tree directly (no InnoSetup).
#
# THE 32-BIT STRETCH (SOLVED — renders on aarch64): FalloutNV.exe is a 32-bit (i386) PE — unlike every other
# title in the suite, which is x86_64. On aarch64 it runs the WoW64 path: wine's i386 PE builtins under box64's
# wowbox64.dll (the i386 CPU emulator, Hangover's hardcoded default for i386-on-ARM64 — see
# wine-prefix-lower.nix), with the i386 syswow64 tree staged there too (this Hangover ARM64EC wine's
# `wineboot -u` never creates it). The native ARM64EC DXVK cannot service an i386 guest, so D3D9 goes through
# wine's builtin wined3d → OpenGL on the Apple M2 (Asahi Mesa). Shared 32-bit enabler with Don't Starve.
#
# TWO per-game fixes make it render (both required; NO emulator/wine patch needed):
#   1. setupScript (setup.sh) seeds Documents\My Games\FalloutNV\FalloutPrefs.ini. Launched directly, the
#      Gamebryo engine finds NO FalloutPrefs.ini and BOUNCES — it spawns FalloutNVLauncher.exe and exits
#      (diagnosed via +file: its last act is a PATH search for FalloutNVLauncher.exe). A seeded FalloutPrefs.ini
#      with a [Launcher] section + valid [Display] makes the engine proceed to device creation itself.
#   2. tuning.userReg spoofs wined3d's reported PCI vendor to a recognized card (NVIDIA GTX 660) — on Asahi
#      wined3d reports VendorId 0xffff, and FNV refuses CreateDevice on an unidentified adapter. wined3d honors
#      the HKCU\Software\Wine\Direct3D override natively (no patch). See tuning.nix.
# With both, FalloutNV.exe creates its D3D9 device and renders the intro (Bethesda logo) → main menu.
#
#   nix run .#fallout-nv --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
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
    # Run setup.sh before wine to seed FalloutPrefs.ini (+ Fallout.ini) — see the fix (1) note above.
    setupScript = setup;
  };
  # The setup script the launcher runs before wine (see setup.sh). Wrapped here so the game controls its own
  # toolset + failure semantics: `set -euo pipefail` + a fixed coreutils/sed/awk/grep PATH (hermetic).
  setup = writeShellScript "fallout-nv-setup" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ coreutils gnused gawk gnugrep ]}:$PATH
    ${builtins.readFile ./setup.sh}
  '';
in
makeAppWine {
  pname = "fallout-nv";
  appid = "fallout-nv";
  name = "Fallout: New Vegas";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "fallout-nv-win"; });
  # Launch the actual game exe DIRECTLY, NOT the isPrimary FalloutNVLauncher.exe. The Launcher is a settings
  # stub that spawns the game and exits — the propnix launcher waits on its primary child, so the stub exiting
  # would trigger prefix teardown while the game is still starting (same launcher-stub pattern as Outlast /
  # Skyrim SE). FalloutNV.exe is the Gamebryo game binary; it resolves Data/, *.ini relative to its own
  # location, so cwd = payload root (C:\game) is correct. (The setupScript pre-seeds FalloutPrefs.ini so the
  # engine does not itself bounce to FalloutNVLauncher.exe — see the header + setup.sh.)
  exe = "FalloutNV.exe";
  inherit tuning;
}

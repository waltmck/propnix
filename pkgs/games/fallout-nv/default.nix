# Fallout: New Vegas Ultimate Edition (GOG, Windows build) via wine — on aarch64 through box64 + wined3d, on
# x86_64 natively. Obsidian/Bethesda 2010 title on the Gamebryo/NetImmerse engine (Direct3D 9). ARCH-AGNOSTIC
# spec: the wine backend + the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a
# content-addressed FOD) is shared across arches. Windows-only title. Payload = the pinned GOG Galaxy build
# fetched by fetchGogGalaxyBuild (D15), delivered as the game tree directly (no InnoSetup).
#
# THE 32-BIT STRETCH (SOLVED — renders on aarch64): FalloutNV.exe is a 32-bit (i386) PE — unlike every other
# title in the suite, which is x86_64. On aarch64 it runs the WoW64 path: wine's i386 PE builtins under box64's
# wowbox64.dll (the i386 CPU emulator, Hangover's hardcoded default for i386-on-ARM64 — see
# wine-prefix-lower.nix), with the i386 syswow64 tree staged there too (this Hangover ARM64EC wine's
# `wineboot -u` never creates it). The native ARM64EC DXVK cannot service an i386 guest, so D3D9 goes through
# wine's builtin wined3d → OpenGL on the Apple M2 (Asahi Mesa) — the i386-windows platform default.
#
# TWO per-game fixes make it render (both required; NO emulator/wine patch needed):
#   1. setupScript (setup.sh) seeds Documents\My Games\FalloutNV\FalloutPrefs.ini. Launched directly, the
#      Gamebryo engine finds NO FalloutPrefs.ini and BOUNCES — it spawns FalloutNVLauncher.exe and exits
#      (diagnosed via +file: its last act is a PATH search for FalloutNVLauncher.exe). A seeded FalloutPrefs.ini
#      with a [Launcher] section + valid [Display] makes the engine proceed to device creation itself.
#   2. tuning.userReg spoofs wined3d's reported PCI vendor to a recognized card (NVIDIA GTX 660) — on Asahi
#      wined3d reports VendorId 0xffff, and FNV refuses CreateDevice on an unidentified adapter. wined3d honors
#      the HKCU\Software\Wine\Direct3D override natively (no patch). See wine-tuning.nix.
# With both, FalloutNV.exe creates its D3D9 device and renders the intro (Bethesda logo) → main menu.
#
#   nix run .#fallout-nv --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  mkSetupScript,
}:
mkApp {
  pname = "fallout-nv";
  appid = "fallout-nv";
  name = "Fallout: New Vegas";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
  # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
  # because this game is single-player; the Gamebryo build has no multiplayer mode and the exe carries no
  # matchmaking symbols. Its ws2_32 import is the era's store/telemetry plumbing, not gameplay.
  online = false;
  # GOG-Windows, 32-bit (i386) — Gamebryo runs via wine WoW64 on aarch64 (box64's wowbox64.dll, the default
  # i386 emulator; see the header).
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  # Launch the actual game exe DIRECTLY, NOT the isPrimary FalloutNVLauncher.exe (a settings stub that spawns
  # the game and exits — a launcher-that-exits trips the propnix launcher's primary-child teardown). FalloutNV.exe
  # is the Gamebryo binary; it resolves Data/, *.ini relative to its own location, so cwd = C:\game is correct.
  # (The setupScript pre-seeds FalloutPrefs.ini so the engine does not itself bounce to FalloutNVLauncher.exe.)
  exe = "FalloutNV.exe";
  # Save: the Gamebryo engine writes saves + Fallout.ini/FalloutPrefs.ini under Documents\My Games\FalloutNV.
  # Bind the whole folder (saves + config together) out to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/fallout-nv). The setupScript below seeds
  # FalloutPrefs.ini into this folder before launch.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Documents/My Games/FalloutNV";
    }
  ];
  # Per-title tuning (the wined3d PCI-vendor spoof) + the setup script the launcher runs before wine to seed
  # FalloutPrefs.ini (+ Fallout.ini) — see the fix (1) note above and setup.sh.
  # Top-level, not a wine knob: the hook runs in the OUTER phase before any prefix exists
  # (modules/app-options.nix).
  setupScript = mkSetupScript {
    name = "fallout-nv-setup";
    script = ./setup.sh;
  };

  wine = import ./wine-tuning.nix;
}

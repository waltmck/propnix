# Homeworld Remastered Collection (GOG, Windows build) via wine — on aarch64 through FEX + native
# ARM64EC DXVK, on x86_64 natively. Gearbox's 2015 remaster of Homeworld 1 & 2 (space RTS).
# ARCH-AGNOSTIC: the same spec runs on both hosts; the wine backend + the scope pick the arch-appropriate
# emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across arches.
# Windows-only title (no native Linux build). Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild
# (D15), delivered as the game tree directly (no InnoSetup).
#
# 32-BIT (i386) TITLE — the one that stretches propnix's usual x86_64/ARM64EC path. HomeworldRM.exe is a
# PE32 i386 binary (as are the HW1/HW2 Classic exes and the HWRStart chooser). This IS supported: the wine
# fork is built with `--enable-archs=…,x86_64,i386`, and on aarch64 32-bit x86 code runs under WoW64 via
# box64's wowbox64.dll (Hangover's hardcoded default i386 emulator; FEX's libwow64fex.dll is the staged
# alternative — see wine-prefix-lower.nix). On x86_64 hosts it is
# native WoW64. The renderer is OpenGL (static OPENGL32 import) → wine builtin opengl32 → host GL; the
# i386-windows platform default d3d = wined3d applies (DXVK is ARM64EC-only, unusable by a 32-bit process).
#
# DISPLAY: the engine NEVER asks the display how big it is — its resolution comes from the player
# profile, whose fallback is a hardcoded 1920x1080, so any larger monitor gets a small window.
# `setupScript` below fixes it by generating the engine's own `commandLine.txt` options file
# (`-w`/`-h`/`-fullscreen`) from the live compositor mode on every launch; see setup.sh for the
# switches and wine-tuning.nix for where the file lands.
#
#   nix run .#homeworld-rm --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  mkSetupScript,
}:
let
  # tuning is a FUNCTION of `payload` (its writable game-dir overlay references the payload store path);
  # applied to the resolved payload below. It carries graphics and the writable game-dir overlay.
  tuning = import ./wine-tuning.nix;
in
mkApp (
  { config, lib, ... }:
  {
    pname = "homeworld-rm";
    maintainers = [ "waltmck" ];
    appid = "homeworld-rm";
    name = "Homeworld Remastered Collection";
    # GOG-Windows, 32-bit (i386).
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    # Launch the REAL game binary DIRECTLY, NOT the goggame.info isPrimary "HWRStart.exe" — HWRStart is the
    # collection's chooser/launcher (it lets the user pick HW1/HW2 Remastered or the Classics, then SPAWNS the
    # picked game and EXITS; a launcher-that-exits trips the propnix launcher's primary-child teardown, same as
    # Outlast's OutlastLauncher / Stellaris' dowser). HomeworldRM.exe is the Homeworld Remastered game binary.
    exe = "HomeworldRM/Bin/Release/HomeworldRM.exe";
    # cwd = the exe's own directory, NOT the payload root: the engine resolves its data path from
    # the cwd, and from C:\game it logs " Error starting up Data path. " to HwRM.log and exits
    # without a window. GOG's playTask (goggame-2114871440.info) sets this same workingDir, and the
    # location of `commandLine.txt` (wine-tuning.nix) depends on it
    # (docs/research/homeworld-rm-engine.md).
    workingDir = "HomeworldRM/Bin/Release";
    # Fully offline via the kernel netns (loopback only). `wine.galaxyStubDlls` is refused for an
    # i386 title (lib/backends/wine/defaults.nix), so the real 32-bit Galaxy SDK loads and, with no
    # route out, takes its own offline path (docs/research/galaxy-sdk-offline.md). Homeworld RM's
    # single-player campaigns need no network; multiplayer does, and is out of scope here.
    online = false;

    # Run setup.sh before launch: the engine never asks the display its size (the profile default
    # is 1920x1080), so setup.sh writes `w`/`h`/`fullscreen` into the engine's `commandLine.txt`
    # options file on every launch. No `withIniLib`: the file is the engine's own
    # one-option-per-line format. Top-level, not a wine knob: the hook runs in the OUTER phase
    # before any prefix exists.
    setupScript = mkSetupScript {
      name = "homeworld-rm-setup";
      script = ./setup.sh;
    };

    wine = tuning { payload = lib.head config.payloads; }; # function-tuning: applied to the payload store path
  }
)

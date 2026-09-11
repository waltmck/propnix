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
# DISPLAY: the engine NEVER asks the display how big it is — its resolution comes from the player profile,
# whose fallback is a hardcoded 1920x1080, so any larger monitor got a small window. `setupScript` below fixes
# it by generating the engine's own `commandLine.txt` options file (`-w`/`-h`/`-fullscreen`) from the live
# compositor mode on every launch; see setup.sh for the switches and wine-tuning.nix for where the file lands.
#
#   nix run .#homeworld-rm --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  mkSetupScript,
}:
let
  # tuning is a FUNCTION of `payload` (its writable game-dir overlay references the payload store path);
  # applied to the resolved payload below. It carries graphics and the writable game-dir overlay (and the
  # record of why this title binds NO Galaxy stub — see wine-tuning.nix).
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
    # cwd = the exe's own directory, NOT the payload root. This spec used to assert the opposite — that the
    # HW2/HWRM engine resolves its data root from the module path, "so launching from cwd = C:\game is fine"
    # — and that was never tested, because the game had always died in Galaxy init before it looked for its
    # data (see wine-tuning.nix). With the crash gone it turns out to be false: from cwd = C:\game the
    # engine writes `HwRM.log` with " Error starting up Data path. " and exits WITHOUT a window, while from
    # cwd = HomeworldRM\Bin\Release it maps its "Homeworld Remastered" window within ~12 s and stays up.
    # GOG's own goggame-2114871440.info says the same thing: the hidden "Homeworld Remastered" playTask
    # carries `"workingDir": "HomeworldRM/Bin/Release"`. (Measured 2026-09-03 on x86_64-linux.)
    workingDir = "HomeworldRM/Bin/Release";
    # Fully offline, enforced by the kernel (loopback-only netns) rather than by neutering the bundled SDK:
    # the usual mechanism — a no-op `wine.galaxyStubDlls` bind over the game's Galaxy.dll — is UNUSABLE for
    # a 32-bit title (the stub's uniform zero-argument vtable violates __thiscall's callee-pops rule and
    # crashed the game; the evidence is in wine-tuning.nix and lib/backends/wine/defaults.nix). The real
    # 32-bit Galaxy SDK therefore loads, and with no route out it takes its offline path: it throws and
    # swallows its own `galaxy::api::IError` C++ exceptions during init and the game proceeds to render.
    # Homeworld RM's single-player campaigns need no network; multiplayer does, and is out of scope here.
    online = false;

    # Run setup.sh before launch: generate the engine's `commandLine.txt` options file carrying the live
    # display resolution (`w`/`h`) + `fullscreen`. WITHOUT IT the game starts at 1920x1080 — MEASURED, not
    # inferred: on a 3840x2160 output HwRM.log reported `Switching to a 1920x1080 32bit mode` and
    # `Display: (0, 0, 1920, 1080)` with an empty `CmdLine:`, i.e. a quarter-area window. 1920x1080 is the
    # engine's own hardcoded profile default (pushed as the fallback to the profile getter at VA 0x41503a /
    # 0x415051) — the game NEVER asks the display what size it is, so a big monitor always gets a small window.
    # No `withIniLib`: this file is not INI, it is the engine's own one-option-per-line format (setup.sh).
    # Top-level, not a wine knob: the hook runs in the OUTER phase before any prefix exists.
    setupScript = mkSetupScript {
      name = "homeworld-rm-setup";
      script = ./setup.sh;
    };

    wine = tuning { payload = lib.head config.payloads; }; # function-tuning: applied to the payload store path
  }
)

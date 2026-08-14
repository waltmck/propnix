# Homeworld Remastered Collection (GOG, Windows build) via wine — on aarch64 through FEX + native
# ARM64EC DXVK, on x86_64 natively. Gearbox's 2015 remaster of Homeworld 1 & 2 (space RTS).
# ARCH-AGNOSTIC: the same spec runs on both hosts; makeAppWine + the scope pick the arch-appropriate
# emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across arches.
# Windows-only title (no native Linux build). Payload = the pinned GOG Galaxy build fetched with gogdl
# (D15), delivered as the game tree directly (no InnoSetup).
#
# 32-BIT (i386) TITLE — the one that stretches propnix's usual x86_64/ARM64EC path. HomeworldRM.exe is a
# PE32 i386 binary (as are the HW1/HW2 Classic exes and the HWRStart chooser). This IS supported: the wine
# fork is built with `--enable-archs=…,x86_64,i386` and the aarch64 prefix registers FEX's `libwow64fex.dll`
# as the WoW64 x86 backend, so 32-bit x86 Windows code runs under FEX-32 (WoW64). On x86_64 hosts it is
# native WoW64. The renderer is OpenGL (static OPENGL32 import) → wine builtin opengl32 → host GL; see
# tuning.nix for why d3d=wined3d (DXVK is ARM64EC-only and unusable by a 32-bit process).
#
#   nix run .#homeworld-rm --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  # tuning is a FUNCTION of `payload` (its writable game-dir overlay references the payload store path);
  # makeAppWine resolves it. It carries graphics/d3d, the Galaxy stub, and the game-dir overlay.
  tuning = import ./tuning.nix;
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "homeworld-rm-win"; });
in
makeAppWine {
  pname = "homeworld-rm";
  appid = "homeworld-rm";
  name = "Homeworld Remastered Collection";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  inherit payload;
  # Launch the REAL game binary DIRECTLY, NOT the goggame.info isPrimary "HWRStart.exe" — HWRStart is the
  # collection's chooser/launcher (it lets the user pick HW1/HW2 Remastered or the Classics, then SPAWNS the
  # picked game and EXITS; a launcher-that-exits trips the propnix launcher's primary-child teardown, same as
  # Outlast's OutlastLauncher / Stellaris' dowser). HomeworldRM.exe is the Homeworld Remastered game binary;
  # the HW2/HWRM engine resolves its data root (HomeworldRM/Data/*.big) from the module path (two dirs up
  # from Bin/Release), so launching from cwd = C:\game (the payload root) is fine.
  exe = "HomeworldRM/Bin/Release/HomeworldRM.exe";
  inherit tuning;
  # BROKEN on aarch64 (runtime-diagnosed). With the full 32-bit enablement in place — wowbox64 + a populated
  # syswow64 + the x86 WinSxS manifests in wine-prefix-lower, plus the writable game-dir overlay, graphics=x11
  # and d3d=wined3d here — HomeworldRM.exe (a 32-bit/i386 PE) gets DEEP into init: it clears the DLL loads,
  # the Galaxy stub, the "Administrative access" folder-write check, the comctl32 v6 activation context, and
  # (on the FEX i386 backend) even MAPS its "Homeworld Remastered" top-level window. Then it dies in its
  # SEH/setjmp-heavy early-init code with an EXCEPTION_ACCESS_VIOLATION — reproducibly, on BOTH WoW64 i386
  # emulators, at DIFFERENT points: FEX (libwow64fex) faults on an EXECUTE at eip=0x008E6060 (a corrupted
  # indirect-branch target in the exe) → the game's crash handler shows its multilingual "Access Violation"
  # box; box64 (wowbox64, the default) faults earlier on a near-null READ (info addr ~0x3733) at guest
  # eip=0x006E4E72, before the main window, then wedges. Two DIFFERENT fault sites/types on the two backends
  # = an x86-on-ARM64 codegen/SEH-translation bug in the emulator, NOT a fixable prefix/config issue (same
  # CLASS as the KSP FEX-codegen blocker). Every propnix/wine/prefix lever was exhausted (both emulators, the
  # winsxs actctx fix, x11/wayland, wined3d). Needs an upstream FEX/box64 fix. Native x86_64 wine runs i386
  # via native WoW64 (no FEX/box64), so it is unaffected there — the package still builds and runs on x86_64.
  brokenSystems = [ "aarch64-linux" ];
  brokenReason = "HomeworldRM.exe (32-bit i386) reaches deep init and maps its window under FEX, then hits a reproducible EXCEPTION_ACCESS_VIOLATION in its SEH/setjmp-heavy early init on BOTH WoW64 i386 backends at different sites (FEX: execute-AV at exe eip 0x8E6060; box64: near-null read at eip 0x6E4E72) — an x86-on-ARM64 emulator codegen/SEH bug, not fixable at the propnix/wine layer (needs upstream FEX/box64). Runs on native x86_64 (native WoW64, no emulator).";
}

# Stellaris (Steam, x86_64 LINUX build) via the THIN launcher path — on aarch64 through box64, on x86_64
# natively. Stellaris is a Paradox grand-strategy title on the Clausewitz engine (statically-linked SDL2,
# PhysFS asset VFS, no Mono).
#
# WHY box64 + the Linux build (not wine + the Windows build): the Windows/Clausewitz build hangs under
# FEX/ARM64EC — a worker thread overflows its stack during early init and wine can't dispatch the overflow
# (a genuine guest overflow the ARM64EC transition overhead inflates; enlarging the reserve doesn't help, it
# just gets consumed — proven). The native Linux ELF sidesteps ARM64EC entirely: box64 runs the x86_64 code
# with the NATIVE aarch64 SDL/GL/Vulkan stack bridged in, which is playable on this host.
#
# WHY Steam (not GOG): GOG's Linux offline installer exposes ONLY the current version (no version pin — an
# FOD that breaks on every store update), whereas Steam pins content by (appId, depotId, manifestId),
# retained forever → a permanently-reproducible FOD. See lib/fetchers/fetchSteamDepot.nix. Requires a Steam
# account: `propnix cred add steam`.
#
# Steam-only, Linux-only: the fetch matrix has exactly that pair, and any other selection is a legible
# mkApp error. `stellaris.apply { backend = "fex"; }` reruns the same build under FEX (broken on 16K
# aarch64; carried for x86_64 / future).
#
#   nix run .#stellaris --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
}:
mkApp (
  { config, ... }:
  {
    pname = "stellaris";
    appid = "stellaris";
    name = "Stellaris";

    # The Linux binaries depot (281994: the `stellaris` ELF + $ORIGIN-linked libPDXSDK/libnakama-cpp) and
    # the shared data depot (281991), UNIONED READ-ONLY by overlayfs at launch — no build-time merge, no
    # store copy. Binaries FIRST so it wins any overlap with data (arg-set order = overlay priority).
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

    # The game's own executable icon (a spaceship over a planet, no text), autocropped + recentred into the
    # hicolor theme + splash. It's the low-res 48px `exe_icon.bmp` (the only text-free square icon the
    # depot ships; the OST cover carries an "Original Soundtrack" subtitle, game-logo is a wide banner), so
    # it's a touch soft upscaled, but it's the correct icon. It lives in the DATA depot = the 2nd payload.
    icon.png = "${lib.elemAt config.payloads 1}/gfx/exe_icon.bmp";

    # Run the game binary DIRECTLY, bypassing start.sh → dowser → the Electron Paradox launcher (an entire
    # Chromium stack that need not survive emulation). launcher-settings.json records what the launcher
    # would exec: `"exePath": "./stellaris", "exeArgs": [ "-gdpr-compliant" ]` — so we run exactly that.
    # Clausewitz resolves its game root from the cwd (= the payload tree), so workingDir stays null.
    exe = "stellaris";
    exeArgs = [ "-gdpr-compliant" ];

    # The library UNION (PLAN2 §7), derived from the payload: `stellaris` links libX11/libGL/libstdc++/
    # libgcc_s (+ its two $ORIGIN libs) and carries a statically-linked SDL2 whose dlopen table adds the
    # audio/wayland/x11/vulkan/egl sonames. bridgingLibs = what box64 WRAPS (needed native aarch64 to
    # bridge AND x86_64 for the guest); guestLibs = guest-only (glibc, libstdc++). zlib is in BOTH: box64
    # wants the native copy (else "Error initializing native libz.so.1"), and libPDXSDK links it as a
    # guest — the union rule in one soname.
    box64 = {
      bridgingLibs =
        p: with p; [
          libgcc
          libx11
          libxext
          libxcursor
          libxrandr
          libxi
          libxfixes
          libxscrnsaver
          libGL
          libglvnd
          vulkan-loader
          libxkbcommon
          wayland
          dbus.lib
          libpulseaudio
          alsa-lib
          libxcb # libX11-xcb.so.1 links against it; listed so resolution doesn't depend on RUNPATH
          zlib
        ];
      guestLibs =
        p: with p; [
          glibc
          stdenv.cc.cc.lib
          zlib
        ];
    };

    # State lives outside the store (PLAN2 §7.2): Clausewitz derives it from launcher-settings.json's
    # "$LINUX_DATA_HOME/Paradox Interactive/Stellaris" (= XDG_DATA_HOME). The THIN launcher points $HOME
    # (and thus the default XDG roots) at an ephemeral per-launch view, then binds the persistent propnix
    # save dir onto the exact path the game writes — so saves/settings/mods/dlc_load.json persist while the
    # game tree stays read-only. Mirrors the wine path's PROPNIX_SAVE_DIR/<appid> semantics.
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = ".local/share/Paradox Interactive/Stellaris";
      }
    ];
  }
)

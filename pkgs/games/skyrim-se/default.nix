# The Elder Scrolls V: Skyrim Special Edition — via wine (aarch64 → FEX + native ARM64EC DXVK, x86_64 →
# native wine). Bethesda Creation Engine (the 64-bit "Special Edition" remaster), renders D3D11 → DXVK →
# Vulkan. ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope pick the arch-appropriate
# emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across arches. Windows-only
# title (no native Linux build on either store), so `platformPreference` stays derived — the ratchet in
# modules/app-options.nix counts PINNED PLATFORMS, not pinned pairs, and there is still exactly one.
#
# The two stores are pinned, and the FETCHER is the only axis that distinguishes them:
#
#   * gog   / x86_64-windows — the GOG Galaxy build (fetchGogGalaxyBuild, D15), one tree. THE VERIFIED
#                              PATH: the save-folder trace, the `Galaxy64.dll` import, the graphics=x11
#                              finding and the iSize behaviour below were all measured on this payload, and
#                              it is what the default `preferredFetchers` (registry order — `gog` sorts
#                              before `steam`) resolves to. Unchanged by the Steam pins.
#   * steam / x86_64-windows — the Steam build, three depots. NEVER LAUNCHED. See "THE STEAM MATRIX".
#
# The Creation Engine needs SkyrimPrefs.ini's `iSize` to equal the actual display resolution for correct
# fullscreen (it renders its backbuffer at iSize even in fullscreen — see setup.sh). We launch SkyrimSE.exe
# directly (bypassing SkyrimSELauncher.exe, which normally writes the resolution + a quality preset), so we
# supply a `setupScript` (setup.sh) that the launcher runs before wine: it seeds SkyrimPrefs.ini's iSize from
# the compositor-derived PROPNIX_WIDTH/HEIGHT facts + the chosen PROPNIX_QUALITY preset.
#
#   nix run .#skyrim-se --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
#   nix run '.#skyrim-se.apply { fetcher = "steam"; }'                    # the untested Steam payload
#
# ── THE STEAM MATRIX ────────────────────────────────────────────────────────────────────────────────────
# Steam splits this title across three depots. The ORDER in versions.json is load-bearing: builders/wine.nix
# takes `head payloads` as C:\game's primary tree, the launch cwd, the tree it extracts the PE icon from,
# AND the tree it points `PROPNIX_PAYLOAD` at for the setup script. Measured contents of the pinned trees:
#
#   489833   ~21 MB   SkyrimSE.exe, and nothing else at all                                          ← head
#   489832  ~7.9 GB   the install ROOT: SkyrimSELauncher.exe, steam_api64.dll, Skyrim_Default.ini,
#                     Skyrim.ccc, the Low/Medium/High/Ultra.ini quality presets, Data/ (the textures +
#                     the four master .esm files), and Skyrim/SkyrimPrefs.ini
#   489831  ~6.4 GB   Data/ (the remaining .bsa archives, the Creation-Club .esl/.esm, Data/Video)
#
# 489833 is head so that `exe` and `icon.auto` behave EXACTLY as on the GOG tree — the PE icon extractor
# (lib/icons/from-pe.nix) runs `wrestool` on `${head payload}/${exe}`, so a head without SkyrimSE.exe would
# be a hard build failure rather than a resolvable one. SkyrimSE.exe carries a 256px icon (verified with
# `icotool -l`).
#
# SETUP-SCRIPT CONSEQUENCE, handled by the framework: `PROPNIX_PAYLOAD` remains the head tree, so it still
# does not contain the Steam quality presets. The launcher also hands hooks `PROPNIX_PAYLOADS`, however:
# every game-content tree in mount-priority order. mkSetupScript supplies `payload_require`, and setup.sh
# uses it to find Low/Medium/High/Ultra.ini in 489832 while retaining the same one-tree behavior on GOG.
# The hook can therefore run in the OUTER phase before merged C:\game exists without losing access to
# co-base assets; a missing preset is still a loud packaging failure that lists every searched tree.
#
# WHAT ELSE IS UNVERIFIED ON THE STEAM PATH: it has not been launched. The two things that provably DIFFER
# by store are handled below (`saveBinds`, `galaxyStubDlls`); the two things that provably do not are the
# exe name and the engine tuning in wine-tuning.nix.
{
  lib,
  mkApp,
  mkSetupScript,
  presets,
}:
mkApp (
  { config, lib, ... }:
  let
    onGog = config.fetcher == "gog";
  in
  {
    pname = "skyrim-se";
    appid = "skyrim-se";
    name = "Skyrim Special Edition";

    # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
    # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
    # because this game is single-player; the Creation Engine build has no multiplayer, and the exe's lone
    # `Matchmaking` string is Steam-SDK boilerplate. Store-independent: the Steam build is the same engine,
    # and its bundled Steamworks lib is de-integrated by `steam.emu` below rather than relied on.
    online = false;
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    # Launch the actual x86_64 game exe DIRECTLY, NOT the isPrimary SkyrimSELauncher.exe (a 32-bit settings stub
    # that spawns SkyrimSE.exe and exits → trips the propnix launcher's primary-child teardown). SkyrimSE.exe is
    # the 64-bit Creation Engine binary; it resolves Data/, *.ini, and the game root relative to its own location,
    # so cwd = payload root is fine. Same name and same behaviour in both stores' payloads.
    exe = "SkyrimSE.exe";
    # Full-color icon auto-extracted from SkyrimSE.exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
    # VC++ runtime (MSVCP140/VCRUNTIME140) loads on wine's ARM64EC UCRT builtins under FEX (no extraSystem32 needed).
    icon.symbolic = ./skyrim-se-symbolic.svg;

    # De-store-integration on the STEAM path (inert on GOG: `steam.emu.enable` defaults to `fetcher ==
    # "steam"`). The Steam build ships ONE Steamworks copy, `steam_api64.dll` at the install root — in
    # depot 489832, verified by listing the tree — and steam.emu union-replaces it with the gbe_fork shim
    # (the settings tree ranks above every payload in the wine game overlay). REQUIRED, not decorative:
    # mk-app.nix refuses a wine build that enables the emu without naming a `.dll` path, because a shim the
    # game never loads would be silently inert while every entitlement read "unowned".
    steam.emu.libPaths = [ "steam_api64.dll" ];

    # Save: the Creation Engine writes saves + Skyrim.ini/SkyrimPrefs.ini under Documents\My Games\<folder>,
    # and THE FOLDER NAME IS STORE-SPECIFIC — this is the one place where getting the fetcher wrong loses
    # data silently rather than loudly, so it is derived from the axis, not hardcoded:
    #
    #   gog    "Skyrim Special Edition GOG"  — verified via a +file trace: SkyrimSE.exe reads/writes exactly
    #                                          that path. Using the Steam name here previously dropped saves
    #                                          and hid the config, which is how this was found.
    #   steam  "Skyrim Special Edition"      — from the Steam build's OWN installscript.vdf (shipped in depot
    #                                          489831), whose "Copy Folders" rule is
    #                                          SrcFolder %INSTALLDIR%\Skyrim → DstFolder
    #                                          %USER_MYDOCS%\My Games\Skyrim Special Edition. That is Steam
    #                                          seeding the very directory the engine then uses, so the
    #                                          unsuffixed name is the Steam build's folder as a matter of
    #                                          record. (Not runtime-traced — nobody has launched this path.)
    #
    # Both bind the same host dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID), which is deliberate: the save format is
    # identical, so a save made under one store's build opens under the other's. Bind the whole folder (saves
    # + .ini config together).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "Documents/My Games/Skyrim Special Edition${lib.optionalString onGog " GOG"}";
      }
    ];

    # Run setup.sh before launch: seed SkyrimPrefs.ini display (iSize/fullscreen) + the PROPNIX_QUALITY
    # preset. setup.sh uses the shared `ini_set` (withIniLib) at its plain-LF `key=value` defaults, and finds
    # the shipped Low/Medium/High/Ultra.ini presets with `payload_require` (payload-lib.sh, always supplied)
    # rather than under $PROPNIX_PAYLOAD — the head tree is pinned to whichever depot carries SkyrimSE.exe,
    # which on the split-depot Steam arm is NOT the depot carrying the presets. Top-level, not a wine knob:
    # the hook runs in the OUTER phase before any prefix exists (modules/app-options.nix).
    # Store-independent — it writes into the HOST save dir, which each fetcher's `saveBinds` row above then
    # binds at that store's own Documents path.
    setupScript = mkSetupScript {
      name = "skyrim-se-setup";
      script = ./setup.sh;
      withIniLib = true;
    };

    wine = presets.mergeTuning [
      (import ./wine-tuning.nix)
      {
        # SkyrimSE.exe STATICALLY imports the GOG Galaxy SDK (Galaxy64.dll, at the payload root — verified via
        # the PE import table), so bind the no-op stub over it via a mount row: propnix games run fully offline,
        # with no cloud dependencies (see emulators/galaxy-stub). Same de-Galaxy pattern as HK / Prison
        # Architect; aarch64 only, a no-op on x86_64 native wine.
        #
        # GATED ON THE FETCHER, and it has to be: the Steam payload contains no Galaxy64.dll at all (listed —
        # its store SDK is `steam_api64.dll`, handled by `steam.emu.libPaths` above). An ungated stub row
        # would bind a GOG shim over a path that does not exist in the Steam game tree, i.e. INVENT a Galaxy
        # SDK for a build that never had one. Same shape as the gate in hollow-knight / factorio.
        galaxyStubDlls = lib.mkIf onGog [ "Galaxy64.dll" ];
      }
    ];
  }
)

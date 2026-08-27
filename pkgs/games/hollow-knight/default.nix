# Hollow Knight — the exemplar of the two-axis model (D16). `fetcher` (gog|steam) and `emulatedPlatform`
# (x86_64-windows|x86_64-linux) are INDEPENDENT: the platform picks the backend + most tweaks, the fetcher
# only the payload source + which store DLL to neutralize. This module sets config CONDITIONALLY on both,
# so one spec covers every combo it has pins for; selection resolves from `platformPreference` (the game's
# quality ranking, below) × the user's `preferredFetchers`, and `.apply { … }` overrides either axis.
#
#   * steam / x86_64-linux   — Steam Linux build via box64 (native aarch64 GL/SDL bridged in). The
#                              PREFERRED platform: benchmarks measure it a bit ahead of the wine path.
#   * gog   / x86_64-windows — GOG Galaxy Windows build via wine (aarch64 → FEX + ARM64EC DXVK). The
#                              sanctioned fallback — a gog-only `preferredFetchers` gets this automatically
#                              (GOG has no HK Linux pin).
#   * steam / x86_64-windows — Steam Windows build via wine (same wine path; steam.emu union-replaces
#                              steam_api64.dll instead of stubbing the GOG Galaxy SDK — the "small tweak"
#                              that differs by fetcher).
#
# Availability IS the fetch matrix: versions.json is `fetchInfo` verbatim (fetcher → platform → fetch
# arg-sets), and mkApp's `payloads` default fetches the selected pair or throws a legible error listing the
# pinned pairs. Per-emulator tuning: `box64 = import ./box64-tuning.nix` (only forced by thin backends) and
# `wine` (only forced by wine) — both set unconditionally, laziness makes the unused one free.
#
#   nix run .#hollow-knight                                                             # steam/linux (default resolution)
#   nix run '.#hollow-knight.apply { emulatedPlatform = "x86_64-windows"; }'            # gog/windows (fetcher re-resolves)
#   nix run '.#hollow-knight.apply { fetcher = "steam"; emulatedPlatform = "x86_64-windows"; }'   # steam/windows
{
  lib,
  mkApp,
  presets,
}:
mkApp (
  { config, ... }:
  let
    onLinux = config.emulatedPlatform == "x86_64-linux";
    onSteam = config.fetcher == "steam";
  in
  {
    pname = "hollow-knight";
    appid = "hollow-knight";
    name = "Hollow Knight";

    # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
    # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
    # because this game is single-player; the exe links no socket library at all and carries no matchmaking
    # symbols.
    online = false;
    icon.symbolic = ./hollow-knight-symbolic.svg;

    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    # The game's platform QUALITY ranking (required: two platforms are pinned). Linux-first: on aarch64 the
    # native-Linux build under box64 benchmarks a bit ahead of the Windows build under wine+FEX/DXVK, and on
    # x86_64 it runs natively. The Windows rank makes gog-only users fall back to gog/x86_64-windows.
    platformPreference = [
      "x86_64-linux"
      "x86_64-windows"
    ];

    # The exe differs by both axes: the Linux ELF; GOG's spaced "Hollow Knight.exe"; Steam's lowercase
    # "hollow_knight.exe" (its data dir is hollow_knight_Data on both Steam builds, matching the ELF).
    exe =
      if onLinux then
        "hollow_knight.x86_64"
      else if onSteam then
        "hollow_knight.exe"
      else
        "Hollow Knight.exe";

    # De-store-integration: every Steam combo runs against the offline emulator now — steam.emu places the
    # gbe_fork lib AT the paths below (Unity dlopens its native plugins by EXPLICIT PATH, so no preload can
    # interpose them): the Linux .so is bind-overed at launch, the Windows dll is union-replaced by the
    # settings tree ranking above the payload. SteamAPI init resolves offline against the emulator; nothing
    # is masked anymore (a mask would also EINVAL now that the emu's extraLowers make the game dir
    # multi-lower — see the maskFiles option docs). HK ships Steamworks.NET 2024.8.0 / SDK 1.60, whose
    # `SteamInternal_SteamAPI_Init` entry point needs gbe_fork — goldberg 0.2.5 lacked it and
    # black-screened (worse than absence: the lib loaded, init threw). Each payload's own path, declared
    # unconditionally; each backend consumes only its flavor. GOG's Galaxy SDK is a different mechanism
    # entirely (a static import needing a real no-op stub): `galaxyStubDlls` below.
    steam.emu.libPaths = [
      "hollow_knight_Data/Plugins/libsteam_api.so"
      "hollow_knight_Data/Plugins/x86_64/steam_api64.dll"
    ];

    # Save: HK's Unity persistentDataPath, bound out to the persistent propnix save dir. dst is
    # HOME-relative on both backends — the Windows and Linux builds just keep it under different
    # OS-native homes (AppData vs .config).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst =
          if onLinux then
            ".config/unity3d/Team Cherry/Hollow Knight"
          else
            "AppData/LocalLow/Team Cherry/Hollow Knight";
      }
    ];

    # ── box64 / Linux tuning ── the emulator lib triage (only forced by thin backends). The two dynarec
    # workarounds are box64-SPECIFIC (native x86_64 needs neither): Unity picks a dying renderer under
    # box64 without -force-opengl, and SDL's Wayland backend trips box64's dynarec — pin x11.
    box64 = import ./box64-tuning.nix;
    exeArgs = lib.optionals (config.backend == "box64") [ "-force-opengl" ];
    env.SDL_VIDEODRIVER = lib.mkIf (config.backend == "box64") "x11";

    # ── wine tuning ── HK is well-behaved on the global defaults; what remains per-title is the Unity
    # frame-pacing preset (agreeing with the launcher's PROPNIX_FPS modes) + the de-Galaxy stubs for the
    # GOG build (HK bundles the Galaxy SDK in two spots; a Steam build has none).
    wine = presets.mergeTuning [
      (presets.unity.framePacing "Software\\Team Cherry\\Hollow Knight")
      {
        galaxyStubDlls = lib.mkIf (config.fetcher == "gog") [
          "Galaxy64.dll"
          "Hollow Knight_Data/Plugins/x86_64/Galaxy64.dll"
        ];
      }
    ];
  }
)

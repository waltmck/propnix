# Hollow Knight — the exemplar of the two-axis model (D16). `fetcher` (gog|steam) and `emulatedPlatform`
# (x86_64-windows|x86_64-linux) are INDEPENDENT: the platform picks the backend + most tweaks, the fetcher
# only the payload source + which store DLL to neutralize. This module sets config CONDITIONALLY on both,
# so one spec covers every combo it has pins for; selection resolves from `platformPreference` (the game's
# quality ranking, below) × the user's `preferredFetchers`, and `.apply { … }` overrides either axis.
#
#   * gog|steam / aarch64-windows — the Windows build on Unity's own NATIVE ARM64 player with our ARM64
#                              Mono runtime (lib/modules/unity-player.nix pins this pair from the x64 rows):
#                              the whole process native under wine, nothing emulated. The PREFERRED
#                              platform; aarch64 hosts only.
#   * steam / x86_64-linux   — Steam Linux build via box64 (native aarch64 GL/SDL bridged in); the
#                              default on x86_64, where it runs natively.
#   * gog   / x86_64-windows — GOG Galaxy Windows build via wine (aarch64 → FEX + ARM64EC DXVK + the
#                              ARM64EC Mono runtime). A gog-only `preferredFetchers` on x86_64 gets this
#                              (GOG has no HK Linux pin); on aarch64 it gets gog/aarch64-windows.
#   * steam / x86_64-windows — Steam Windows build via wine (same wine path; steam.emu union-replaces
#                              steam_api64.dll instead of stubbing the GOG Galaxy SDK — the "small tweak"
#                              that differs by fetcher).
#
# Availability IS the fetch matrix: versions.json is `fetchInfo` verbatim (fetcher → platform → fetch
# arg-sets), and mkApp's `payloads` default fetches the selected pair or throws a legible error listing the
# pinned pairs. Per-emulator tuning: `box64 = import ./box64-tuning.nix` (only forced by thin backends) and
# `wine` (only forced by wine) — both set unconditionally, laziness makes the unused one free.
#
#   nix run .#hollow-knight                                                             # aarch64: gog/aarch64-windows (native); x86_64: steam/linux
#   nix run '.#hollow-knight.apply { emulatedPlatform = "x86_64-windows"; }'            # gog/windows, the x64 player under FEX (the A/B)
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
    maintainers = [ "waltmck" ];
    appid = "hollow-knight";
    name = "Hollow Knight";

    # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
    # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
    # because this game is single-player; the exe links no socket library at all and carries no matchmaking
    # symbols.
    online = false;
    # Art-led title: gamescope enlarges a smaller image by whole multiples only, so the art stays crisp.
    gamescope.scaler = "integer";
    icon.symbolic = ./hollow-knight-symbolic.svg;

    # The two Windows rows also pin `aarch64-windows` (lib/modules/unity-player.nix: their recorded player
    # version, 6000.0.61f1, is packaged), so three platforms are pinned.
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    # The game's platform QUALITY ranking (required: more than one platform is pinned). The native ARM64
    # process first — nothing in it is emulated, and the intro video plays, which it does not on the x64
    # player under FEX (the player decodes it in-process; wine's media path is the same builtin code in
    # both, so that gap is FEX's) — which only an aarch64 host can run (the resolver skips it elsewhere);
    # then the Linux build, which runs natively on x86_64 and under box64 on aarch64 a bit ahead of the
    # x64 Windows build under wine+FEX/DXVK; then that Windows build, which makes gog-only users fall back
    # to gog/x86_64-windows on x86_64.
    platformPreference = [
      "aarch64-windows"
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

    # Unity 6, Mono scripting backend (the pin records the player's version — `unityVersion` on each row).
    # The aarch64-windows platform runs on Unity's own NATIVE ARM64 player for that release (emulators/
    # unity-player) with our native ARM64 Mono runtime: the whole process is ARM64 under wine, nothing
    # is emulated (lib/modules/unity-player.nix). The game's own code is pure IL; its only native pieces
    # are the Steam shim, which steam-emu places in `Plugins/ARM64/` as the ARM64 gbe_fork, and the GOG
    # Galaxy stub, bound from the ARM64 target set — both keyed by the platform. HK ≥1.5 reads input
    # through the Unity Input System, so the vendored x64 InControlNative.dll is never asked for. The
    # x86_64-windows platform is the x64 player under FEX with the ARM64EC runtime
    # (lib/modules/unity-mono.nix); the Linux combo under box64 is unaffected by either.

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

    # ── box64 / Linux tuning ── the emulator lib triage (only forced by thin backends). The renderer
    # workaround is box64-SPECIFIC (native x86_64 doesn't need it): Unity picks a dying renderer under
    # box64 without -force-opengl.
    box64 = import ./box64-tuning.nix;
    exeArgs = lib.optionals (config.backend == "box64") [ "-force-opengl" ];

    # SDL video driver: x11 on EVERY thin backend (was box64-only), for two independent reasons:
    #   * box64: SDL's Wayland backend trips box64's dynarec.
    #   * native x86_64: Unity vendors a pre-2.26 SDL fork inside UnityPlayer.so — SDL_DYNAMIC_API is
    #     compiled out (no swapping in a modern SDL) and there is no wayland mode emulation — so a
    #     Wayland window can only ever see the output's LOGICAL size. On a fractionally-scaled output
    #     that caps the in-game resolution list (2560x1440 on a 1.5x-scaled 4K monitor, Player.log:
    #     "Display 0: 2560x1440") and the compositor upscales the result. Under Xwayland the game sees
    #     whatever the compositor exposes there — the physical mode when so configured (Hyprland
    #     `xwayland:force_zero_scaling`), and never less than the wayland backend's logical cap.
    # Inert on the wine backend (wine has no SDL). Revisit if the vendored SDL ever reaches ≥2.26.
    env.SDL_VIDEODRIVER = "x11";

    # ── THIS TITLE UNDER FEX: BROKEN ON A 16K-PAGE HOST ─────────────────────────────────────────────────
    # `.apply { backend = "fex"; }` is a legal override of the Linux platform's default (box64), and for
    # this engine it does not work here: the thin-FEX path reaches Unity and then crashes at guest MONO
    # init. The cause is FEX's self-modifying-code tracking, which a Mono JIT leans on and which is
    # 4 KiB-granular against this host's 16 KiB page — a different wall from the mmap/allocator ones
    # emulators/fex-linux fixes, and one those patches do not address.
    #
    # RECORDED HERE, NOT IN THE BACKEND, because it is a property of the ENGINE: FEX carries Civ V's
    # native C++ engine in-game on the same host, so a backend-wide refusal would be false for every
    # title that has no JIT. box64 — this platform's default and the benchmarked-faster route anyway —
    # is unaffected, so nothing about a normal `nix run .#hollow-knight` changes; only the explicit FEX
    # override is refused, with the wall named instead of a package that dies after the splash.
    #
    # Retiring this means RE-RUNNING the title under the current emulators/fex-linux and reporting that,
    # not deleting these two lines. The windows platform is untouched (wine there loads FEX's ARM64EC
    # DLLs, which is mechanism (A) of D12 and a different thing entirely).
    # Both halves are gated, so a box64/native/wine build carries no `broken.reason` at all rather than an
    # explanation of a wall it never meets.
    broken.systems = lib.optionals (config.backend == "fex") [ "aarch64-linux" ];
    broken.reason =
      lib.mkIf (config.backend == "fex")
        "Hollow Knight's Unity/Mono engine crashes at guest Mono init under the thin FEX backend on a 16K-page host: the Mono JIT depends on FEX's self-modifying-code tracking, which is 4K-granular against a 16K host page (emulators/fex-linux's large-host-page patches fix the mmap and allocator walls, not SMC). Drop `backend = \"fex\"` — box64 is this platform's default here and benchmarks faster regardless.";

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

# Factorio (Wube Software) — a factory-automation sim on its own engine, packaged from BOTH stores across
# THREE content platforms. The two axes (D16) are fully independent here, and this is the repo's first game
# whose platform ranking reaches a NATIVE-aarch64 build:
#
#   * steam / aarch64-linux   — Wube's own ARM64 Linux build, run NATIVELY on aarch64 (no emulator at all).
#                               The best path on this host by a wide margin, and the reason the platform axis
#                               grew an `aarch64-linux` value. Skipped automatically on an x86_64 host —
#                               propnix ships no ARM-on-x86 emulator, so lib/strategy.nix `runnable` filters
#                               it out of the resolver's walk and the ranking falls through to the next entry.
#   * steam / x86_64-linux    — the same depot's x86_64 ELF, under box64 on aarch64 / natively on x86_64.
#   * steam / x86_64-windows  — the Steam Windows build under wine (aarch64 → FEX + ARM64EC DXVK).
#   * gog   / x86_64-windows  — the GOG Galaxy Windows build under wine. The sanctioned fallback: a
#                               gog-only `preferredFetchers` gets this automatically (GOG's content system
#                               has no Linux Factorio build at all — Windows + Mac only).
#
# ONE DEPOT, TWO PLATFORMS: Steam ships both Linux ABIs in depot 427523, so `fetchInfo.steam.aarch64-linux`
# and `.x86_64-linux` are the SAME row (same pname/manifest ⇒ one derivation, fetched once). What differs is
# only which ELF `exe` names. NB the depot lays a `bin/x64/factorio` BASH DISPATCHER over the two real
# binaries (it `exec`s ../x64_/factorio or ../arm64/factorio after reading `arch`) — selecting that path
# would hand box64 a shell script, so both arms name the real ELF directly.
#
# THE STEAM PINS ARE ON THE `experimental` BRANCH (2.1.x), deliberately: `bin/arm64/` exists only there.
# Steam's `public` branch is still 2.0.77, whose Linux depot ships a single `bin/x64/factorio` and no ARM64
# build — pinning it would delete the aarch64-linux platform. Every Steam row names the same branch, so the
# platforms move together.
#
# BUT THE ARM64 BINARY LAGS ITS OWN DEPOT, and that is Wube's doing, not a pinning mistake. MEASURED on the
# depot whose branch is labelled 2.1.16: `bin/x64_/factorio` reports 2.1.16 and `bin/arm64/factorio` reports
# 2.1.15 — same manifest, same branch, two engine versions, and the same 2.1.15 in the Space Age depot. They
# evidently do not rebuild ARM for every release. Since all platforms share ONE save dir (see `saveBinds`),
# a save written by the x86_64 build can be a minor version ahead of what the ARM64 build will open, and
# Factorio refuses a save from a newer version. Worth knowing before blaming propnix for a rejected save.
#
#   nix run .#factorio                                                          # steam/aarch64-linux (native) on aarch64
#   nix run '.#factorio.apply { emulatedPlatform = "x86_64-linux"; }'           # steam/linux under box64
#   nix run '.#factorio.apply { fetcher = "gog"; }'                             # gog/windows under wine
#   nix run '.#factorio.withDlc [ "space-age" ]'                                # + the Space Age expansion
{
  lib,
  mkApp,
  mkSetupScript,
  fetchGogGalaxyBuild,
  fetchSteamDepot,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp (
  { config, lib, ... }:
  let
    onLinux = lib.hasSuffix "-linux" config.emulatedPlatform;
    onGog = config.fetcher == "gog";
    # Factorio's user-data (write-data) dir, relative to the home each backend joins onto:
    #   Windows: %APPDATA%\Factorio   (goggame savePath `{userappdata}/Factorio`; verified at runtime)
    #   Linux:   ~/.factorio           (config-path.cfg `use-system-read-write-data-directories=true`)
    userData = if onLinux then ".factorio" else "AppData/Roaming/Factorio";
    # The three files Factorio writes into that root once the startup caches are on. Same names on every
    # platform (one engine, one config).
    cacheFiles = [
      "atlas-cache.dat"
      "data-cache.dat"
      "crop-cache.dat"
    ];
  in
  {
    pname = "factorio";
    appid = "factorio";
    name = "Factorio";

    fetchInfo = versions.fetchInfo;

    # The game's quality ranking, best first, and HOST-INDEPENDENT — this states what is the better build,
    # not what this machine happens to be able to execute. Native ARM64 beats the same game under box64,
    # which beats the Windows build under wine+FEX; the Windows rank is what a gog-only user falls through
    # to. The resolver filters this through `lib/strategy.nix`'s `runnable`, so an x86_64 host skips the
    # ARM64 entry and walks on down this same list — no per-host branching belongs in a game spec.
    platformPreference = [
      "aarch64-linux"
      "x86_64-linux"
      "x86_64-windows"
    ];

    # Factorio resolves its read-data dir and its user-data dir from the EXECUTABLE's location (via
    # /proc/self/exe → bin/<arch>/../..), not from the cwd, so no `workingDir` is needed on any platform.
    exe =
      if config.emulatedPlatform == "aarch64-linux" then
        "bin/arm64/factorio"
      else if config.emulatedPlatform == "x86_64-linux" then
        "bin/x64_/factorio" # NB the underscore: bin/x64/factorio is the arch dispatcher script
      else
        "bin/x64/factorio.exe";

    # Full-color icon: factorio.exe's PE resources top out at 48px (pixelated upscaled) AND the high-res game
    # asset is off-centre in its canvas, so use the 1024px icon Wube ships in the game data via `icon.png` —
    # autocropped + recentred into a crisp, centred hicolor theme + splash png (lib/icons/from-png.nix). The
    # same relative path exists in every payload this game has — verified against all five pinned trees (GOG
    # Windows + its Space Age, and the Steam Windows/Linux depots + both Space Age depots), each carrying an
    # identical 1185524-byte file — so it needs no per-axis branch. The symbolic variant is a vendored gear (Font
    # Awesome 6 Solid, CC BY 4.0 — attribution in the .svg header).
    icon.png = "${lib.head config.payloads}/data/core/graphics/factorio.icon/Assets/factorio.png";
    icon.symbolic = ./factorio-symbolic.svg;

    # De-store-integration. Factorio LINKS its store SDK rather than dlopening it — `readelf -d` on both
    # Linux ELFs shows `NEEDED libsteam_api.so` with `RUNPATH $ORIGIN` — so `maskFiles` is not merely
    # constrained here, it is impossible: erasing the library makes the loader refuse to start the process
    # ("error while loading shared libraries"), which is nothing like the clean "no online subsystems"
    # degradation a dlopen-ing engine gives. The file must EXIST, so the Steam story is the offline
    # entitlement shim: steam.emu binds the gbe_fork library over each path below (thin) / union-replaces the
    # dll (wine), and answers DLC ownership offline. Declared for every payload unconditionally — each
    # backend consumes only the flavour its loader can mean.
    steam.emu.libPaths = [
      "bin/arm64/libsteam_api.so"
      "bin/x64_/libsteam_api.so"
      "bin/x64/steam_api64.dll"
    ];

    # Save: Factorio's user-data dir (saves + mods + blueprints + config + player-data + log). Both OS
    # layouts bind to the SAME host dir, which is right — the formats are cross-platform, so a save made by
    # the aarch64 build opens in the Windows build and vice versa. (Path per platform: see `userData`.)
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = userData;
      }
    ]
    # ── the startup caches, redirected out of the save dir ────────────────────────────────────────────
    # With `cache-sprite-atlas` + `cache-prototype-data` on (setup.sh), Factorio writes three cache files:
    # `atlas-cache.dat` is ~1.4 GB with Space Age, `data-cache.dat` ~8 MB, `crop-cache.dat` ~5 MB. All three
    # are DERIVED data, rebuilt from the payload whenever missing or stale, so they belong in the per-app
    # CACHE dir ($PROPNIX_CACHE = $XDG_CACHE_HOME/propnix/factorio — where the DXVK/vkd3d shader caches
    # already live) rather than in a save dir a user syncs or backs up. Not the STATE dir: state is what is
    # worth keeping, and $XDG_CACHE_HOME is the one a user can point at a fast, un-snapshotted filesystem.
    #
    # Factorio gives no help: `[path]` has only `read-data`/`write-data`, there is no cache-path key and no
    # CLI flag, and all three land in the write-data ROOT interleaved with `saves/`, `mods/` and
    # `player-data.json`. That rules out the usual overlay: an overlay has ONE upper, so it cannot route
    # writes by filename — `upper = state` sends the saves to state too, `upper = save` sends the cache
    # back. Binding the files individually is what routes by name, and it is safe here because the engine
    # writes them IN PLACE (MEASURED at 0.2s polling across a full load: no `.tmp` ever appears, so there
    # is no rename to hit EBUSY on a bind mountpoint).
    #
    # `type = "file"` is what makes `create` TOUCH the source on first launch instead of mkdir'ing it — a
    # directory there would make Factorio's open() fail obscurely. One declaration serves every platform:
    # wine joins `dst` onto the profile home and thin onto the view $HOME, exactly as for the row above.
    ++ map (f: {
      src = "$PROPNIX_CACHE/${f}";
      dst = "${userData}/${f}";
      type = "file";
    }) cacheFiles;

    # DLC — Space Age (Wube's 2.0 expansion: space platforms, new planets, quality/elevated-rails; requires
    # the base game). Note what the tree actually IS on both stores: NOT an additive overlay but a COMPLETE
    # 20835-file build of the game, its own engine binary and a full `data/base` included, with the
    # expansion's `data/{space-age,quality,elevated-rails,recycler}` alongside. Enabling it therefore
    # shadows the base payload almost entirely through the DLC-first union — which is why the thin path
    # gives every game tree its own exec-bit fix layer in its own position (builders/thin.nix): a single
    # fix layer built from the base payload would put the BASE engine back on top of the expansion's.
    dlc.available.space-age =
      if onGog then
        fetchGogGalaxyBuild versions.dlc.space-age
      else if onLinux then
        fetchSteamDepot versions.dlc.space-age-steam-linux
      else
        fetchSteamDepot versions.dlc.space-age-steam-windows;

    # ── box64 / native Linux tuning ── Factorio static-links almost everything (its own ELF NEEDs only
    # libresolv/libsteam_api/libm/libc) and dlopens the rest by soname at runtime — the bundled-SDL2 pattern.
    # This is the union those dlopens must find. Only ever forced by a thin backend.
    box64 = import ./box64-tuning.nix;

    # box64-SPECIFIC, and measured here: the x86_64 build under box64 dies during init with
    # `SDLWindow.cpp:190: SDL couldn't be initialized. SDL_Error: wayland not available`, then aborts. The
    # same wall hollow-knight hits — SDL's Wayland backend does not survive box64 — and the same fix: pin
    # SDL to x11 and let XWayland carry it. The NATIVE faces need none of this (the aarch64 build runs
    # straight on Wayland), so this is gated on the backend rather than on the platform.
    env.SDL_VIDEODRIVER = lib.mkIf (config.backend == "box64") "x11";

    # Maintain config.ini before launch — on EVERY platform, because its main job is now the startup
    # caches (`cache-prototype-data`, `cache-sprite-atlas`), which cut load time on all four combos. The
    # script also asserts `check-updates=false`, which only the GOG build actually has; setting it on a
    # Steam build is verified harmless (see setup.sh). Top-level, not a wine knob: the hook runs in the
    # OUTER phase before any prefix or view exists, so the thin backends honour it too.
    setupScript = mkSetupScript {
      name = "factorio-setup";
      script = ./setup.sh;
      withIniLib = true;
    };

    # ── wine tuning ──
    wine = {

      # The GOG build bundles the Galaxy SDK as a STATIC import, which cannot be WINEDLLOVERRIDE'd away —
      # it needs a real no-op stub so nothing ever reaches GOG's services (offline policy, not a crash fix).
      galaxyStubDlls = lib.mkIf onGog [ "bin/x64/Galaxy64.dll" ];
    };
  }
)

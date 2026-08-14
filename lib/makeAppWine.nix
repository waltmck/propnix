# makeAppWine — turn a game spec into an installable package that invokes propnix-launcher (PLAN2 §4).
#
# ARCH-TRANSPARENT: the emulator set (wine/dxvk/vkd3d/prefixLower) is injected from the scope, which wires
# the arch-appropriate packages (aarch64 → Hangover wine + FEX + native ARM64EC DXVK/vkd3d; x86_64 →
# the SAME wine source built native + standard x86_64 DXVK/vkd3d, no FEX). The wrapper, launcher, config,
# game spec, and tuning are IDENTICAL across arches, and the EXTERNAL behaviour (every PROPNIX_* env var)
# is the same — the emulation is handled transparently below the launcher. (A future arg could select the
# aarch64 emulator between FEX and box64; for now aarch64 always uses FEX via the scope.)
#
# The produced package is a symlinkJoin of `bin/<pname>` (a makeWrapper around the launcher, with the
# baked config path added as a flag) + the `.desktop` entry (+ icon). The `configFile` — a writeText JSON
# with all store paths interpolated — IS the launcher↔wrapper interface (PLAN2 §4): Nix computes the
# intended state; the launcher enforces it. The config bakes DEFAULTS ONLY; every knob is overridable at
# runtime by the matching PROPNIX_* env var (§5), so a user or NixOS module can steer all games at once.
{
  lib,
  stdenv,
  runCommand,
  makeWrapper,
  writeText,
  symlinkJoin,
  wine,
  dxvk,
  vkd3d,
  prefixLower,
  propnix-launcher,
  gnutar,
  mkStoreSkeleton,
  mkWineReg,
  mangohud,
  sealing,
  wineDefaults, # a FUNCTION `{ lib, prefixLower, galaxyStub ? null }: config: { … }` (see wine-defaults.nix)
  mkPropnixDesktopItem,
  extractPeIcon,
  mkAppIcon,
  # Graceful no-op GOG Galaxy SDK stubs. Present on the winefex (aarch64) path; null on x86_64 (native wine),
  # where callPackage falls back to this default because the scope has no `galaxyStub` attr there.
  galaxyStub ? null,
}:
let
  # makeApp — the game-spec function, BOUND so `passthru.overrideTweaks` can re-invoke it with appended tweak
  # layers (`@gargs` captures the caller's arg set for that re-invocation).
  makeApp =
    {
      pname,
      appid,
  payload, # a derivation (e.g. fetchGogGalaxyBuild result); its store path is the game tree + launch cwd
  exe, # executable relative to payload, e.g. "Hollow Knight.exe"
  # Optional launch working directory, RELATIVE to the game dir (C:\game = payload). Null (default) → cwd is
  # the payload root (historical behaviour; unchanged for every existing game). Set it (the goggame.info
  # `workingDir`) for an engine that resolves its asset/data root from the CWD rather than the exe path and
  # needs the CWD to be the exe's subdirectory — e.g. Don't Starve (exe "bin/dontstarve.exe", workingDir "bin").
  workingDir ? null,
  # per-game tuning; layered over wineDefaults — the single home for how the app runs (graphics, mounts,
  # registry, dllOverrides, exeArgs, galaxyStubDlls, extraSystem32, setup/userRegScript, …; see
  # wine-defaults.nix for the full set + defaults). Either an attrset, or a FUNCTION `{ payload }: { … }` (so a
  # game whose mounts redirect its own payload — e.g. KSP's in-game-dir writes — interpolates the store path).
  tuning,
  name ? pname, # human-visible name (desktop entry + splash)
  autoIcon ? true, # extract the app icon from the exe's PE resources into a freedesktop hicolor theme
  # Optional high-res raster icon SOURCE (a PNG path, usually one shipped in the game's own data — e.g.
  # Factorio's 1024px `data/core/graphics/factorio.icon/Assets/factorio.png`). When set it REPLACES the exe
  # extraction as the icon source: `mkAppIcon` autocrops its transparent margins, recentres it on a square
  # canvas, and emits the same hicolor theme + splash png. Prefer this whenever the exe's PE icon is small
  # (Factorio's tops out at 48px → visibly pixelated upscaled) or off-centre in its canvas. Null → the exe.
  iconPng ? null,
  iconSymbolic ? null, # optional monochrome `-symbolic.svg` (currentColor) variant
  # Systems on which this title is known-broken → `meta.broken` on those systems (nix refuses to build it
  # without allowBroken). A list of Nix system strings, e.g. `[ "aarch64-linux" ]` for a game that only runs
  # under native x86_64 wine. `brokenReason` annotates why (surfaced in meta for humans; the reason itself
  # does not affect the build). The derivation still EVALUATES on a broken system — only building is refused —
  # so the package stays discoverable and the reason inspectable via `nix eval`.
  brokenSystems ? [ ],
  brokenReason ? null,
  # Extra tuning override LAYERS appended by `passthru.overrideTweaks` — the module-system override mechanism.
  # Each is a `finalConfig: <tuning override>` function, merged LAST (so it wins over the game's own tuning) and
  # resolved against the fixed-point config (so a derived entry recomputes). Empty for a normal build.
  tweaks ? [ ],
  # DLC framework (reusable across games). `dlc` is the attrset of AVAILABLE DLC packages for this game, each
  # a derivation whose tree overlays onto the game dir (game-relative paths, e.g. `data/<mod>/…` — typically a
  # `fetchGogGalaxyBuild` with `dlcId` set). The base package ships NO DLC; `passthru.withDlc`/`withAllDlc`
  # produce variants with DLC enabled (see below). `enabledDlc` is the INTERNAL selection those helpers set —
  # not meant to be passed directly; enabling it flips the game mount from a read-only bind of `payload` to a
  # read-only multi-lower OVERLAY (`lowerdir = payload:dlc1:dlc2`), so overlayfs MERGES the trees at mount time
  # (the game dir gains the DLC's files) with NO store duplication of the (large) base payload.
  dlc ? { },
  enabledDlc ? [ ],
  }@gargs:
    let
      # Resolve the per-game tuning (call it with `payload` if it's a function; see the arg doc), layer it over
  # the global defaults, then (in `flat`) strip the `reason` justifications down to the values the config emit
  # + mount table consume:
  #   flat = { d3d; graphics; dllOverrides = { <dll> = <order>; … }; userReg; fpsUserReg; vsyncUserReg;
  #            systemReg; userdefReg; brokenVariables; exeArgs; galaxyStubDlls; extraSystem32;
  #            setupScript; userRegScript; mounts }
  # Resolve a function-tuning, passing only the args it declares. Most take just `payload`; a tuning that
  # wants a CUSTOM partial skeleton (fine-grained writability — expose/writable-ify only some files) also
  # takes `mkStoreSkeleton`. Store-backed overlays get a whole-`lower` skeleton by default regardless (below).
  resolvedTuning =
    if lib.isFunction tuning then
      tuning (builtins.intersectAttrs (lib.functionArgs tuning) { inherit payload mkStoreSkeleton; })
    else
      tuning;
  # Resolve the tuning as a FIXED-POINT layer stack (module-system semantic): wineDefaults, then the per-game
  # tuning, then any `overrideTweaks` layers. wineDefaults is itself a config-function (`config: { … }`), so
  # its derived mount rows (de-Galaxy stubs from `galaxyStubDlls`, staged DLLs from `extraSystem32`) recompute
  # against the final, post-override config — which a `//`-merge cannot do. See sealing.resolveTuning.
  config = sealing.resolveTuning (
    [ (wineDefaults { inherit lib prefixLower galaxyStub; }) resolvedTuning ] ++ tweaks
  );
  flat = sealing.flattenTuning config;
  wineUser = prefixLower.wineUser; # single source of truth: the user the store prefix was built for


  # ── Declarative registry hives (per-game) ──────────────────────────────────────────────────────────────
  # system.reg (HKLM) + userdef.reg (HKU\.Default): the wine-generated base + this game's `systemReg`/
  # `userdefReg` overrides, baked in (mkWineReg) and bound READ-ONLY (never CoW). user.reg (HKCU) is handled
  # separately — NOT baked per-game: its base is wine's game-agnostic vanilla hive (seeded into the root
  # mount) and every propnix HKCU override is applied at RUNTIME by the three-way merge (see below).
  #
  # Each systemReg/userdefReg entry is `{ value; reason; type ? "REG_SZ"; }` (same shape as userReg — `reason`
  # justifies the non-default hive value); `flattenReg` drops the reason and emits the mkWineReg override list.
  flattenReg =
    hive: attrs:
    lib.concatLists (
      lib.mapAttrsToList (
        key: names:
        lib.mapAttrsToList (
          name: v:
          assert lib.assertMsg (v ? value && v ? reason)
            "propnix: systemReg/userdefReg entry ${hive}\\${key}\\${name} needs both `value` and `reason`";
          {
            key = "${hive}\\${key}";
            inherit name;
            inherit (v) value;
            type = v.type or "REG_SZ";
          }
        ) names
      ) attrs
    );
  systemRegFile = mkWineReg {
    inherit prefixLower;
    regName = "system.reg";
    overrides = flattenReg "HKLM" flat.systemReg;
    name = appid;
  };
  userdefRegFile = mkWineReg {
    inherit prefixLower;
    regName = "userdef.reg";
    overrides = flattenReg "HKU\\.Default" flat.userdefReg;
    name = appid;
  };
  # HKCU (user.reg) is NOT baked per-game. The base is wine's GAME-AGNOSTIC vanilla hive (`mkWineReg` with no
  # overrides = `${prefixLower}/user.reg` verbatim, no build). ALL propnix HKCU overrides — the Graphics
  # driver, DPI, the per-game `userReg`, fps/vsyncUserReg — are applied at RUNTIME by the three-way merge
  # (graphics.rs); nothing is baked, so a `$PROPNIX_*`-valued entry (which can't be known at build time) is
  # no longer a special case.
  baseUserReg = mkWineReg {
    inherit prefixLower;
    regName = "user.reg";
    overrides = [ ]; # game-agnostic → returns ${prefixLower}/user.reg (shared, free)
  };
  # The two read-only declarative hive binds (HKLM/HKU\.Default). The writable HKCU hive (user.reg) is the
  # ROOT overlay (below), NOT a bind: wine SAVES user.reg by writing `user.reg.tmp` and rename(2)-ing it over
  # `user.reg` INSIDE $WINEPREFIX, and rename can't replace a bind-mounted file (EBUSY) — so a file bind never
  # persists a single HKCU write. An overlay whose merged root IS $WINEPREFIX lets that temp+rename happen and
  # copies up only user.reg.
  regMounts = {
    "system.reg" = {
      type = "mount";
      source = "${systemRegFile}";
      mode = "ro";
    };
    "userdef.reg" = {
      type = "mount";
      source = "${userdefRegFile}";
      mode = "ro";
    };
  };

  # The game is installed at C:\game (drive_c/game) in the prefix — the payload bound in read-only there,
  # and the launch cwd. A game that must WRITE inside its own dir (KSP) overrides this row to an overlay in
  # its tuning. Default (no DLC): a read-only bind of the raw FOD. With DLC enabled (`enabledDlc` non-empty,
  # set by `withDlc`/`withAllDlc`): a read-only multi-lower OVERLAY that unions the base payload with each DLC
  # tree at mount time — the game dir gains the DLC's `data/<mod>/…` files with NO store copy of the base
  # payload. `readOnly = true` makes it a lowerdir-only overlay (base + DLCs all as lowers, NO upper) so the
  # union is strictly read-only, matching the base bind's `mode = "ro"` (not an ephemeral writable upper).
  # `skeleton = null`: a read-only lowerdir-only overlay never copies up, so it needs no CoW-from-store
  # metadata skeleton (and a multi-path `lower` isn't a single store tree to skeletonise anyway).
  gameMount = {
    "drive_c/game" =
      if enabledDlc == [ ] then
        {
          type = "mount";
          source = "${payload}";
          mode = "ro";
        }
      else
        {
          type = "overlay";
          # DLCs FIRST, base payload LAST: overlayfs gives the leftmost lower priority, so a DLC that MODIFIES
          # a base file (e.g. GOG ships Factorio: Space Age with its own factorio.exe + reworked base data)
          # wins over the base's version, and the base fills in everything the DLC doesn't ship.
          lower = lib.concatStringsSep ":" (map (d: "${d}") enabledDlc ++ [ "${payload}" ]);
          skeleton = null;
          readOnly = true;
        };
  };

  # Every store-backed `overlay` row gets a data-only skeleton built from its OWN `lower` by DEFAULT — so a
  # game just writes `type = "overlay"` and gets writable CoW-from-store for free (no seeding, shared store
  # inode/page-cache). An explicit `skeleton` is honoured: a path uses that tar; `null` opts OUT to a plain
  # overlay (for an empty-lower ephemeral overlay like Temp, where nothing is ever copied up). An overlay's
  # `lower` is always a store path (lowers never carry runtime $VARs), so mkStoreSkeleton evaluates here.
  withDefaultSkeletons = lib.mapAttrs (
    target: m:
    if (m.type or "mount") == "overlay" && !(m ? skeleton) then
      if lib.hasPrefix (builtins.storeDir + "/") m.lower then
        m
        // {
          skeleton = "${mkStoreSkeleton {
            payload = m.lower;
            name = "${appid}-${lib.replaceStrings [ "/" " " ] [ "_" "_" ] target}";
          }}";
        }
      else
        throw ''
          propnix: overlay mount "${target}" (game "${appid}") has lower "${m.lower}", which is not in
          ${builtins.storeDir}. A default CoW-from-store skeleton can only be built from a store path (it is
          built at eval time, so the lower must exist in the store). Either:
            • set `skeleton = null` for a plain overlay (a user-owned or ephemeral lower — e.g. Temp), or
            • provide `skeleton` explicitly.''
    else
      m
  );

  # Icon: extract the exe's PE icon into a freedesktop hicolor theme (all sizes → share/icons/…), found
  # natively via $XDG_DATA_DIRS once installed. `${iconTree}/icon.png` (largest size) feeds the splash.
  iconName = "org.propnix.${appid}";
  # A high-res raster source (`iconPng`) wins over the exe's PE resources; else extract from the exe if
  # `autoIcon`; else no icon. Both produce the same layout (hicolor theme + share/propnix/<id>.png splash).
  iconTree =
    if iconPng != null then
      mkAppIcon { src = iconPng; inherit iconName; }
    else if autoIcon then
      extractPeIcon { inherit payload exe iconName; }
    else
      null;
  splashIcon = if iconTree != null then "${iconTree}/share/propnix/${iconName}.png" else null;

  # Informational: which emulation the scope wired for this host (aarch64 = wine+FEX/ARM64EC, x86_64 =
  # native wine). The launcher does NOT branch on this — its behaviour is arch-identical.
  backend = if stdenv.hostPlatform.isAarch64 then "winefex" else "wine";

  # The §7 seal: targeted scrub + the structured DLL-override map + the remaining meant vars. The launcher
  # joins dllOverrides into WINEDLLOVERRIDES (merging the DXVK/vkd3d entries) at launch; USER/LOGNAME pin
  # the wine profile to the store lower's user; WINEDEBUG's launch default is -all (PROPNIX_WINEDEBUG wins).
  seal = sealing.mkSeal {
    dllOverrides = flat.dllOverrides;
    setEnv = {
      WINEDEBUG = "-all";
      USER = wineUser;
      LOGNAME = wineUser;
    };
  };

  # The prefix ROOT (target ""): a MOUNT of the persistent WINE-backend prefix dir. propnix-mount realizes any
  # writable mount that lacks some child mountpoint as `overlay(lower=childSkeleton, upper=source)` — it
  # computes the top-level mountpoints (system.reg, drive_c/…, dosdevices, …) from the mount table at runtime
  # and puts them in the read-only child-skeleton lower, so the writable upper (<state>/wine/prefix) only ever
  # holds user.reg + wine's HKCU writes, never a mountpoint stub. The game-agnostic base user.reg is SEEDED in
  # on first launch (a one-file store dir), then the three-way merge layers the propnix overrides on top.
  userRegDir = runCommand "${appid}-userreg" { } ''
    mkdir -p "$out"
    cp ${baseUserReg} "$out/user.reg"
  '';
  rootMount."" = {
    type = "mount";
    source = "$PROPNIX_STATE/wine/prefix";
    createIfNotExist = true;
    seed = "${userRegDir}";
  };

  # The complete WINEPREFIX mount table (view-relative targets): the two read-only hive binds (regMounts) +
  # default game bind + the defaults & per-game tuning (flat.mounts — which now CARRIES the de-Galaxy stubs
  # and staged system32 runtime DLLs, derived in wineDefaults from galaxyStubDlls/extraSystem32) + the root
  # mount. propnix-mount supplies every mount's missing child mountpoints from the table (no build-time
  # skeleton of the table).
  finalMounts = withDefaultSkeletons (regMounts // gameMount // flat.mounts // rootMount);

  configFile = writeText "propnix-${appid}.json" (
    builtins.toJSON {
      schema = 1;
      inherit appid name exe backend;
      # Launch cwd relative to C:\game (null → the payload root); see the `workingDir` arg. toJSON drops a
      # null field, and config.rs defaults `working_dir` to None, so existing games are unaffected.
      workingDir = workingDir;
      exeArgs = flat.exeArgs;
      icon = splashIcon; # largest extracted PE icon (for the splash), or null
      payload = "${payload}"; # the raw FOD game tree; the launch cwd (galaxy DLLs are stubbed via mount rows)
      emulators = {
        wine = "${wine}";
        prefixLower = "${prefixLower}";
        dxvk = "${dxvk}";
        vkd3d = "${vkd3d}";
        # `tar` for the linked propnix_mount to extract overlay `skeleton` tars (sparse + xattr aware). (The
        # mount + prefetch helpers are compiled INTO propnix-launcher now, not separate binaries.)
        tar = "${gnutar}/bin/tar";
        # MangoHud package root — under PROPNIX_BENCH the launcher puts `<mangohud>/share` on the child's
        # XDG_DATA_DIRS to load MangoHud's Vulkan implicit layer (covers DXVK + vkd3d; no GL hook).
        mangohud = "${mangohud}";
      };
      defaults = {
        graphics = flat.graphics;
        d3d = flat.d3d;
      };
      # Env vars the launcher unsets before anything else (per-game escape hatch from a user's global
      # PROPNIX_* that breaks a title — e.g. Skyrim lists PROPNIX_FPS/PROPNIX_DPI). From wineDefaults +
      # per-game tuning (union). See wine-defaults.nix.
      brokenVariables = flat.brokenVariables;
      # HKCU overrides re-applied every launch (list of { key; name; value; type; }); e.g. the black
      # pre-render window colors. From wineDefaults.userReg, mergeable per-game.
      userReg = flat.userReg;
      # HKCU overrides applied ONLY when PROPNIX_FPS > 0 (fixed cap), with `$VAR` values resolved at launch —
      # a game's own frame-cap/vsync keys as a function of `$PROPNIX_FPS`. Same list shape as userReg but NOT
      # baked into the base user.reg (runtime-only value); the launcher folds them in / prunes them per the FPS
      # mode. From wineDefaults.fpsUserReg, mergeable per-game.
      fpsUserReg = flat.fpsUserReg;
      # The VRR counterpart: HKCU overrides applied ONLY when PROPNIX_FPS == 0 (enable the game's vsync). Same
      # list shape/semantics as fpsUserReg. From wineDefaults.vsyncUserReg, mergeable per-game.
      vsyncUserReg = flat.vsyncUserReg;
      # Optional per-game setup script (a store-path executable the game built) the launcher runs before wine
      # — the escape hatch for game-specific prefix setup (e.g. Skyrim's display + quality ini seeding). A
      # non-zero exit aborts the launch. Null unless the game passes `setupScript` (toJSON coerces a
      # derivation to its outPath, null → null).
      setupScript = flat.setupScript;
      # Optional escape hatch for DYNAMIC HKCU overrides: a store-path executable whose JSON stdout is a set of
      # HKCU overrides applied this launch (runtime-derived → overrides static userReg). Null unless the game
      # passes `userRegScript` (toJSON coerces a derivation to its outPath, null → null).
      userRegScript = flat.userRegScript;
      # The complete WINEPREFIX mount table (finalMounts), all keyed by paths RELATIVE to the (tmpfs) view
      # root: the two read-only hive binds (regMounts) + the default game bind (gameMount) + the defaults &
      # per-game tuning (flat.mounts — including the derived de-Galaxy stubs + staged system32 DLLs, and a
      # `drive_c/game` override that wins for KSP) + the persistent root mount (rootMount). The launcher joins
      # each target to the view root, $VAR-expands the sources, filters/sorts, and lays each with propnix-mount.
      mounts = finalMounts;
      inherit seal;
    }
  );

  wrapper = runCommand "${pname}-launcher-wrapper" { nativeBuildInputs = [ makeWrapper ]; } ''
    mkdir -p "$out/bin"
    makeWrapper ${propnix-launcher}/bin/propnix-launcher "$out/bin/${pname}" \
      --add-flags "--config ${configFile}"
  '';

  desktopItem = mkPropnixDesktopItem {
    inherit appid name iconSymbolic;
    exec = pname; # resolves from PATH once the package is installed
    hasIcon = iconTree != null; # set Icon=<id> only if the raster theme is actually installed
    # wine's top-level window class ≈ the exe basename (lowercased). Confirm at Tier-3 verification.
    startupWMClass = lib.toLower (baseNameOf exe);
  };
  # Broken on the current build system? (a game listed as broken here, e.g. KSP on aarch64 where the FEX
  # codegen bug crashes it at the menu). `meta.broken` makes nix refuse to BUILD it without allowBroken,
  # while the derivation still evaluates — so it stays discoverable and the reason inspectable.
  isBroken = lib.elem stdenv.hostPlatform.system brokenSystems;
in
symlinkJoin {
  name = pname;
  paths = [
    wrapper
    desktopItem
  ]
  ++ lib.optional (iconTree != null) iconTree; # the freedesktop hicolor raster theme
  passthru = {
    inherit configFile payload backend;
    launcher = propnix-launcher;
    # User-overridable package (module-system style). `f` is a `finalConfig: <tuning override>` layer; it's
    # appended to the tweak stack and re-evaluated, so it WINS over the game's own tuning AND propagates to any
    # derived entry:  hollow-knight.overrideTweaks (old: { graphics = { value = "x11"; reason = "…"; }; })
    overrideTweaks = f: makeApp (gargs // { tweaks = (gargs.tweaks or [ ]) ++ [ f ]; });
    # DLC selection (see the `dlc`/`enabledDlc` args). `dlc` re-exposes the game's available-DLC attrset so a
    # caller can pick by name. `withDlc` takes a SELECTOR `dlc: [ <chosen> ]` (e.g.
    # `factorio.withDlc (dlc: with dlc; [ space-age ])`) and returns a variant with just those enabled;
    # `withAllDlc` enables every declared DLC. Both re-invoke makeApp with `enabledDlc` set, which turns the
    # game mount into the merged read-only overlay (no base-payload duplication in the store).
    inherit dlc;
    withDlc = select: makeApp (gargs // { enabledDlc = select dlc; });
    withAllDlc = makeApp (gargs // { enabledDlc = builtins.attrValues dlc; });
  };
  meta = {
    description = "${name} — propnix wine app (${backend})";
    mainProgram = pname;
    broken = isBroken;
  }
  // lib.optionalAttrs (brokenReason != null) { brokenReason = brokenReason; };
}
;
in
makeApp

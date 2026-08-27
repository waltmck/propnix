# builders/thin.nix — mkThinApp, the backend-AGNOSTIC builder for THIN-mode games (propnix-launcher
# `mode = "thin"`): a native/box64/FEX Linux game with no WINEPREFIX. It owns everything that does NOT
# depend on WHICH emulator runs the ELF: the read-only game-tree overlay (`payloads` unioned, + the
# zero-copy exec-bit metacopy fix), the save/state binds, the icon, the splash / single-instance /
# window-watcher, and the THIN config JSON emission. The per-emulator specifics arrive as a LAUNCH BLOCK —
# `{ backend; emulator; env; ldLibraryPath; mangohud; }` — computed by a backend registry entry
# (lib/backends/{box64,fex}) and validated + routed here by backends/mk-thin-build.nix, so box64, FEX, and
# native are siblings that share this core rather than forks of it. Packaging tail = mkLauncherPackage.
{
  lib,
  writeText,
  runCommand,
  gnutar,
  sealing,
  mkLauncherPackage,
  mkAppIcon,
  extractUnityIcon,
  mkStoreSkeleton,
}:
{
  pname,
  appid,
  name ? pname,
  # The GAME TREES: a LIST of derivations mounted READ-ONLY at the view's game dir and run from there,
  # in MOUNT PRIORITY order (leftmost wins). Enabled DLC leads the list, then the payload depots —
  # backends/mk-thin-build.nix assembles it — because DLC is game content that unions ahead of the base,
  # and because each entry gets its own exec-bit fix layer below (a DLC that ships its own build of the
  # game needs its executable made runnable just as the base depot's does).
  # One entry → a read-only bind; several → a lowerdir-only overlayfs UNION at mount time, the free
  # multi-depot merge (no build-time copy).
  payloads,
  # NON-GAME layers unioned ABOVE every game tree: the backend's own overlay (the patched-exe layer) and
  # the app's extra trees (the offline Steam-entitlement settings). Store-path strings. Enabled DLC is NOT
  # here — it is game content and rides in `payloads`, where it gets its own exec-bit fix layer in its own
  # position. Empty = the lowers are exactly the game trees.
  extraLowers ? [ ],
  # Game-dir-relative paths that must carry the EXEC bit (box64 needs +x on the ELF it loads; Steam depots
  # ship 0444) — reproduced via one sparse metacopy skeleton PER GAME TREE, each stacked in that tree's own
  # position (zero data copy). `[]` → no fix, for a backend that supplies its own already-+x copies (FEX
  # and the native face, which must patch PT_INTERP anyway — see builders/patched-exes.nix).
  executables ? [ exe ],
  # Game-dir-relative files to ERASE from the game dir at runtime — emitted as propnix-mount `whiteout`
  # entries, so the file is genuinely ABSENT with NO store copy of the tree. (E.g. HK's Steam-only
  # libsteam_api.so must be ABSENT so its plugin loader cleanly reports "no online subsystems"; an
  # empty-but-present stub instead makes its dlopen throw → a black screen.)
  maskFiles ? [ ],
  exe, # the executable, RELATIVE to the game dir
  exeArgs ? [ ],
  # Offline enforcement: false → the launcher unshares a netns for the game (see app-options `online`).
  online ? true,
  workingDir ? null,
  # OUTER-phase per-game setup hook (the top-level `setupScript` option): a store-path executable run
  # before the view is assembled. Backend-independent by nature — see app-options.
  setupScript ? null,
  # Save/state binds: `{ src; dst; ro ? false; create ? true; }` — bind `src` (persistent,
  # `$VAR`-expandable) at `dst` under the game's $HOME view (the game writes its native path; data
  # persists in a propnix dir).
  saveBinds ? [ ],
  # `{ png; symbolic; auto; }` (the mkApp `icon` record): an explicit raster source wins; else `auto`
  # extracts the Unity Linux app icon (UnityPlayer.png) from the game tree — LOUDLY failing the build for
  # a non-Unity game (set icon.png or icon.auto = false); else symbolic-only.
  icon ? {
    png = null;
    symbolic = null;
    auto = true;
  },
  splash ? true,
  singleInstance ? true,
  windowWatch ? true,
  # `{ systems; reason; }` → meta.broken (see mkLauncherPackage).
  broken ? {
    systems = [ ];
    reason = null;
  },
  # ── the per-emulator LAUNCH BLOCK (from a backend registry entry, via mk-thin-build) ──
  backend, # informational: "box64" | "fex" | "native" (the launcher does not branch on it)
  emulator ? null, # program that runs the ELF (box64 / FEXInterpreter path), or null → exec the ELF natively
  env ? { }, # child env set after the scrub ($VAR-expandable); the game's unified `env` already merged over the backend defaults
  ldLibraryPath ? "", # box64/native lib union; "" for FEX (which uses a rootfs, not host-lib bridging)
  # The env-var namespaces scrubbed before the seal — single-sourced from sealing.defaultScrub (§7:
  # targeted scrub, never env_clear+allowlist).
  scrubPrefixes ? sealing.defaultScrub,
  mangohud, # MangoHud package root (PROPNIX_BENCH shim preload; see thin.rs)
}:
let
  # The exec-bit fix: ONE metacopy skeleton PER GAME TREE, each a sparse, zero-data-copy mirror of its own
  # tree whose `executables` stubs are 0755. The launcher mounts each as `skeleton::tree` (userxattr) and
  # puts the result in THAT TREE'S place in the lower stack, so priority is preserved exactly.
  #
  # Per-tree, not one layer built from the primary payload, because a skeleton mirrors its WHOLE tree (an
  # executables-only skeleton was tried and broke box64's UnityPlayer.so load). A single such layer stacked
  # at the top therefore shadows every higher-priority tree — a DLC that ships a COMPLETE build of the game
  # rather than an additive overlay (Factorio's Space Age, on both GOG and Steam) would silently lose to the
  # base engine — and it leaves an executable that only the higher tree supplies at 0444.
  #
  # Built only when there are executables to fix (`executables = [ ]` — FEX and the native face, which
  # carry their own already-+x exe overlay — skips the mechanism entirely). `maskFiles` are handled
  # separately as runtime whiteout entries, NOT here.
  usesSkeleton = executables != [ ];
  # Keyed on the TREE, not its position in the list. With an index-based name the same depot gets a
  # different derivation name in every DLC selection that reorders the list — so identical skeletons are
  # rebuilt and stored once per selection (the base tree as `-exe-1` alongside `-exe-0` from the vanilla
  # build, two copies of the same multi-thousand-file tar). Keyed on the tree's store hash, one skeleton
  # per (tree, executables) exists once and is shared by every selection that mounts it.
  modeFixes = map (tree: {
    skeleton = "${mkStoreSkeleton {
      payload = tree;
      name = "${appid}-exe-${lib.substring 0 8 (baseNameOf "${tree}")}";
      inherit executables;
    }}";
    lower = "${tree}";
  }) payloads;
  # A declared executable that is in NO tree would otherwise reach the launcher as a 0444 file and fail at
  # exec with a bare EACCES. mkStoreSkeleton skips what its own tree lacks (an executable lives in one tree,
  # not all of them), so the "exists somewhere" check belongs here, once, across the whole set.
  #
  # `-f`, matching the skeleton's own chmod test. `-e` would pass a directory-valued entry (a path with the
  # leaf omitted) that every skeleton then skips — build green, launcher execve's a directory, bare EACCES
  # at launch. Before the per-tree split this was a hard build error, and it stays one.
  executablesPresent =
    runCommand "${appid}-executables-present" { } ''
      ${lib.concatMapStrings (e: ''
        found=
        for tree in ${lib.escapeShellArgs (map (p: "${p}") payloads)}; do
          if [ -f "$tree"/${lib.escapeShellArg e} ]; then found=1; break; fi
        done
        if [ -z "$found" ]; then
          echo "propnix (${pname}): declared executable '${e}' is not a regular file in any game tree" >&2
          exit 1
        fi
      '') executables}
      mkdir -p "$out"
    '';
  gameModeFix = lib.optionalAttrs usesSkeleton {
    gameModeFixes = modeFixes;
  };
  # The lowers that need NO exec-bit fix, highest-priority first: `extraLowers` (the backend's own overlays,
  # the offline Steam-entitlement settings tree, a game's own extra trees). The fixed game trees are stacked
  # BELOW these by the launcher, in `payloads` order. Without the fix (executables = [ ]) the game trees are
  # plain lowers here.
  gameLowers = extraLowers ++ lib.optionals (!usesSkeleton) (map (d: "${d}") payloads);

  iconName = "org.propnix.${appid}";
  iconTree =
    if icon.png != null then
      mkAppIcon {
        src = icon.png;
        inherit iconName;
      }
    else if icon.auto then
      extractUnityIcon { inherit payloads iconName; }
    else
      null;
  splashIcon = if iconTree != null then "${iconTree}/share/propnix/${iconName}.png" else null;

  configFile = writeText "propnix-${appid}.json" (
    builtins.toJSON (
      {
        schema = 1;
        mode = "thin";
        appId = appid;
        inherit name;
        icon = splashIcon;
        inherit
          gameLowers
          emulator
          exe
          env
          ;
        workingDir = workingDir;
        exeArgs = exeArgs;
        payload = "${builtins.head payloads}";
        online = online;
        ldLibraryPath = ldLibraryPath;
        inherit scrubPrefixes;
        binds = map (b: {
          inherit (b) src dst;
          ro = b.ro or false;
          create = b.create or true;
          # `type = "file"` → the source is a regular file, so `create` touches it rather than mkdir'ing
          # it (redirecting one file out of a directory that is itself bound elsewhere). Same vocabulary as
          # the wine mount table's `type`.
          type = b.type or "mount";
        }) saveBinds;
        inherit splash singleInstance windowWatch;
        tar = "${gnutar}/bin/tar";
        mangohud = mangohud;
      }
      // gameModeFix
      # Omitted when unset so a game without one emits no key (config.rs defaults it to None).
      // lib.optionalAttrs (setupScript != null) { setupScript = "${setupScript}"; }
      # Game-dir-relative files to erase at runtime (→ propnix-mount whiteout entries). Omitted when empty
      # so a game with no masks is unaffected; config.rs defaults `maskFiles` to [].
      // lib.optionalAttrs (maskFiles != [ ]) { maskFiles = maskFiles; }
    )
  );
in
mkLauncherPackage {
  inherit
    pname
    appid
    name
    exe
    configFile
    iconTree
    broken
    ;
  iconSymbolic = icon.symbolic;
  description = "${name} — propnix native/${backend} app";
  extraChecks = lib.optional usesSkeleton executablesPresent;
  extraPassthru = {
    inherit payloads backend;
    # The tree the game actually runs from = the highest-priority one (a complete-tree DLC when enabled).
    unwrapped = builtins.head payloads;
  };
}

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
  # The game tree(s): a LIST of derivations mounted READ-ONLY at the view's game dir and run from there.
  # One entry → a read-only bind; several → a lowerdir-only overlayfs UNION at mount time (leftmost wins),
  # the free multi-depot merge (no build-time copy).
  payloads,
  # DLC (or other) trees to union ABOVE the base game tree (highest overlay priority, DLC-first — matching
  # the wine DLC overlay). Store-path strings. Empty = the lowers are exactly the base game.
  extraLowers ? [ ],
  # Game-dir-relative paths that must carry the EXEC bit (box64/native exec require +x; Steam depots ship
  # 0444) — reproduced via a sparse metacopy skeleton of the exe-bearing tree (`payloads` head), stacked
  # above the union (zero data copy). `[]` → no fix (e.g. FEX's already-+x patched exe).
  executables ? [ exe ],
  # Game-dir-relative files to ERASE from the game dir at runtime — emitted as propnix-mount `whiteout`
  # entries, so the file is genuinely ABSENT with NO store copy of the tree. (E.g. HK's Steam-only
  # libsteam_api.so must be ABSENT so its plugin loader cleanly reports "no online subsystems"; an
  # empty-but-present stub instead makes its dlopen throw → a black screen.)
  maskFiles ? [ ],
  exe, # the executable, RELATIVE to the game dir
  exeArgs ? [ ],
  workingDir ? null,
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
  # The metacopy skeleton over the exe-bearing tree (`payloads` head): a sparse, zero-data-copy layer that
  # makes `executables` +x. The launcher mounts `skeleton::(head)` (userxattr) as a read-only layer ABOVE
  # the other trees. Built only when there are executables to fix; `maskFiles` are handled separately as
  # runtime whiteout entries, NOT here.
  #
  # KNOWN CONSTRAINT: the skeleton mirrors the WHOLE primary tree (an executables-only skeleton was tried
  # and broke box64's UnityPlayer.so load), and the launcher stacks the binfix layer at the very top — so a
  # thin EXTRA lower (DLC / FEX's patched exe) that MODIFIES a primary-tree file is shadowed by the primary
  # version when the exec-bit fix is active. No current thin game combines both; a future thin-DLC title
  # needs the launcher to stack the binfix directly above the primary tree instead.
  primaryTree = builtins.head payloads;
  restTrees = builtins.tail payloads;
  usesSkeleton = executables != [ ];
  modeFixSkel = mkStoreSkeleton {
    payload = primaryTree;
    name = "${appid}-exe";
    inherit executables;
  };
  gameModeFix = lib.optionalAttrs usesSkeleton {
    gameModeFix = {
      skeleton = "${modeFixSkel}";
      lower = "${primaryTree}";
    };
  };
  # The game lowers, highest-priority first: any `extraLowers` (DLC, DLC-first) ABOVE the base tree; then
  # the data trees (when the skeleton carries the primary tree) or all payloads. The skeleton (if any) is
  # stacked above these by the launcher.
  gameLowers = extraLowers ++ map (d: "${d}") (if usesSkeleton then restTrees else payloads);

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
        ldLibraryPath = ldLibraryPath;
        inherit scrubPrefixes;
        binds = map (b: {
          inherit (b) src dst;
          ro = b.ro or false;
          create = b.create or true;
        }) saveBinds;
        inherit splash singleInstance windowWatch;
        tar = "${gnutar}/bin/tar";
        mangohud = mangohud;
      }
      // gameModeFix
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
  extraPassthru = {
    inherit payloads backend;
    unwrapped = primaryTree;
  };
}

# builders/wine.nix — mkWineApp: turn a resolved game config into an installable package that invokes
# propnix-launcher in PREFIX (wine) mode. Always driven by mkApp via the wine backend registry entry
# (lib/backends/wine): it receives the identity, payloads, the PRE-RESOLVED wine tuning (`resolvedConfig`
# — the defaults layer + per-game tuning + `.apply` overrides, merged by evalModules), and the DLC
# selection; the override surface lives in mkApp, not here.
#
# ARCH-TRANSPARENT: the emulator set (wine/dxvk/vkd3d/prefixLower) is injected from the scope, which wires
# the arch-appropriate packages (aarch64 → Hangover wine + FEX + native ARM64EC DXVK/vkd3d; x86_64 → the
# SAME wine source built native + standard x86_64 DXVK/vkd3d, no FEX). The wrapper, launcher, config, game
# spec, and tuning are IDENTICAL across arches, and the EXTERNAL behaviour (every PROPNIX_* env var) is
# the same — the emulation is handled transparently below the launcher.
#
# The configFile — a writeText JSON with all store paths interpolated — IS the launcher↔wrapper interface
# (PLAN2 §4): Nix computes the intended state; the launcher enforces it. The config bakes DEFAULTS ONLY;
# every knob is overridable at runtime by the matching PROPNIX_* env var (§5). Packaging tail =
# mkLauncherPackage.
{
  lib,
  stdenv,
  runCommand,
  writeText,
  wine,
  dxvk,
  vkd3d,
  prefixLower,
  gnutar,
  mkStoreSkeleton,
  mkWineReg,
  mangohud,
  sealing, # supplies flattenTuning + mkSeal (the merge/resolve is done upstream in mkApp)
  mkLauncherPackage,
  extractPeIcon,
  mkAppIcon,
}:
{
  pname,
  appid,
  name ? pname,
  # The game tree(s): head = the primary tree (C:\game, the launch cwd). A wine build is normally ONE tree;
  # extra trees (co-base depots) union read-only above it exactly like DLC — never silently dropped.
  payloads,
  exe, # executable relative to the game dir, e.g. "Hollow Knight.exe"
  # Launch arguments for the exe (the single, backend-shared source of exe args).
  exeArgs ? [ ],
  # Offline enforcement: false → the launcher unshares a netns for the game (see app-options `online`).
  online ? true,
  # Optional launch working directory, RELATIVE to the game dir (C:\game). Null → the game dir itself.
  # For engines that resolve assets from the CWD rather than the exe path (Don't Starve: "bin").
  workingDir ? null,
  # The fully-resolved wine tuning (mkApp's `config.wine`), used VERBATIM — nothing is re-layered here.
  resolvedConfig,
  # Save/state binds `{ src; dst; ro ? false; create ? true; }` with dst relative to the wine profile HOME
  # (drive_c/users/<wineUser>/) — each derives one bind-mount row, merged BEFORE the tuning's `mounts` so a
  # game/user can still override per-target. Binds only: overlay-style save persistence (KSP) stays a
  # hand-written `wine.mounts` row.
  saveBinds ? [ ],
  # OUTER-phase per-game setup hook (the top-level `setupScript` option): a store-path executable run
  # before the prefix is assembled. Not a wine tuning knob — the thin backends honour the same option.
  setupScript ? null,
  # Extra child environment (the unified mkApp `env`), folded into seal.setEnv — values $VAR-expanded by
  # the launcher. Reserved launcher-owned names are rejected here (eval-time), keeping the option honest.
  env ? { },
  # `{ png; symbolic; auto; }` (the mkApp `icon` record): an explicit raster source wins (autocropped +
  # recentred, lib/icons/from-png.nix); else `auto` extracts the exe's PE resources; else symbolic-only.
  icon ? {
    png = null;
    symbolic = null;
    auto = true;
  },
  # `{ systems; reason; }` → meta.broken (see mkLauncherPackage).
  broken ? {
    systems = [ ];
    reason = null;
  },
  # DLC framework: `dlc` = the AVAILABLE set (name → overlay-tree derivation); `enabledDlc` = the selected
  # derivations (mkApp resolves names). Enabling flips the game mount from a read-only bind to a read-only
  # multi-lower OVERLAY (DLC-first), merging the trees at mount time with NO store copy of the base.
  dlc ? { },
  enabledDlc ? [ ],
  # App-level extra trees unioned with the DLC (mkApp's `extraLowers`) — same priority band, same
  # read-only merge; for content that is neither payload nor DLC.
  extraLowers ? [ ],
  # Game-dir-relative files to ERASE from the game tree at runtime (propnix-mount `whiteout` rows over
  # C:\game — true absence, no store copy). E.g. a Steam build's steam_api64.dll → the plugin loader
  # reports "no online subsystem" and runs offline. (A STATICALLY imported SDK needs the opposite — a real
  # no-op stub: `galaxyStubDlls`.)
  maskFiles ? [ ],
  # Whether this build carries the gbe_fork offline Steam-entitlement shim (`steam.emu.enable`). Baked so
  # the launcher knows to seat the stored Steam account's SteamID64 into the shim's global settings inside
  # the per-launch view (launcher steamid.rs) — identity stays a RUNTIME, per-host fact, never a store
  # path's content (see builders/steam-offline-entitlement.nix), and a GOG game's launch never touches the
  # credential store.
  steamEmu ? false,
  # The baked GL/Vulkan fallback stack (builders/gl-fallback.nix — field contract and rationale there) —
  # activated by the launcher when `/run/opengl-driver` is absent (non-NixOS) or `forced` (the `mesa` knob).
  fallbackGl,
}:
let
  payload = builtins.head payloads; # the primary tree: C:\game root, launch cwd, icon/exe source
  coBaseTrees = builtins.tail payloads; # extra co-base depots, unioned read-only above the primary

  # The resolved wine tuning, used verbatim. `flat` strips the `reason` justifications down to the values
  # the config emit + mount table consume:
  #   flat = { d3d; graphics; dllOverrides = { <dll> = <order>; … }; userReg; fpsUserReg; vsyncUserReg;
  #            systemReg; userdefReg; brokenVariables; galaxyStubDlls; extraSystem32;
  #            userRegScript; mounts }
  flat = sealing.flattenTuning resolvedConfig;
  wineUser = prefixLower.wineUser; # single source of truth: the user the store prefix was built for

  # ── Declarative registry hives (per-game) ────────────────────────────────────────────────────────────
  # system.reg (HKLM) + userdef.reg (HKU\.Default): the wine-generated base + this game's `systemReg`/
  # `userdefReg` overrides, baked in (mkWineReg) and bound READ-ONLY (never CoW). user.reg (HKCU) is
  # handled separately — NOT baked per-game: its base is wine's game-agnostic vanilla hive (seeded into
  # the root mount) and every propnix HKCU override is applied at RUNTIME by the three-way merge.
  #
  # Each systemReg/userdefReg entry is `{ value; reason; type ? "REG_SZ"; }` (same shape as userReg);
  # `flattenReg` drops the reason and emits the mkWineReg override list.
  flattenReg =
    hive: attrs:
    lib.concatLists (
      lib.mapAttrsToList (
        key: names:
        lib.mapAttrsToList (
          name: v:
          assert lib.assertMsg (
            v ? value && v ? reason
          ) "propnix: systemReg/userdefReg entry ${hive}\\${key}\\${name} needs both `value` and `reason`";
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
  # HKCU (user.reg) base: wine's GAME-AGNOSTIC vanilla hive (`mkWineReg` with no overrides =
  # `${prefixLower}/user.reg` verbatim, no build). ALL propnix HKCU overrides — the Graphics driver, DPI,
  # per-game userReg, fps/vsyncUserReg — are applied at RUNTIME by the three-way merge (graphics.rs).
  baseUserReg = mkWineReg {
    inherit prefixLower;
    regName = "user.reg";
    overrides = [ ]; # game-agnostic → returns ${prefixLower}/user.reg (shared, free)
  };
  # The two read-only declarative hive binds. The writable HKCU hive (user.reg) is the ROOT overlay
  # (below), NOT a bind: wine SAVES user.reg via `user.reg.tmp` + rename(2), and rename can't replace a
  # bind-mounted file (EBUSY) — an overlay whose merged root IS $WINEPREFIX lets the temp+rename happen
  # and copies up only user.reg.
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

  # The game is installed at C:\game (drive_c/game) in the prefix — the primary tree bound read-only
  # there. A game that must WRITE inside its own dir (KSP) overrides this row to an overlay in its tuning.
  # With DLC enabled and/or co-base trees (a multi-payload build): a read-only multi-lower OVERLAY that
  # unions everything at mount time — DLC FIRST (a DLC that modifies a base file wins), then the payloads
  # in their declared order (first wins). `readOnly = true` = lowerdir-only, NO upper; `skeleton = null`
  # (a read-only overlay never copies up; a multi-path lower isn't a single tree to skeletonise anyway).
  extraGameLowers =
    map (d: "${d}") enabledDlc ++ map (d: "${d}") extraLowers ++ map (d: "${d}") coBaseTrees;
  gameMount = {
    "drive_c/game" =
      if extraGameLowers == [ ] then
        {
          type = "mount";
          source = "${payload}";
          mode = "ro";
        }
      else
        {
          type = "overlay";
          lower = lib.concatStringsSep ":" (
            map (d: "${d}") enabledDlc
            ++ map (d: "${d}") extraLowers
            ++ [ "${payload}" ]
            ++ map (d: "${d}") coBaseTrees
          );
          skeleton = null;
          readOnly = true;
        };
  };

  # Derived save-bind rows: one bind mount per `saveBinds` entry, at the wine profile home. `type` comes
  # from the row (default "mount"; these rows bypass flattenTuning's `{ type = "mount"; }` stamping), so a
  # game can declare `type = "file"` once and have it work on wine and thin alike — which is how a single
  # file is redirected out of a directory that is itself bound (factorio's cache files). `ro` maps to
  # `mode = "ro"`, omitted when false. Merged BEFORE flat.mounts so the tuning wins per-target.
  # `dst` is joined onto the profile home BY STRING, so an absolute path would silently produce a nonsense
  # row — refuse legibly (an absolute target belongs in `wine.mounts`; THIN saveBinds do support them).
  saveMounts = lib.listToAttrs (
    map (
      b:
      lib.throwIf (lib.hasPrefix "/" b.dst)
        "propnix (${pname}): wine saveBinds dst must be relative to the wine profile home, got '${b.dst}' — use a wine.mounts row for an absolute target."
        (
          lib.nameValuePair "drive_c/users/${wineUser}/${b.dst}" (
            {
              type = b.type or "mount";
              source = b.src;
              createIfNotExist = b.create or true;
            }
            // lib.optionalAttrs (b.ro or false) { mode = "ro"; }
          )
        )
    ) saveBinds
  );

  # Every store-backed `overlay` row gets a data-only skeleton built from its OWN `lower` by DEFAULT — so
  # a game just writes `type = "overlay"` and gets writable CoW-from-store for free (no seeding, shared
  # store inode/page-cache). An explicit `skeleton` is honoured: a path uses that tar; `null` opts OUT to
  # a plain overlay (nothing ever copied up — ephemeral/read-only overlays).
  withDefaultSkeletons = lib.mapAttrs (
    target: m:
    if (m.type or "mount") == "overlay" && !(m ? skeleton) then
      if lib.hasPrefix (builtins.storeDir + "/") m.lower then
        m
        // {
          skeleton = "${mkStoreSkeleton {
            payload = m.lower;
            # replaceStrings keeps the historical names for existing targets; sanitizeDerivationName then
            # guarantees validity for any target character it doesn't cover (e.g. parentheses).
            name = lib.strings.sanitizeDerivationName "${appid}-${
              lib.replaceStrings [ "/" " " ] [ "_" "_" ] target
            }";
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

  # Icon: an explicit raster source (autocropped/recentred) wins over the exe's PE resources; else extract
  # from the exe when icon.auto; else no raster icon. Same hicolor + splash layout either way.
  iconName = "org.propnix.${appid}";
  iconTree =
    if icon.png != null then
      mkAppIcon {
        src = icon.png;
        inherit iconName;
      }
    else if icon.auto then
      extractPeIcon { inherit payload exe iconName; }
    else
      null;
  splashIcon = if iconTree != null then "${iconTree}/share/propnix/${iconName}.png" else null;

  # Informational: which emulation the scope wired for this host (aarch64 = wine+FEX/ARM64EC, x86_64 =
  # native wine). The launcher does NOT branch on this — its behaviour is arch-identical.
  backend = if stdenv.hostPlatform.isAarch64 then "winefex" else "wine";

  # The unified `env` folds into seal.setEnv — but the launcher OWNS some vars (env.rs skips/recomputes
  # them, or they'd break the sealed profile), so those are an eval-time error, not a silent no-op.
  reservedEnv = [
    "WINEDEBUG"
    "USER"
    "LOGNAME"
    "WINEPREFIX"
    "WINEDLLOVERRIDES"
    "LD_LIBRARY_PATH"
    "LD_PRELOAD"
  ];
  badEnv = lib.intersectLists reservedEnv (lib.attrNames env);

  # The §7 seal: targeted scrub + the structured DLL-override map + the meant vars. The launcher joins
  # dllOverrides into WINEDLLOVERRIDES (merging the DXVK/vkd3d entries) at launch; USER/LOGNAME pin the
  # wine profile to the store lower's user; WINEDEBUG's launch default is -all (PROPNIX_WINEDEBUG wins).
  # The game's unified `env` merges over the base three (reserved names rejected above).
  seal =
    lib.throwIfNot (badEnv == [ ])
      "propnix (${pname}): env may not set launcher-owned var(s) ${toString badEnv} on the wine backend (the launcher computes/owns them)."
      (
        sealing.mkSeal {
          dllOverrides = flat.dllOverrides;
          setEnv = {
            WINEDEBUG = "-all";
            USER = wineUser;
            LOGNAME = wineUser;
          }
          // env;
        }
      );

  # The prefix ROOT (target ""): a MOUNT of the persistent WINE-backend prefix dir. propnix-mount realizes
  # any writable mount that lacks some child mountpoint as `overlay(lower=childSkeleton, upper=source)`,
  # so the writable upper (<state>/wine/prefix) only ever holds user.reg + wine's HKCU writes, never a
  # mountpoint stub. The game-agnostic base user.reg is SEEDED in on first launch, then the three-way
  # merge layers the propnix overrides on top.
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

  # De-store-integration WHITEOUTS: erase each `maskFiles` entry from the game tree (C:\game). One
  # `whiteout` row apiece — sorted AFTER "drive_c/game" so the game bind is laid first and the whiteout
  # overlays the (now-present) parent dir.
  maskMounts = lib.listToAttrs (
    map (rel: lib.nameValuePair "drive_c/game/${rel}" { type = "whiteout"; }) maskFiles
  );

  # The complete WINEPREFIX mount table (view-relative targets): the two read-only hive binds + the game
  # bind + the derived save-bind rows + the defaults & per-game tuning (flat.mounts — which CARRIES the
  # derived de-Galaxy stubs and staged system32 DLLs, and wins over a derived save row at the same target)
  # + the game-dir whiteouts + the root mount. propnix-mount supplies every mount's missing child
  # mountpoints from the table (no build-time skeleton of the table).
  finalMounts = withDefaultSkeletons (
    # Tuning rows REFINE a derived save row at the same target per-field (matching how tuning rows merge
    # among themselves) — a whole-row replace would let a partial `.apply { wine.mounts."<save>".mode = …; }`
    # silently drop the row's `source` (an accidental tmpfs = saves stop persisting).
    regMounts
    // gameMount
    // saveMounts
    // (lib.mapAttrs (t: m: (saveMounts.${t} or { }) // m) flat.mounts)
    // maskMounts
    // rootMount
  );

  configFile = writeText "propnix-${appid}.json" (
    builtins.toJSON {
      schema = 1;
      mode = "prefix"; # the launcher's dispatch tag (ModeProbe; "prefix" = the wine path)
      inherit
        appid
        name
        exe
        backend
        ;
      # Launch cwd relative to C:\game (null → the game dir); toJSON drops a null field.
      workingDir = workingDir;
      exeArgs = exeArgs;
      online = online;
      icon = splashIcon; # largest extracted icon (for the splash), or null
      payload = "${payload}"; # the primary game tree; the launch cwd (store DLLs are stubbed/whited-out via mount rows)
      emulators = {
        wine = "${wine}";
        # No `prefixLower`: the read-only system tree is referenced only by the `mounts` rows above
        # (`${prefixLower}/drive_c/windows`, …), which is all the launcher needs — it warms the ASSEMBLED
        # prefix's PE modules from inside the mount ns, never the store tree. (`deny_unknown_fields`: adding it
        # back here without the matching launcher field is a hard load error.)
        dxvk = "${dxvk}";
        vkd3d = "${vkd3d}";
        # `tar` for the linked propnix_mount to extract overlay `skeleton` tars (sparse + xattr aware).
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
      # PROPNIX_* that breaks a title — e.g. Skyrim lists PROPNIX_FPS/PROPNIX_DPI).
      brokenVariables = flat.brokenVariables;
      # HKCU overrides re-applied every launch (list of { key; name; value; type; }).
      userReg = flat.userReg;
      # HKCU overrides applied ONLY when PROPNIX_FPS > 0 (fixed cap), `$VAR` values resolved at launch.
      fpsUserReg = flat.fpsUserReg;
      # The VRR counterpart: applied ONLY when PROPNIX_FPS == 0 (enable the game's vsync).
      vsyncUserReg = flat.vsyncUserReg;
      # Optional per-game setup script (a store-path executable) the launcher runs before wine — the
      # escape hatch for game-specific prefix setup (e.g. Skyrim's display+quality ini seeding). A
      # non-zero exit aborts the launch.
      setupScript = setupScript;
      # Optional DYNAMIC HKCU overrides: an executable whose JSON stdout is applied this launch
      # (runtime-derived → overrides static userReg). Non-zero/bad-JSON ABORTS.
      userRegScript = flat.userRegScript;
      # gbe_fork present → the launcher seats the stored Steam account's identity (see the param above).
      steamEmu = steamEmu;
      inherit fallbackGl;
      # The complete WINEPREFIX mount table (see finalMounts above). The launcher joins each target to the
      # view root, $VAR-expands the sources, filters/sorts, and lays each with propnix-mount.
      mounts = finalMounts;
      inherit seal;
    }
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
  description = "${name} — propnix wine app (${backend})";
  extraPassthru = {
    inherit
      payload
      payloads
      backend
      dlc
      ;
  };
}

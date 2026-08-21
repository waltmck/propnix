# backends/wine/defaults.nix — the base wine-tuning layer every propnix wine app inherits (PLAN2 §5/§6),
# on BOTH the emulated aarch64 (winefex) and native x86_64 paths. A per-game `wine-tuning.nix` layers on
# top through the module merge (per-game wins; `dllOverrides`/`mounts` merge per-key), so a game spec
# states only what is SPECIFIC to it. Each scalar knob is `{ value; reason; }` so a non-default choice
# justifies itself.
#
# Shape: `{ lib, prefixLower, galaxyStub ? null }: { platform, wine }: { … }`. The OUTER args are the
# store-path derivations its mount table references (the read-only `prefixLower` system tree; the GOG
# Galaxy no-op stub tree) — interpolated into mount rows directly at build time, with no runtime env
# indirection (and no way for a stray env var to redirect a source). The INNER args come from the app
# config: `platform` = the app's emulatedPlatform (platform-dependent defaults, e.g. i386 → wined3d) and
# `wine` = the RESOLVED fixed-point tuning — this layer is a MODULE-SYSTEM config-function, so mount rows
# derived from other knobs (`galaxyStubDlls`, `extraSystem32`) recompute when those knobs are overridden.
# Injected via the scope (backends/wine/default.nix takes `wineDefaults`); override the scope attr to
# re-base all games.
{
  lib,
  prefixLower,
  # Graceful no-op GOG Galaxy SDK stub tree (a store path). Present on the winefex (aarch64) path; null on
  # x86_64 (native wine), where the de-Galaxy mount rows are omitted.
  galaxyStub ? null,
}:
{ platform, wine }:
let
  config = wine; # the resolved fixed-point tuning (derived rows below read the FINAL knob values)
  # ── Derived mount rows (module-system): computed from other tuning knobs against the FINAL config, so an
  # `.apply` that changes `galaxyStubDlls`/`extraSystem32` re-derives these rows. ──────────────────

  # De-Galaxy stubs. Some GOG titles bundle the GOG Galaxy SDK (Galaxy64.dll / Galaxy.dll) and the older
  # POPS online client (pops_api.dll) and STATICALLY import them from the exe's own directory, where the
  # SDK spins up a network/RPC layer at startup. A packaged game must run FULLY OFFLINE with no cloud
  # dependencies, so that gets neutralized. Because they're static imports in the app dir, wine's loader
  # resolves them there FIRST — a system32/WINEDLLOVERRIDES stub can't shadow them — so bind a graceful
  # no-op stub over each (at its path
  # under drive_c/game). `config.galaxyStubDlls` (payload-relative paths the game declares) → one `mount` row
  # apiece with the store-path stub as source. aarch64 only (galaxyStub != null); on x86_64 the game runs
  # under native wine and these are omitted.
  galaxyMounts =
    if galaxyStub == null then
      { }
    else
      lib.listToAttrs (
        map (
          rel:
          lib.nameValuePair "drive_c/game/${rel}" {
            type = "mount";
            source = "${galaxyStub}/${baseNameOf rel}";
            mode = "ro";
          }
        ) config.galaxyStubDlls
      );

  # Native runtime DLLs staged over the builtins in system32: one read-only bind row apiece, bound over an
  # EXISTING system32 file (the wine builtin), so no mountpoint is created in the read-only windows bind. From
  # `config.extraSystem32` (`{ "<name>.dll" = <store path to the DLL FILE>; }`). See the `extraSystem32` knob.
  extraSystem32Mounts = lib.mapAttrs' (
    name: src:
    lib.nameValuePair "drive_c/windows/system32/${name}" {
      type = "mount";
      source = "${src}";
      mode = "ro";
    }
  ) config.extraSystem32;

  # The static base mount table (independent of other knobs). The derived rows above merge on top.
  staticMounts = {
    ".update-timestamp" = {
      source = "${prefixLower}/.update-timestamp";
      mode = "ro";
    };
    "drive_c/windows" = {
      source = "${prefixLower}/drive_c/windows";
      mode = "ro";
    };
    # C:\Windows\Temp — writable but throwaway: an ephemeral (tmpfs-upper) overlay. `skeleton = null` opts out
    # of the default CoW-from-store skeleton — Temp only gets NEW files (straight to the tmpfs upper), nothing
    # in the lower is ever copied up, so a plain overlay suffices.
    "drive_c/windows/temp" = {
      type = "overlay";
      lower = "${prefixLower}/drive_c/windows/temp";
      skeleton = null;
    };
    "drive_c/Program Files" = {
      source = "${prefixLower}/drive_c/Program Files";
      mode = "ro";
    };
    "drive_c/Program Files (x86)" = {
      source = "${prefixLower}/drive_c/Program Files (x86)";
      mode = "ro";
    };
    # DOS drive mapping (c: → ../drive_c, z: → /): wine's own relative symlinks, bound read-only from the store.
    "dosdevices" = {
      source = "${prefixLower}/dosdevices";
      mode = "ro";
    };
    # The writable profile (users\ + ProgramData\): PERSISTENT CoW overlays over the store skeleton. Reads
    # fall through to the store inode (shared page cache); writes persist to $PROPNIX_STATE with NO seed.
    "drive_c/users" = {
      type = "overlay";
      lower = "${prefixLower}/drive_c/users";
      upper = "$PROPNIX_STATE/wine/users";
      createIfNotExist = true;
    };
    "drive_c/ProgramData" = {
      type = "overlay";
      lower = "${prefixLower}/drive_c/ProgramData";
      upper = "$PROPNIX_STATE/wine/programdata";
      createIfNotExist = true;
    };
  };
in
{
  # D3D→GPU backend. PLATFORM-DERIVED: an i386 (32-bit) title cannot use DXVK on the aarch64 path — the
  # native DXVK is ARM64EC-only, unloadable by a 32-bit process — so i386 defaults to wine's builtin
  # wined3d (→ host GL); the same on native x86_64 today for x-arch consistency (the i386 games shipped
  # with wined3d unconditionally). x86_64 titles default to DXVK. A game overrides per-title as ever.
  d3d =
    if platform == "i386-windows" then
      {
        value = "wined3d";
        reason = "i386 title: DXVK is ARM64EC-only and unusable by a 32-bit process (platform default); D3D goes through wine's builtin wined3d → host GL.";
      }
    else
      {
        value = "dxvk";
        reason = "native ARM64EC DXVK → Vulkan measures 60 fps; wine's builtin wined3d-Vulkan present-stalls to ~12 (architectural, RESEARCH §22). Per-title override to \"wined3d\" if a title misbehaves.";
      };

  # wine display driver.
  graphics = {
    value = "wayland";
    reason = "winewayland: native fractional scaling, single native window, no Xwayland. Per-title override to \"x11\" for titles needing a correct hardware cursor or that misrender on wayland (RESEARCH §12).";
  };

  # WINEDLLOVERRIDES as a STRUCTURED DLL→load-order map (mergeable/overridable per-DLL, unlike a string;
  # the launcher composes the final `dll=order;…` string and merges the DXVK/vkd3d entries into it).
  # Load order: "n" = native, "b" = builtin, "" = disabled (n,b combinations also allowed, e.g. "n,b").
  # These three are universal wine hygiene, not per-game:
  dllOverrides = {
    mscoree = {
      value = "b";
      reason = "builtin: suppress the wine-mono install prompt without breaking .NET.";
    };
    mshtml = {
      value = "";
      reason = "disabled: drop the wine-gecko install prompt.";
    };
    "winemenubuilder.exe" = {
      value = "";
      reason = "disabled: stop wine writing its own .desktop/icon files for the app — propnix ships the launcher's.";
    };
  };

  # HKCU (user.reg) registry overrides, RE-APPLIED on every launch so they always win and update without a
  # prefix reset. The base user.reg is wine's game-agnostic vanilla hive (seeded once into the root mount);
  # these overrides are layered on at RUNTIME by the launcher's three-way merge (graphics.rs), never baked.
  # Structured like dllOverrides but two levels: "<key relative to HKCU>"."<value name>" =
  # { value; reason; type ? "REG_SZ"; }; merged per-value, so a game can add/override entries in tuning.nix.
  #
  # (NB: `HKCU\Software\Wine\X11 Driver\Decorated=N` does NOT give borderless on winewayland — the Win32
  # caption is drawn by win32u nc_paint/handle_nc_calc_size straight from WS_CAPTION with no decorated_mode
  # gate; `decorated_mode` only affects the X11/SSD visible rect. True borderless on winewayland would need a
  # wine NC patch — deferred. An earlier COLOR_WINDOW=black attempt to kill the ~0.5 s white flash was also
  # irrelevant: a window with no background brush — HK, `bg=(nil)` in the wine +class trace — is never erased;
  # that flash is the D3D swapchain's first frame, not the window background.)
  #
  # The display driver and screen DPI are declared HERE as ordinary userReg entries (no hardcoded HKCU writes
  # in the launcher). Their values are `$VAR`s the launcher resolves at runtime: `graphics.rs` exports the
  # RESOLVED `settings.graphics` → `PROPNIX_WINE_GRAPHICS` (= the env override → the per-game `graphics` knob,
  # already merged — so Skyrim's `graphics="x11"` propagates) and `settings.dpi` → `PROPNIX_DPI` only when set.
  # An unset `$PROPNIX_DPI` drops LogPixels → the three-way merge PRUNES a stale one (the DPI self-heal).
  userReg = {
    "Software\\Wine\\Drivers"."Graphics" = {
      value = "$PROPNIX_WINE_GRAPHICS";
      reason = "wine display driver; launcher exports the resolved value (per-game `graphics` + PROPNIX_WINE_GRAPHICS override). Applied via the three-way merge, not baked.";
    };
    "Control Panel\\Desktop"."LogPixels" = {
      value = "$PROPNIX_DPI";
      type = "REG_DWORD";
      reason = "screen DPI (96=100%); present only when PROPNIX_DPI is in play — unset drops it and the merge prunes a stale LogPixels (black-screened Skyrim otherwise).";
    };
  };

  # HKCU overrides applied ONLY when PROPNIX_FPS > 0 (a FIXED cap — not VRR / unset). Same structure as
  # `userReg` ("<key relative to HKCU>"."<value name>" = { value; reason; type ? "REG_SZ"; }; a numeric cap
  # key wants `type = "REG_DWORD";`), merged
  # per-value, EXCEPT the `value` may embed `$VAR`/`${VAR}` resolved at LAUNCH — so a game writes its own
  # in-engine frame cap / vsync key as a function of `$PROPNIX_FPS` (e.g. a `MaxFPS = "$PROPNIX_FPS"` DWORD).
  # These are NOT baked into the base user.reg (the value is runtime-only); the launcher folds them into the
  # three-way-merge desired set only in the Fixed FPS mode, so switching to VRR/unset PRUNES them (self-heal).
  # Runtime-dependent, so they OVERRIDE any static `userReg` value for the same key. Empty default.
  fpsUserReg = { };

  # The VRR counterpart to `fpsUserReg`: HKCU overrides applied ONLY when PROPNIX_FPS == 0 (VRR). Same
  # structure/semantics as `fpsUserReg` (merged per-value, `$VAR`-expanded at launch, runtime-precedence over
  # static `userReg`, pruned on the transition out of VRR). Use it to ENABLE the game's own vsync so it
  # presents FIFO and the display's variable refresh follows it (the inverse of the fpsUserReg case, where the
  # game's vsync is disabled so DXVK's timer-paced cap governs). Empty default.
  vsyncUserReg = { };

  # Env vars the launcher UNSETS before doing anything (fact population, Settings, the seal). A per-game
  # escape hatch from a user's GLOBAL PROPNIX_* that a specific title can't tolerate — the §5 promise is that
  # one exported PROPNIX_* steers every game, but a game that misrenders under one can opt out here. E.g.
  # Skyrim SE lists PROPNIX_FPS (forced vsync-off) and PROPNIX_DPI (persistent LogPixels stamp), both of which
  # break its renderer. A plain list of env-var names; merged (union) with any per-game list. Empty default.
  brokenVariables = [ ];

  # ── The rest of a game's declarative CONFIG (the builder's arg set stays identity/content/packaging so `tuning` is the single,
  # uniformly-layered home for everything about HOW an app runs; the wine builder's own args are just identity
  # (pname/appid/name), content (payload), entry point (exe), and build-time packaging (icon, brokenSystems)).
  # Each has an inert default so a game states only what it needs, and each is reachable by `.apply`.

  # Payload-relative paths of bundled GOG Galaxy SDK DLLs (Galaxy64/Galaxy/pops_api) the title statically
  # imports. A LIST, unioned across layers. Each becomes a de-Galaxy `mount` row (see `galaxyMounts` above —
  # DERIVED into the mount table here, so an `.apply` on this list re-derives the rows) binding the
  # no-op stub over it on aarch64 (omitted on x86_64, where there's no stub).
  galaxyStubDlls = [ ];

  # Native runtime DLLs to stage into system32 as `{ "<name>.dll" = <store path to the DLL FILE>; }` — one
  # read-only bind row apiece over an EXISTING system32 builtin. For an x86_64 title needing a GENUINE MS
  # runtime DLL the ARM64EC builtin can't stand in for under FEX (e.g. Outlast's VC++ 2010 `msvcp100.dll`).
  # Merged per-DLL (like dllOverrides). The target must already exist in the store system32 (shadows, not adds).
  # DERIVED into the mount table here (see `extraSystem32Mounts` above), so overriding it re-derives the rows.
  extraSystem32 = { };

  # Declarative HKLM (systemReg) / HKU\.Default (userdefReg) registry overrides, baked over the wine-generated
  # base (mkWineReg) and bound READ-ONLY (never CoW). Nested `"<key relative to the hive>"."<value name>" =
  # { value; reason; type ? "REG_SZ"; }`, merged per-value — same `{ value; reason; type? }` shape as userReg
  # (HKCU, which is runtime-applied instead), so a non-default HKLM/.Default value justifies itself too.
  systemReg = { };
  userdefReg = { };

  # Optional per-game SETUP SCRIPT: a path to an EXECUTABLE the launcher runs (OUTER, before wine) for
  # game-specific prefix setup that doesn't belong in the launcher (e.g. Skyrim seeding SkyrimPrefs.ini). Gets
  # the runtime env + PROPNIX_PAYLOAD; a NON-ZERO exit ABORTS the launch. The game builds it (writeShellScript).
  setupScript = null;

  # Optional escape hatch for DYNAMIC HKCU overrides: a store-path executable whose JSON stdout is a set of
  # HKCU overrides applied this launch (runtime-derived → overrides static userReg). Non-zero/bad-JSON ABORTS.
  # Prefer `fpsUserReg` for the common "cap = $PROPNIX_FPS" case; this hatch is for logic a $VAR can't capture.
  userRegScript = null;

  # The WINEPREFIX mount table — the FULL declarative description of how the prefix the game sees is
  # assembled. An attrset keyed by TARGET, each entry one of two types (the launcher passes only literal paths
  # to propnix-mount, which lays them with kernel binds/overlays in a private user+mount namespace; parent-
  # first, most-specific target wins). Keyed so a per-game `tuning.nix` can add entries, override one field
  # (`mounts."drive_c/windows/temp".lower = …`), or disable one (`mounts.<t>.enabled = false;`).
  #
  #   { type = "mount";   source ? null; mode ? "rw"; seed ? null; } # a bind of `source` at the target, OR —
  #                                                                  #   when source = null — a fresh private
  #                                                                  #   tmpfs; `seed` pre-populates it/the bind
  #   { type = "overlay"; lower; upper ? null; skeleton ? …; }       # a COW overlay; upper = null → EPHEMERAL
  # plus common `enabled ? true` and `createIfNotExist ? false` (create the writable `source`/`upper` if
  # missing, else FAIL the launch; store sources leave it false). `type` defaults to "mount" (sealing.nix),
  # so bind rows omit it. `seed` (env-expandable path): on every launch, every file the target LACKS is copied
  # from `seed` (existing files untouched) — used with a null `source` for a per-launch tmpfs pre-filled from a
  # store tree (e.g. a Mono runtime's assemblies), and by the root mount to seed the base user.reg.
  #
  # NOTE ON OVERLAYS: a store-backed overlay works unprivileged via the DATA-ONLY `skeleton` (the wine builder
  # defaults it from the `lower`): reads fall through to the store inode (shared page cache), writes copy-up
  # to `upper` with the store data preserved. `skeleton = null` opts out to a plain overlay (an empty/ephemeral
  # lower like Temp, where nothing is copied up). CRITICAL: never use the same dir as `upper` in two overlays
  # (kernel UB) — every overlay here has a distinct upper.
  #
  # STORE-PATH fields are interpolated here at build time (`${prefixLower}/…`; a game's tuning does the same
  # with its `payload`). The remaining `$VAR` placeholders are RUNTIME values the launcher expands:
  #   $PROPNIX_STATE = the app state dir ($XDG_STATE_HOME/propnix/<appid>)
  #   $PROPNIX_SAVE_DIR = the host save root ($XDG_DATA_HOME/propnix-saves by default; explicit-but-missing
  #                       fails the launch)      $PROPNIX_APPID = the app id
  # plus $HOME/$XDG_* — a game can bind e.g. $XDG_DOCUMENTS_DIR natively. A TARGET key that expands to an
  # ABSOLUTE path is a literal (a payload/store redirect, e.g. KSP's in-game-dir writes); RELATIVE is inside
  # the prefix.
  #
  # The prefix ROOT (target "") and the two declarative HKLM/.Default hive binds (system.reg, userdef.reg) are
  # injected by the wine builder, not declared here: the root is a persistent MOUNT of `$PROPNIX_STATE/wine/prefix`
  # (seeded once with the game-agnostic base user.reg; propnix-mount realizes it as an overlay so its child
  # skeleton exposes every sub-mount's mountpoint and its upper persists HKCU writes), and the hive binds are
  # per-game (mkWineReg = wine-generated base + this game's systemReg/userdefReg overrides). What IS here: the
  # read-only system trees (C:\Windows + Program Files + dosdevices, ro binds); C:\Windows\Temp (ephemeral
  # overlay); the writable profile (users\ + ProgramData\) as PERSISTENT CoW overlays over the store — the
  # default skeleton (the wine builder) makes those root-owned lowers copy-up-able unprivileged, so writes persist
  # to $PROPNIX_STATE with NO seeding and reads share the store inode; PLUS the DERIVED de-Galaxy stubs
  # (galaxyStubDlls) and staged system32 runtime DLLs (extraSystem32). DISTINCT uppers everywhere (UB: never
  # share an upper between two overlays — root=$STATE/wine/prefix, users=$STATE/wine/users,
  # programdata=$STATE/wine/programdata, game=$STATE/gamedir, saves=$SAVE_DIR). The game + saves are per-game
  # rows; the DXVK/vkd3d system32 binds are added by the launcher when d3d = dxvk.
  mounts = staticMounts // galaxyMounts // extraSystem32Mounts;
}

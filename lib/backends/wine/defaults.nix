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
  # Graceful no-op GOG Galaxy SDK stub tree (a store path). Wired on BOTH hosts (its DLLs are x86_64/i386
  # PEs matching the GAME, never the host); null only if a scope declines to provide it, in which case the
  # de-Galaxy mount rows are omitted.
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
  # apiece with the store-path stub as source.
  #
  # 64-BIT CALLERS ONLY, and that is an ABI FACT rather than a policy. The stub hands the game ONE uniform
  # vtable whose every slot is a zero-argument C function (emulators/galaxy-stub/src/galaxy_stub.c). Under
  # Microsoft x64 that is safe for a slot of ANY arity: arguments arrive in registers and the CALLER cleans
  # the stack, so a callee that ignores them leaves nothing behind. On i386 the SDK's interfaces are
  # __thiscall — the CALLEE pops the arguments — so a zero-argument slot standing in for an N-argument
  # method leaves N bytes of arguments on the caller's stack, and the caller's own `ret` then pops an
  # ARGUMENT as its return address.
  #
  # MEASURED 2026-09-03, homeworld-rm on native x86_64 WoW64 — the first i386 title ever to actually load
  # this stub (before the x86_64 wiring it was a silent no-op, see TOOLCHAIN in emulators/galaxy-stub).
  # HomeworldRM.exe's Galaxy init wrapper is:
  #     004bd9e5  ff 15 2c 80 87 00   call [GalaxyFactory::CreateInstance]  ; a Galaxy.dll import
  #     004bd9eb  8b 10               mov  edx,[eax]                       ; IGalaxy vtable
  #     004bd9ed  6a 00               push 0
  #     004bd9ef  68 c8 60 8e 00      push 0x8e60c8                        ; clientSecret
  #     004bd9f4  68 60 60 8e 00      push 0x8e6060                        ; clientID "48201844549712537"
  #     004bd9f9  8b c8               mov  ecx,eax                         ; this
  #     004bd9fb  ff 52 04            call [edx+4]                         ; IGalaxy::Init — __thiscall, `ret 12`
  #     004bd9fe  c3                  ret                                  ; pops 0x8e6060 when nobody popped
  # and the game's own crash log reads "HomeworldRM.exe caused an Access Violation in module
  # HomeworldRM.exe at 0023:008e6060 … Bytes at CS:EIP: 34 38 32 30 31 38 34 34 …" — it is EXECUTING the
  # client-ID STRING LITERAL (0x8e6060 is that string in .rdata; it matches goggame-2114871440.info's
  # `clientId` exactly), with the module list confirming the 29075-byte stub as the loaded Galaxy.dll.
  # Dropping the row makes the fault go away and the game maps its window; nothing else does. A generic
  # 32-bit no-op stub cannot be written: it would need the true arity of every slot of every interface.
  #
  # So i386 titles get NO rows, and declaring the knob there is a legible ERROR rather than a silent no-op
  # (a silent no-op is precisely what kept this defect hidden). The offline guarantee for a 32-bit GOG
  # title is `online = false` instead — a kernel network-namespace unshare, strictly stronger than trusting
  # a stub to be a no-op.
  galaxyMounts =
    if galaxyStub == null || config.galaxyStubDlls == [ ] then
      { }
    else
      lib.throwIf (platform == "i386-windows")
        "propnix wine tuning: `wine.galaxyStubDlls` cannot be used by an i386 title — the stub's uniform zero-argument vtable breaks __thiscall's callee-pops rule and the game ends up executing its own arguments (measured on homeworld-rm; see the comment above this throw in lib/backends/wine/defaults.nix). Drop the knob and set `online = false`, which enforces the same offline guarantee in the kernel."
        (
          lib.listToAttrs (
            map (
              rel:
              lib.nameValuePair "drive_c/game/${rel}" {
                type = "mount";
                source = "${galaxyStub}/${baseNameOf rel}";
                mode = "ro";
              }
            ) config.galaxyStubDlls
          )
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
    # DOS drive mapping: wine's own relative symlinks (c: → ../drive_c, z: → /) from the store, under an
    # EPHEMERAL (tmpfs-upper) overlay. `skeleton = null` — the two lower entries are never modified, only
    # NEW letters are added, and those go straight to the tmpfs upper and are discarded at exit.
    #
    # WHY NOT A READ-ONLY BIND (which is what this was): mountmgr WRITES here, and one of those writes is a
    # retry loop that never terminates if the write cannot succeed. `dlls/mountmgr.sys/device.c`'s
    # `add_dos_device()` takes `device_section` and, for an auto-assigned letter, calls
    # `unixlib.c: add_drive()`, whose tail is
    #     while (avail != -1) { …scan a..z for a free letter…
    #                           if (avail != -1) { … if (symlink( device, path ) != -1) goto done;
    #                                              /* failed, retry the search */ } }
    # The retry exists for a RACE (another process claimed the letter between the scan and the symlink), and
    # it is correct for that: the next scan sees the letter taken and moves on. On a read-only dosdevices the
    # symlink fails PERMANENTLY, the scan is unchanged, and the same letter is picked forever — `in_use[]` is
    # only set by a scan that FINDS something, never by a failed create.
    # MEASURED on this tree before the change (x86_64-linux, space-engineers): a winedevice.exe thread pinned
    # at 99.4% CPU for 2m15s in `add_drive`, strace showing
    #     symlink("/dev/sdd", "…/dosdevices/d::") = -1 EROFS (Read-only file system)
    # on repeat, and — because `device_section` is held across that call — every OTHER process in the prefix
    # blocking forever in any mountmgr IOCTL. Space Engineers' main thread hung in
    # `NtQueryVolumeInformationFile → get_mountmgr_fs_info → server_wait_for_object` and never reached its
    # renderer; wine's own `err:sync:RtlpWaitForCriticalSection … "dlls/mountmgr.sys/device.c: device_section"
    # wait timed out` names the section. This is host-dependent, not game-dependent: it fires on any machine
    # with a block device UDisks2 reports that has no letter yet, and it hangs any title that asks for volume
    # information (a .NET `DriveInfo`/`GetVolumeInformation` is enough).
    #
    # EPHEMERAL, not persistent: the letters are a snapshot of the HOST's block devices at launch, so caching
    # them across launches would only leave stale links to devices that are gone. Nothing hermetic is lost —
    # the new entries point at /dev nodes and unix mount points that the launch's private mount namespace
    # does not carry, so they dangle; what matters is that the symlink SUCCEEDS and add_drive returns.
    "dosdevices" = {
      type = "overlay";
      lower = "${prefixLower}/dosdevices";
      skeleton = null;
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
    # mscoree is the CLR HOST, and since emulators/wine-prefix-lower.nix started shipping Wine Mono at
    # C:\windows\mono\mono-2.0 this entry is load-bearing rather than cosmetic. Two corrections to the
    # reason it used to carry:
    #   * "b" is not a choice between implementations — the BUILTIN is the only mscoree that exists (wine
    #     builds it into lib/wine/*/mscoree.dll; Wine Mono installs no native mscoree anywhere, its payload
    #     is bin/libmono-2.0-x86{,_64}.dll plus managed assemblies). "n" would find nothing to load and ""
    #     would disable .NET outright, so every managed title depends on this staying "b".
    #   * it never suppressed the wine-mono install prompt. That prompt is mscoree's DllRegisterServer ->
    #     install_wine_mono() -> invoke_appwiz(), reached only when wine.inf's RegisterDlls step registers
    #     mscoree during `wineboot -u` — which propnix runs ONCE, at prefix-lower build time, and never at
    #     runtime (.update-timestamp=disable). With a CLR now present, get_mono_path() succeeds anyway.
    mscoree = {
      value = "b";
      reason = "builtin: mscoree IS the CLR host and the builtin is its only implementation — \"n\" finds nothing to load, \"\" disables .NET outright. See the comment above for what this does NOT do.";
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
  # the runtime env + PROPNIX_PAYLOAD (the primary tree) + PROPNIX_PAYLOADS (all of them, ':'-joined in mount
  # priority order); a NON-ZERO exit ABORTS the launch. The game builds it (mkSetupScript).

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

# backends/mk-thin-build.nix — the shared THIN dispatch-arm assembler: turns (resolved app config +
# a backend's LAUNCH BLOCK) into the mkThinApp call. Every thin backend entry (box64/native/fex) builds
# through this, so the config→builder plumbing exists once and the launch-block CONTRACT is enforced here:
# a block that misspells a field or grows an undeclared one is a named eval error, not a silently-dropped
# attr or an opaque unexpected-argument failure inside mkThinApp.
{
  lib,
  stdenv,
  strategy,
  mkThinApp,
  mkFallbackGl, # builders/gl-fallback.nix: the baked GL/Vulkan stack of last resort (its header has the why)
}:
let
  # The launch-block contract (see builders/thin.nix, which consumes the launch fields verbatim).
  requiredFields = [
    "backend" # informational: "box64" | "fex" | "native"
    "emulator" # program that runs the ELF, or null → exec natively
    "env" # backend env defaults (the game's unified `env` is merged over them by the backend)
    "ldLibraryPath" # library union ("" for FEX)
    "mangohud" # MangoHud root (PROPNIX_BENCH)
  ];
  optionalFields = [
    "extraLowers" # trees unioned ABOVE the game (FEX's patched-exe overlay)
    "executables" # exec-bit-fix override ([] = the block handled +x itself)
    "brokenSystems" # backend-level meta.broken contribution
    "brokenReason"
  ];
  checkLaunchBlock =
    block:
    let
      keys = lib.attrNames block;
      missing = lib.subtractLists keys requiredFields;
      unknown = lib.subtractLists (requiredFields ++ optionalFields) keys;
    in
    lib.throwIfNot (missing == [ ] && unknown == [ ])
      "propnix: malformed thin launch block — missing ${toString missing}; unknown ${toString unknown} (contract: required ${toString requiredFields}, optional ${toString optionalFields})"
      block;
in
{
  cfg, # the resolved mkApp config
  enabledDlc, # DLC derivations selected by name (highest-priority extra lowers)
  executables, # the app-level exec-bit-fix list (cfg.executables ? [ cfg.exe ]); a block may override
  block, # the backend's launch block (checked against the contract above)
}:
let
  b = checkLaunchBlock block;
  host = stdenv.hostPlatform.system;

  # ── the (backend face × payload arch × host arch) guard ──────────────────────────────────────────────
  # `backend` is an ordinary option, so `.apply { backend = …; }` can name a face that cannot run this
  # payload — and nothing else catches it: `runnable` compares platform against HOST, the suffix check
  # above only asserts "-linux", and each entry trusts `cfg.backend` to describe its own face.
  # `.apply { emulatedPlatform = "x86_64-linux"; backend = "native"; }` on aarch64 therefore stamps the
  # HOST loader into an x86_64 ELF and builds clean, dying at execve with ENOEXEC.
  #
  # Here rather than in an entry because it is one rule for every thin backend, and a BUILD refusal
  # rather than a throw for the same reason as `runnable`'s: the CI matrix forces combinations on hosts
  # that cannot run them, and evaluation must survive that.
  payloadArch = (strategy.platformToNeed cfg.emulatedPlatform).arch;
  hostArch = if stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
  # What each face can actually execute:
  #   native — the host's own arch, PLUS i386 on an x86_64 host: an x86_64 kernel executes a 32-bit
  #            x86 ELF directly (given the 32-bit loader and libraries, which the box64 entry's
  #            native face resolves from the payload's own package set), which is exactly why
  #            resolveStrategy sends i386-linux to `native` there.
  #   box64  — x86_64 ONLY. It is an x86_64→ARM64 emulator with no 32-bit guest support; box86 would
  #            be that answer and is dead on 16 KiB pages (see lib/strategy.nix).
  #   fex    — either x86 width. Its own entry carries the "no x86_64-host FEX" refusal.
  faceRuns =
    {
      native = payloadArch == hostArch || (hostArch == "x86_64" && payloadArch == "i386");
      box64 = payloadArch == "x86_64";
      fex = payloadArch == "x86_64" || payloadArch == "i386";
    }
    .${b.backend} or true;

  # ── meta.broken: THREE independent claims, ONE reason ────────────────────────────────────────────────
  # A refusal can come from the game (this engine is broken under this backend), from the backend's own
  # launch block (this backend has no emulator on this host), or from the face guard above — and more
  # than one can hold at once. The systems are simply unioned, but `meta.brokenReason` is a single
  # string, so it has to be CHOSEN, and the choice is what the user reads.
  #
  # Choose a claim that names the HOST BEING EVALUATED, or the message describes the wrong machine:
  # taking the game's reason unconditionally (as this once did) told an x86_64 user that Hollow Knight
  # "crashes at guest Mono init … on a 16K-page host" and to "drop `backend = fex`, box64 is this
  # platform's default here" — three claims that are all false there, where the real refusal is the fex
  # backend having no x86_64-host interpreter and the default being `native`.
  #
  # Among the claims that DO name this host, the game outranks the guards: its verdict survives any
  # change of backend, so pointing at the backend first would offer a remedy that cannot work. The
  # fallback (no claim names this host) keeps whatever reason exists, for the `allowBroken` and
  # cross-host-inspection paths where the string is informational rather than a refusal.
  claims = [
    { inherit (cfg.broken) systems reason; }
    {
      systems = lib.optionals (!faceRuns) [ host ];
      # NULL when the face runs, not merely an empty `systems`. A claim carries its reason into the
      # fallback below, so a reason left populated on a working combination is not inert: it becomes the
      # `meta.brokenReason` of a perfectly healthy package, which then advertises a wall it does not
      # have ("backend 'box64' cannot execute x86_64 content on aarch64-linux" on a default, working
      # Hollow Knight).
      reason =
        if faceRuns then
          null
        else
          "backend '${b.backend}' cannot execute ${payloadArch} content on ${host}: the 'native' face runs the host's own arch (plus i386 on an x86_64 host), box64 emulates x86_64 only, and fex emulates x86 of either width. This combination is reachable solely through an explicit `.apply { backend = …; }` — drop it and let resolveStrategy pick.";
    }
    {
      systems = b.brokenSystems or [ ];
      reason = b.brokenReason or null;
    }
  ];
  stated = lib.filter (c: c.reason != null) claims;
  aboutThisHost = lib.filter (c: lib.elem host c.systems) stated;
  broken = {
    systems = lib.unique (lib.concatMap (c: c.systems) claims);
    reason =
      if aboutThisHost != [ ] then
        (lib.head aboutThisHost).reason
      else
        (lib.head (stated ++ [ { reason = null; } ])).reason;
    # The caller's escape hatch (app-options `allowBroken`): suppresses the refusal these systems
    # earn, whether the claim came from the game, from the backend's launch block, or from the guard.
    allow = cfg.allowBroken;
  };
in
# A thin backend runs Linux ELFs; forcing one onto a Windows build would fail obscurely downstream
# (patchelf on a PE, box64 handed a .exe) — refuse legibly at eval instead.
lib.throwIfNot (lib.hasSuffix "-linux" cfg.emulatedPlatform)
  "propnix (${cfg.pname}): the '${b.backend}' backend runs Linux ELFs, but emulatedPlatform is '${cfg.emulatedPlatform}' — select a *-linux platform (`.apply { emulatedPlatform = …; }`) or a windows-capable backend."
  (mkThinApp {
    inherit (cfg)
      pname
      appid
      name
      exe
      wmClass
      exeArgs
      online
      workingDir
      maskFiles
      icon
      setupScript
      maintainers
      ;
    # The last-wins save/state rows plus the composable framework/game rows (steam-emu's shim placements).
    saveBinds = cfg.saveBinds ++ cfg.extraBinds;
    # The GAME TREES, highest priority first: enabled DLC, then the payloads. DLC belongs in this list
    # rather than in `extraLowers` because it IS game content and mkThinApp gives each game tree its own
    # exec-bit fix layer in its own position — a DLC that ships a complete build of the game needs its
    # executable made +x just as the base payload's does.
    payloads = (map (d: "${d}") enabledDlc) ++ cfg.payloads;
    executables = b.executables or executables;
    inherit broken; # the unioned systems + host-appropriate reason computed above
    # Non-game layers that rank ABOVE every game tree: the backend's own overlay (FEX's patched exe, the
    # native face's interpreter-patched exe) and the app's extra trees (the offline Steam-entitlement
    # settings). Enabled DLC is NOT here — it goes into `payloads` above, where it gets its own exec-bit
    # fix layer and keeps its place in the union.
    extraLowers = (b.extraLowers or [ ]) ++ (map (d: "${d}") cfg.extraLowers);
    # gbe_fork wired in (modules/steam-emu.nix); informational for the launcher.
    steamEmu = cfg.steam.emu.enable;
    # The GL/Vulkan userspace of last resort (host-native arch; the guest reaches GL through the
    # emulator's native bridge). See builders/gl-fallback.nix for the rationale and field contract.
    fallbackGl = mkFallbackGl cfg.mesa;
    inherit (b)
      backend
      emulator
      env
      ldLibraryPath
      mangohud
      ;
  })

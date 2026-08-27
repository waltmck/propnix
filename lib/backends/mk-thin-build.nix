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
in
# A thin backend runs Linux ELFs; forcing one onto a Windows build would fail obscurely downstream
# (patchelf on a PE, box64 handed a .exe) — refuse legibly at eval instead.
lib.throwIfNot (lib.hasSuffix "-linux" cfg.emulatedPlatform)
  "propnix (${cfg.pname}): the '${b.backend}' backend runs Linux ELFs, but emulatedPlatform is '${cfg.emulatedPlatform}' — select a *-linux platform (`.apply { emulatedPlatform = …; }`) or a windows-capable backend."
  (mkThinApp ({
    inherit (cfg)
      pname
      appid
      name
      exe
      exeArgs
      online
      workingDir
      maskFiles
      icon
      setupScript
      ;
    # The last-wins save/state rows plus the composable framework/game rows (steam-emu's shim placements).
    saveBinds = cfg.saveBinds ++ cfg.extraBinds;
    # The GAME TREES, highest priority first: enabled DLC, then the payloads. DLC belongs in this list
    # rather than in `extraLowers` because it IS game content and mkThinApp gives each game tree its own
    # exec-bit fix layer in its own position — a DLC that ships a complete build of the game needs its
    # executable made +x just as the base payload's does.
    payloads = (map (d: "${d}") enabledDlc) ++ cfg.payloads;
    executables = b.executables or executables;
    broken = {
      systems = cfg.broken.systems ++ (b.brokenSystems or [ ]);
      reason = if cfg.broken.reason != null then cfg.broken.reason else (b.brokenReason or null);
    };
    # Non-game layers that rank ABOVE every game tree: the backend's own overlay (FEX's patched exe, the
    # native face's interpreter-patched exe) and the app's extra trees (the offline Steam-entitlement
    # settings). Enabled DLC is NOT here — it goes into `payloads` above, where it gets its own exec-bit
    # fix layer and keeps its place in the union.
    extraLowers = (b.extraLowers or [ ]) ++ (map (d: "${d}") cfg.extraLowers);
    inherit (b)
      backend
      emulator
      env
      ldLibraryPath
      mangohud
      ;
  }
  # ── the (backend face × payload arch × host arch) guard ──────────────────────────────────────────
  # `backend` is an ordinary option, so `.apply { backend = …; }` can name a face that cannot run this
  # payload — and nothing else catches it: `runnable` compares platform against HOST, mk-thin-build's
  # suffix check only asserts "-linux", and each entry trusts `cfg.backend` to describe its own face.
  # `.apply { emulatedPlatform = "x86_64-linux"; backend = "native"; }` on aarch64 therefore stamps the
  # HOST loader into an x86_64 ELF and builds clean, dying at execve with ENOEXEC.
  #
  # Here rather than in an entry because it is one rule for every thin backend, and a BUILD refusal
  # rather than a throw for the same reason as `runnable`'s: the CI matrix forces combinations on hosts
  # that cannot run them, and evaluation must survive that.
  // (
    let
      payloadArch = (strategy.platformToNeed cfg.emulatedPlatform).arch;
      hostArch = if stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
      # What each face can actually execute: `native` only the host's own arch, the emulators only x86.
      faceRuns =
        {
          native = payloadArch == hostArch;
          box64 = payloadArch == "x86_64" || payloadArch == "i386";
          fex = payloadArch == "x86_64" || payloadArch == "i386";
        }
        .${b.backend} or true;
    in
    lib.optionalAttrs (!faceRuns) {
      broken = {
        systems = cfg.broken.systems ++ [ stdenv.hostPlatform.system ];
        reason = "backend '${b.backend}' cannot execute ${payloadArch} content on ${stdenv.hostPlatform.system}: the 'native' face runs only the host's own arch, and box64/fex emulate x86 only. This combination is reachable solely through an explicit `.apply { backend = …; }` — drop it and let resolveStrategy pick.";
      };
    }
  )))

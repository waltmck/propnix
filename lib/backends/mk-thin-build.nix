# backends/mk-thin-build.nix — the shared THIN dispatch-arm assembler: turns (resolved app config +
# a backend's LAUNCH BLOCK) into the mkThinApp call. Every thin backend entry (box64/native/fex) builds
# through this, so the config→builder plumbing exists once and the launch-block CONTRACT is enforced here:
# a block that misspells a field or grows an undeclared one is a named eval error, not a silently-dropped
# attr or an opaque unexpected-argument failure inside mkThinApp.
{ lib, mkThinApp }:
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
  (mkThinApp {
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
      ;
    # The last-wins save/state rows plus the composable framework/game rows (steam-emu's shim placements).
    saveBinds = cfg.saveBinds ++ cfg.extraBinds;
    payloads = cfg.payloads;
    executables = b.executables or executables;
    broken = {
      systems = cfg.broken.systems ++ (b.brokenSystems or [ ]);
      reason = if cfg.broken.reason != null then cfg.broken.reason else (b.brokenReason or null);
    };
    # Enabled DLC + the app's own extra trees union ABOVE the base game (after any backend overlay like
    # FEX's patched exe).
    extraLowers =
      (b.extraLowers or [ ]) ++ (map (d: "${d}") enabledDlc) ++ (map (d: "${d}") cfg.extraLowers);
    inherit (b)
      backend
      emulator
      env
      ldLibraryPath
      mangohud
      ;
  })

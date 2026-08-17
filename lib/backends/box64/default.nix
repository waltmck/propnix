# backends/box64 — the box64/native backend REGISTRY ENTRY (Linux content). box64 runs an x86_64 Linux ELF
# on aarch64 by dlopen-bridging the NATIVE host libraries it wraps; on an x86_64 host there is no emulator
# and the ELF runs directly — so this ONE entry serves both the "box64" and "native" registry names (the
# scope aliases native to it with `modules = [ ]` so the shared option module isn't declared twice).
#
# The entry: options.nix declares `box64.*` (the library union, reused by FEX); `build` computes the LAUNCH
# BLOCK — emulator/env/ldLibraryPath — and assembles the package via mkThinBuild → mkThinApp. The library
# union is resolved TWICE on aarch64 (native ∪ x86_64 guest) so the two can't drift (D7); on x86_64
# pkgsX86 == pkgs and it collapses to one native set.
{
  lib,
  stdenv,
  pkgs,
  pkgsX86,
  knobTypes,
  mangohud,
  mkThinBuild,
  box64 ? null, # aarch64-only scope attr; null on x86_64 (native, no emulator)
}:
let
  isAarch64 = stdenv.hostPlatform.isAarch64;
in
{
  modules = [ (import ./options.nix { inherit lib knobTypes; }) ];

  build =
    {
      cfg,
      enabledDlc,
      executables,
    }:
    let
      inherit (cfg.box64) bridgingLibs guestLibs;
      libs =
        if isAarch64 then
          (bridgingLibs pkgs) ++ (bridgingLibs pkgsX86) ++ (guestLibs pkgsX86)
        else
          (bridgingLibs pkgs) ++ (guestLibs pkgs);
    in
    mkThinBuild {
      inherit cfg enabledDlc executables;
      block = {
        backend = if isAarch64 then "box64" else "native";
        emulator =
          if isAarch64 then
            assert lib.assertMsg (
              box64 != null
            ) "propnix: box64 backend needs box64 on aarch64, but the scope provided none";
            "${box64}/bin/box64"
          else
            null;
        ldLibraryPath = lib.makeLibraryPath libs;
        # box64 seal knobs (aarch64 only): suppress every rcfile so ~/.box64rc can't change behaviour +
        # PREFER_WRAPPED (all-or-nothing). The game's unified `env` merges OVER these (so it can override).
        env =
          (lib.optionalAttrs isAarch64 {
            BOX64_NORCFILES = "1";
            BOX64_PREFER_WRAPPED = "1";
          })
          // cfg.env;
        mangohud = "${mangohud}";
      };
    };
}

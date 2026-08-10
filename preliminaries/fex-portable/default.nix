# fex-portable — FEX-Emu 2605 patched to run on hosts whose kernel page size is
# larger than the 4K that upstream FEX (>= 2508) hard-requires. Targets Apple
# Silicon / Asahi Linux at 16K, but the patch derives every boundary from
# sysconf(_SC_PAGESIZE) rather than assuming 16K, so it is page-size agnostic.
#
# The fork is expressed as a single reviewable patch over the exact FEX source
# nixpkgs already pins (version 2605); we reuse nixpkgs' build machinery
# (cmake flags, thunks, FEXServer) via overrideAttrs rather than vendoring the
# tree. See README.md for the wall-by-wall rationale behind each hunk.
#
#   Build:  nix-build preliminaries/fex-portable
#   Result: bin/FEX, bin/FEXInterpreter, bin/FEXServer — run x86_64 / x86 Linux
#           ELFs on aarch64 with a 16K host page.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs {
    system = "aarch64-linux";
    config.allowUnfree = true;
  },
}:
pkgs.fex.overrideAttrs (old: {
  pname = "fex-portable";

  # Applied with -p1 during patchPhase, before nixpkgs' own postPatch thunk-path
  # substitutions (they touch disjoint lines, so ordering is safe).
  patches = (old.patches or [ ]) ++ [ ./fex-portable.patch ];

  passthru = (old.passthru or { }) // {
    # Marks this as the large-host-page fork so dependents can assert on it.
    portableHostPage = true;
    upstreamVersion = old.version or "2605";
  };

  meta = (old.meta or { }) // {
    description = "FEX-Emu 2605 with large host-page (16K) support — propnix fork";
  };
})

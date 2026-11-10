# box64-latest.nix — box64, the x86_64-Linux→aarch64 emulator behind the THIN `box64` backend
# (lib/backends/box64), pinned to the newest upstream release rather than the one nixpkgs carries.
#
# nixpkgs' derivation is reused for everything but the source (its cmake flags, the dynarec switch, the
# assembler-flag substitution and the x86_64 hello-world check), so a bump is a tag + hash here. Built by
# the cachix `tools` job on aarch64 (ci/cache-audit.sh keeps that true).
{
  lib,
  box64,
  fetchFromGitHub,
}:
box64.overrideAttrs (old: rec {
  version = "0.4.5-1";
  src = fetchFromGitHub {
    owner = "ptitSeb";
    repo = "box64";
    tag = "v${version}";
    hash = "sha256-RSFS7OlRWJpt+ehwyzmJJ5BbOj7EfJLQF0Pvjx1isLo=";
  };
})

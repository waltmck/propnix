# box64-latest.nix — the box64 x86_64-Linux→aarch64 emulator for the (deferred) box64 guest path.
#
# STATUS: BACKLOG placeholder. This pass ships only the winefex (x86_64-Windows) path; the box64 path
# (`makeAppBox64` + a Linux-native GOG title) is explicitly deferred (plan §Backlog). box64 is carried
# in the scope now so the edge exists and the backlog work is a drop-in, not a rewire.
#
# For now this simply re-exports nixpkgs' pinned box64 (a known-good upstream release from cache) rather
# than a from-source pin: there is no verified box64 rev/hash for the Linux-guest path yet, and a
# speculative FOD hash would only break evaluation. When the box64 path is picked up, pin a specific
# upstream commit here (fetchFromGitHub + box64.overrideAttrs) and re-verify on the 16K host — the same
# discipline the winefex emulators follow.
{
  box64,
}:
box64

# mangohud.nix — MangoHud, whose `mangoapp` is the PROPNIX_BENCH overlay gamescope runs
# (pkgs/propnix-launcher/src/gamescope.rs), built with FEX-Emu stats support.
#
# nixpkgs' derivation is reused unchanged except for `-Dwith_fex=true`. Without it the `fex_stats` option
# still parses but shows nothing: the reader of FEX's per-process `/dev/shm/fex-<pid>-stats` (JIT load,
# hot threads, SIGBUS / self-modifying-code / softfloat-fallback counts) is compiled in only with the flag.
# aarch64 only (lib/default.nix): FEX exists only there. Built by the cachix `tools` job.
{
  lib,
  mangohud,
}:
mangohud.overrideAttrs (old: {
  mesonFlags = (old.mesonFlags or [ ]) ++ [ (lib.mesonBool "with_fex" true) ];
})

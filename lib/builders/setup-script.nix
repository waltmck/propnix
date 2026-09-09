# builders/setup-script.nix — mkSetupScript: wrap a game's setup.sh as the store-path executable the
# launcher runs before the game (the `wine.setupScript` tuning knob). The wrapper is the uniform contract
# every setup script gets: `set -euo pipefail` (a mid-script error aborts → the launcher aborts the
# launch) + a pinned coreutils/sed/awk/grep PATH (hermetic, independent of the caller's env) — previously
# copy-pasted verbatim by each game — + the payload-tree lookup helpers (payload-lib.sh: `payload_find` /
# `payload_require` / `payload_trees`). `withIniLib` prepends the shared `ini_set` INI editor (ini-lib.sh;
# see there for its INI_SEP/INI_CRLF/INI_SKIP_COMMENTS knobs).
#
# payload-lib is UNCONDITIONAL where ini-lib is opt-in, deliberately: ini-lib is an editor a game may or may
# not want, whereas payload-lib is the shell side of an env-var contract the launcher applies to EVERY setup
# script (`PROPNIX_PAYLOADS`). Gating it would mean a script could receive the list but not the sanctioned,
# order-respecting way to read it — and the near-certain result is per-game re-implementations that get the
# priority order (or the `PROPNIX_PAYLOADS`-unset fallback) subtly wrong. Cost is ~60 lines of shell text in
# each setup script's store path.
{
  lib,
  writeShellScript,
  coreutils,
  gnused,
  gawk,
  gnugrep,
}:
{
  name, # derivation name, e.g. "factorio-setup"
  script, # path to the game's setup.sh (readFile'd — the script text is part of the wrapper)
  withIniLib ? false,
  runtimeInputs ? [
    coreutils
    gnused
    gawk
    gnugrep
  ],
}:
writeShellScript name ''
  set -euo pipefail
  export PATH=${lib.makeBinPath runtimeInputs}:$PATH
  ${builtins.readFile ./payload-lib.sh}
  ${lib.optionalString withIniLib (builtins.readFile ./ini-lib.sh)}
  ${builtins.readFile script}
''

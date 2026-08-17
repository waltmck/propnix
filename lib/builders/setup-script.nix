# builders/setup-script.nix — mkSetupScript: wrap a game's setup.sh as the store-path executable the
# launcher runs before the game (the `wine.setupScript` tuning knob). The wrapper is the uniform contract
# every setup script gets: `set -euo pipefail` (a mid-script error aborts → the launcher aborts the
# launch) + a pinned coreutils/sed/awk/grep PATH (hermetic, independent of the caller's env) — previously
# copy-pasted verbatim by each game. `withIniLib` prepends the shared `ini_set` INI editor (ini-lib.sh;
# see there for its INI_SEP/INI_CRLF/INI_SKIP_COMMENTS knobs).
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
  ${lib.optionalString withIniLib (builtins.readFile ./ini-lib.sh)}
  ${builtins.readFile script}
''

# cred-lib.sh — the credential prologue shared by the three propnix fetchers
# (fetchGogGalaxyBuild, fetchGogLinuxInstaller, fetchSteamDepot). Sourced into each
# FOD builder script via `source ${./cred-lib.sh}`; only the genuinely-common steps
# live here — every fetcher keeps its OWN account-iteration loop and download body
# (they differ structurally: gogdl auth-config transform vs verbatim token drop-in
# vs isolated-storage tar replay).
#
# The credential store contract (see config/credentials.nix):
#   /propnix/credentials.toml               — the pointer (credentialDir = in-sandbox root, normally /propnix)
#   <credentialDir>/<kind>/<username>/…     — one credential file per account (`propnix cred add <kind>`)
# reachable inside the sandbox via `services.propnix.enable` or --extra-sandbox-paths.
#
# SECRECY DISCIPLINE: nothing here ever reads, echoes, or logs a token value, token
# path, or username — errors speak only in terms of the store and the `propnix cred`
# command. credentialDir itself is a filesystem path (a pointer), not a secret.

# propnix_require_credentials <kind> [extra-line]...
#   Verifies /propnix/credentials.toml is readable inside the sandbox; if not, prints
#   the `propnix cred add <kind>` guidance for that store kind (gog | steam), then any
#   caller-supplied extra lines verbatim (fetcher-specific hints: the drop-dir offline
#   path, a buyUrl, the title needing the account), and exits 1.
propnix_require_credentials() {
  local kind="$1"
  shift
  [ -r /propnix/credentials.toml ] && return 0
  echo "propnix: no credentials at /propnix/credentials.toml" >&2
  case "$kind" in
    gog)
      echo "  Add a GOG account:  propnix cred add gog   (populates /var/lib/propnix)" >&2
      echo "  and enable the sandbox bind (services.propnix.enable, or" >&2
      echo "  --extra-sandbox-paths /propnix=/var/lib/propnix)." >&2
      ;;
    steam)
      echo "  Add one:  propnix cred add steam   (one-time Steam Guard 2FA)" >&2
      echo "  and enable the sandbox bind (services.propnix.enable, or" >&2
      echo "  --extra-sandbox-paths /propnix=/var/lib/propnix)." >&2
      ;;
    *)
      echo "  Add an account with:  propnix cred add $kind" >&2
      ;;
  esac
  local line
  for line in "$@"; do
    echo "$line" >&2
  done
  exit 1
}

# propnix_creddir
#   Prints credentialDir from /propnix/credentials.toml — the in-sandbox credential
#   root (normally /propnix). A filesystem path, not a secret.
propnix_creddir() {
  grep -oP 'credentialDir\s*=\s*"\K[^"]+' /propnix/credentials.toml
}

# propnix_account_files <kind> <glob-expansion>...
#   Collects the READABLE account files from the caller's (already shell-expanded)
#   globs into the array PROPNIX_ACCOUNT_FILES. A non-matching glob reaches us as its
#   literal pattern, which the -r test drops. If no account file survives, emits the
#   legible "no accounts" error naming `propnix cred add <kind>` and exits 1.
propnix_account_files() {
  local kind="$1"
  shift
  PROPNIX_ACCOUNT_FILES=()
  local f
  for f in "$@"; do
    [ -r "$f" ] && PROPNIX_ACCOUNT_FILES+=("$f")
  done
  if [ "${#PROPNIX_ACCOUNT_FILES[@]}" -eq 0 ]; then
    case "$kind" in
      gog) echo "propnix: no GOG account tokens found under the credential store" >&2 ;;
      steam) echo "propnix: no Steam account credentials found under the credential store" >&2 ;;
      *) echo "propnix: no $kind account credentials found under the credential store" >&2 ;;
    esac
    echo "  Add one with:  propnix cred add $kind" >&2
    exit 1
  fi
}

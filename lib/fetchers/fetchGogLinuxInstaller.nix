# fetchGogLinuxInstaller (lgogdownloader backend) — the production GOG *Linux offline-installer* fetcher,
# the sibling of fetchGogGalaxyBuild. GOG's Galaxy content-system has NO Linux builds (only Windows/Mac),
# so a native Linux game is delivered as its GOG **offline installer** (a MojoSetup shell script with a zip
# appended). That is a different API from Galaxy depots, so it is a different tool: lgogdownloader's
# `--download-file`, not gogdl.
#
# WHY lgogdownloader (and why it is fine here): nixpkgs lgogdownloader 3.18 crashes non-deterministically on
# `--galaxy-install` (the Galaxy-depot path — the reason fetchGogGalaxyBuild uses gogdl instead). This
# fetcher uses `--download-file`, a DIFFERENT, stable code path (proven end-to-end in the PoC), so the 3.18
# crash does not apply. One flat file out, content-addressed.
#
# CREDENTIALS — reuses the SAME store as the Windows path, with ZERO transform. `propnix cred add gog` writes
# a FLAT `galaxy_tokens.json` that IS lgogdownloader's own on-disk token format (fetchGogGalaxyBuild's header
# documents this: it transforms that same file INTO gogdl's keyed shape; here we just drop it into
# lgogdownloader's config dir verbatim). So:
#   * /propnix/credentials.toml            — the pointer (credentialDir = the in-sandbox root, normally /propnix)
#   * /propnix/gog/<username>/galaxy_tokens.json  — one per GOG account (`propnix cred add gog`)
# are consumed directly. Multi-account: each stored token is tried until one OWNS the file (mirrors the
# Galaxy fetcher). Token PATHS/usernames/contents are never printed.
#
# DETERMINISM: the offline installer is a fixed, versioned artifact on GOG's CDN, so identical bytes → same
# `outputHash`. `size` is the OBSERVED byte count, checked BEFORE the hash: GOG serves a short HTML 302 to
# the login page when a token is expired/lacks the file, so this turns that into a legible error (or a
# fall-through to the next account) instead of a hash mismatch after a multi-GB download (PoC §1).
{
  lib,
  runCommand,
  lgogdownloader,
  coreutils,
  gnugrep,
  cacert,
}:
{
  pname ? "gog-linux-installer",
  # lgogdownloader file selector: "gamename/fileid" (e.g. "stellaris/en3installer0") or, for a DLC,
  # "gamename/dlcname/fileid". The fileid encodes the platform+language (Linux installer), so `os` is implicit.
  fileId,
  outputHash, # flat sha256 (SRI) of the downloaded installer file
  outputHashAlgo ? "sha256",
  size, # OBSERVED byte count of the installer — a pre-hash sanity gate (see DETERMINISM above)
  title ? "this GOG title", # human text for the not-credentialed / not-owned error (be specific — PoC §3.3)
  buyUrl ? "https://www.gog.com",
}:
runCommand (lib.strings.sanitizeDerivationName pname)
  {
    inherit outputHash outputHashAlgo;

    meta = {
      license = lib.licenses.unfree;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };

    outputHashMode = "flat";

    nativeBuildInputs = [
      lgogdownloader
      coreutils
      gnugrep
    ];
    # cacert must be a REAL input, not merely interpolated: the sandbox ships no CA bundle, so lgogdownloader's
    # TLS fails with "Use --cacert to set the path for CA certificate bundle" unless these point at a real one.
    buildInputs = [ cacert ];
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    allowSubstitutes = true;
    preferLocalBuild = true;

    inherit
      fileId
      size
      title
      buyUrl
      ;
  }
  ''
    set -euo pipefail

    # Shared credential prologue (credentials.toml check, creddir extraction, account glob): cred-lib.sh.
    source ${./cred-lib.sh}
    propnix_require_credentials gog \
      "  This payload is $title. Own it at $buyUrl"
    creddir=$(propnix_creddir)

    # Collect every stored GOG token. `propnix cred` writes <root>/gog/<username>/galaxy_tokens.json; the second
    # glob keeps backward-compat with a single-file store. Paths/usernames are never printed.
    propnix_account_files gog "$creddir"/gog/*/galaxy_tokens.json "$creddir"/galaxy_tokens.json

    export HOME="$TMPDIR/home"
    # config.cfg's `directory = .` would override --directory, so we run from the output dir and pass none.
    mkdir -p "$TMPDIR/dl"

    fetched=0
    for _tok in "''${PROPNIX_ACCOUNT_FILES[@]}"; do
      rm -f "$TMPDIR/dl/payload.bin"
      # The stored galaxy_tokens.json IS lgogdownloader's own format — drop it in verbatim (no transform). The
      # mount is read-only + lgogdownloader rewrites its token on refresh, so work from a private writable copy.
      export XDG_CONFIG_HOME="$TMPDIR/cfg-$RANDOM"
      export XDG_CACHE_HOME="$TMPDIR/cache"
      install -d -m700 "$XDG_CONFIG_HOME/lgogdownloader" "$XDG_CACHE_HOME" "$HOME"
      install -m600 "$_tok" "$XDG_CONFIG_HOME/lgogdownloader/galaxy_tokens.json"

      # Success = lgogdownloader exits 0 AND the file is the expected byte count. A wrong/expired account
      # yields a nonzero exit or a short 302-to-login body → fall through to the next token.
      if ( cd "$TMPDIR/dl" && lgogdownloader --download-file "$fileId" --no-remote-xml -o payload.bin ) \
        && [ "$(stat -c%s "$TMPDIR/dl/payload.bin" 2>/dev/null || echo 0)" = "$size" ]; then
        fetched=1
        break
      fi
      echo "propnix: this account could not fetch $fileId; trying the next configured account" >&2
    done
    if [ "$fetched" -ne 1 ]; then
      echo "propnix: no configured GOG account could fetch $fileId ($title)" >&2
      echo "  (none owns it, all tokens are expired/invalid, or the fileId is stale). Own it at $buyUrl" >&2
      exit 1
    fi

    mv "$TMPDIR/dl/payload.bin" "$out"
  ''

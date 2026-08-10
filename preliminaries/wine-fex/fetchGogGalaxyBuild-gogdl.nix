# fetchGogGalaxyBuild (gogdl backend) — the production GOG Galaxy fetcher (D15; PLAN2 §3.1).
#
# Downloads a SPECIFIC GOG Galaxy build (pinned by buildId) as a content-addressed FOD, so every
# package pins { version; buildId; hash; } nixpkgs-style and stays reproducible across GOG updates
# (offline installers are latest-only and break; see RESEARCH §7 / D15 / PLAN2 §3.1). Galaxy delivers the game
# TREE directly from the content system — no InnoSetup/innoextract step.
#
# WHY gogdl, NOT lgogdownloader: nixpkgs lgogdownloader 3.18 crashes non-deterministically on
# --galaxy-install (std::out_of_range). gogdl 1.2.2 (Heroic's depot downloader) is a clean, purpose-
# built Galaxy client. VERIFIED 2026-08-07: two independent full downloads of Hollow Knight windows/
# x64 build 59545516053866453 into different /var/tmp dirs produced byte-identical recursive NAR
# hashes (5,262,883,798 bytes, 1789 files, 19 dirs) → sha256-zNs+los9+7taVgCKmFrVrKGFHQMqJkB/Pau6nnE5EkU=.
#
# DETERMINISM (mechanism, not just the match):
#   * gogdl's persistent manifest cache lives at $GOGDL_CONFIG_PATH/heroic_gogdl/manifests (constants.py
#     28-31), OUTSIDE the game tree — we point it at a throwaway dir so the run is a true full download.
#   * In-tree bookkeeping (.gogdl-resume, .gogdl-download-cache/, *.tmp) is self-removed by gogdl on
#     successful completion (task_executor.py). We still prune it belt-and-suspenders below.
#   * goggame-<id>.{info,hashdb} are DEPOT content (gogdl only ever reads them; no install-time
#     timestamps), so they are byte-identical across runs.
#   * Multithreaded chunk order is irrelevant: each file's bytes are fixed by the manifest, and NAR
#     hashing sorts dir entries and ignores mtimes / non-exec permission bits (RESEARCH §7). Only
#     content, structure, and the exec bit feed the hash — all manifest-determined.
#
# AUTH (no secrets in this file, no secrets ever printed):
#   gogdl reads a JSON auth-config keyed by GOG's Galaxy client id "46899977096215655" (auth.py CLIENT_ID);
#   value is the token dict { access_token, refresh_token, expires_in, loginTime, ... }. Its expiry test
#   is `time.time() >= loginTime + expires_in` (auth.py:80); on expiry it refreshes from refresh_token
#   using gogdl's OWN hardcoded client id+secret and writes the refreshed dict back to the auth-config
#   path (auth.py:82-116) — so the auth-config file MUST be writable.
#
#   propnix's credential is lgogdownloader's galaxy_tokens.json (a FLAT token object minted against the
#   same Galaxy client). We transform it file->file with jq into gogdl's keyed shape and force a refresh
#   by pinning loginTime:0 — gogdl then always refreshes the access token from the refresh_token on first
#   API call. GOG does not rotate refresh tokens (RESEARCH §7), so this is hands-off and stable. gogdl
#   needs ONLY this token JSON — not cookies.txt or config.cfg. No token value is ever read, echoed, or
#   logged: jq writes straight to a file, and we never run `gogdl auth` (which prints tokens to stdout).
#
# BUILDER REQUIREMENTS (what must be bind-mounted / present):
#   * /propnix (read-only) via:  nix build --extra-sandbox-paths /propnix=/var/tmp/propnix ...
#       - /propnix/credentials.toml   (holds `credentialDir = "..."`; not a secret path)
#       - <credentialDir>/galaxy_tokens.json   (the only credential file gogdl needs)
#   * Network: automatic — this is an FOD, so it gets network under sandbox=true (RESEARCH §7).
#   * pkgs.cacert MUST be a real build input, not just interpolated into SSL_CERT_FILE (RESEARCH §13).
#
# Usage:
#   fetchGogGalaxyBuild {
#     productId = "1308320804";        # NUMERIC GOG product id (gogdl needs the id, NOT the slug)
#     buildId   = "59545516053866453";
#     version   = "1.5.12620";
#     hash      = "sha256-zNs+los9+7taVgCKmFrVrKGFHQMqJkB/Pau6nnE5EkU=";
#   }                                  # platform defaults to windows/x64
#
# Resolve productId from the public API (unauthenticated, RESEARCH §7):
#   slug -> id:   https://api.gog.com/products?...   or  https://embed.gog.com/products/<slug>
#   builds:       https://content-system.gog.com/products/<id>/os/windows/builds?generation=2
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs {
    system = "aarch64-linux";
    config.allowUnfree = true;
  },
}:
{
  productId, # NUMERIC GOG product id, e.g. "1308320804" (Hollow Knight). NOT the slug.
  buildId, # the pinned GOG Galaxy build id
  version, # human version string, for the derivation name / provenance
  hash, # recursive sha256 of the assembled game tree
  platform ? "windows", # gogdl choices: windows | osx | linux (default target for wine+FEX)
  lang ? "en", # resolves to the build's only language when there is one (en -> en-US for HK)
  pname ? "gog-galaxy-build",
}:
pkgs.runCommand "${pname}-${version}"
  {
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = hash;

    nativeBuildInputs = [
      pkgs.gogdl
      pkgs.jq
      pkgs.coreutils
    ];
    # cacert must be a real build input (RESEARCH §13): with it only in the string, Python's default
    # SSL context loads 0 CA certs and every GOG TLS call fails with a misleading self-signed error.
    buildInputs = [ pkgs.cacert ];
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

    allowSubstitutes = false;
    preferLocalBuild = true;

    inherit productId buildId platform lang;
  }
  ''
    set -euo pipefail

    if [ ! -r /propnix/credentials.toml ]; then
      echo "propnix: no credentials at /propnix/credentials.toml" >&2
      echo "  nix build --extra-sandbox-paths /propnix=/var/tmp/propnix ..." >&2
      exit 1
    fi
    # credentialDir is a filesystem path, not a secret. Never printed.
    creddir=$(grep -oP 'credentialDir\s*=\s*"\K[^"]+' /propnix/credentials.toml)
    if [ ! -r "$creddir/galaxy_tokens.json" ]; then
      echo "propnix: galaxy_tokens.json not found under credentialDir" >&2
      exit 1
    fi

    export HOME="$TMPDIR/home"
    export GOGDL_CONFIG_PATH="$TMPDIR/gogdl-cfg"   # -> manifest cache lands OUTSIDE the game tree
    install -d -m700 "$HOME" "$GOGDL_CONFIG_PATH"
    mkdir -p "$TMPDIR/dl"

    # Build gogdl's auth-config by a PURE file->file transform. No token value ever reaches stdout.
    #   * key it by GOG's Galaxy client id (gogdl's CLIENT_ID) so gogdl finds the tokens
    #   * loginTime:0 forces gogdl to treat the stored access_token as expired and refresh it from the
    #     (non-rotating) refresh_token on first use — robust regardless of the stored token's age.
    authcfg="$TMPDIR/gogdl_auth.json"   # MUST be writable: gogdl writes the refreshed token back here
    jq '{ "46899977096215655": (. + {loginTime: 0}) }' \
      "$creddir/galaxy_tokens.json" > "$authcfg"
    chmod 600 "$authcfg"

    # Download the pinned build. NEVER `gogdl auth` (auth.py handle_cli prints tokens to stdout).
    gogdl --auth-config-path "$authcfg" \
      download "$productId" \
      --platform "$platform" \
      --build "$buildId" \
      --lang "$lang" \
      --skip-dlcs \
      --path "$TMPDIR/dl"

    echo "=====PROPNIX-LAYOUT-BEGIN====="
    find "$TMPDIR/dl" -maxdepth 2 | sort | head -80
    echo "  file count: $(find "$TMPDIR/dl" -type f | wc -l)"
    echo "=====PROPNIX-LAYOUT-END====="

    # gogdl installs into a single game dir under $TMPDIR/dl (folder_name from the manifest, e.g.
    # "Hollow Knight"); publish its contents as $out.
    mkdir -p "$out"
    inner=$(find "$TMPDIR/dl" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -z "$inner" ]; then echo "no install dir produced" >&2; exit 1; fi
    cp -a "$inner"/. "$out/"

    # Belt-and-suspenders: drop gogdl's own bookkeeping (already self-cleaned on success) so the
    # recursive hash can never be perturbed by a partial/interrupted state. These are gogdl-internal,
    # never depot content. Note: goggame-<id>.{info,hashdb} are KEPT — they are depot files.
    find "$out" \( \
         -name '.gogdl-resume' \
      -o -name '.gogdl-download-cache' \
      -o -name '.gogdl-redist-manifest' \
      -o -name '.gogdl-linux-manifest' \
      -o -name '*.tmp' \
      -o -name '*.delta' \
      \) -prune -exec rm -rf {} + 2>/dev/null || true

    # Sanity: a windows build must contain the game executable, else the tree was truncated.
    test -n "$(find "$out" -iname '*.exe' -print -quit)" \
      || { echo "install truncated: no .exe in tree" >&2; exit 1; }
  ''

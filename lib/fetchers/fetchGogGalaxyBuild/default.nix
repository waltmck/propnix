# fetchGogGalaxyBuild (gogdl backend) — the production GOG Galaxy fetcher (D15; PLAN2 §3.1).
#
# Downloads a SPECIFIC GOG Galaxy build (pinned by buildId) as a content-addressed FOD, so every
# package pins { version; buildId; outputHash; } nixpkgs-style and stays reproducible across GOG updates
# (offline installers are latest-only and break; see RESEARCH §7 / D15 / PLAN2 §3.1). Galaxy delivers the
# game TREE directly from the content system — no InnoSetup/innoextract step.
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
#   * /propnix (read-only) via `services.propnix.enable` (nixos), or manually:
#       nix build --extra-sandbox-paths /propnix=/var/lib/propnix ...
#       - /propnix/credentials.toml         (holds `credentialDir = "/propnix"`; a pointer, not a secret)
#       - /propnix/gog/<username>/galaxy_tokens.json   (one per GOG account; populate via `propnix cred add gog`)
#         (backward-compat: an older single-account layout with the token directly at
#          <credentialDir>/galaxy_tokens.json is also accepted.)
#     MINIMAL CONTENTS: `extra-sandbox-paths` bypasses the reproducibility sandbox, so the bind must carry
#     ONLY auth — the store holds ONLY the credentials.toml pointer + per-account galaxy_tokens.json files
#     (NO lgogdownloader config.cfg / cookies.txt: config.cfg holds language/DLC/platform/thread settings that
#     could steer a download). This fetcher never reads them anyway — every download parameter is pinned in
#     versions.json and the auth-config handed to gogdl is derived SOLELY from a galaxy_tokens.json — so the
#     bind can only make a fetch succeed or fail, never change WHAT is fetched. See config/credentials.nix.
#   * Network: automatic — this is an FOD, so it gets network under sandbox=true (RESEARCH §7).
#   * pkgs.cacert MUST be a real build input, not just interpolated into SSL_CERT_FILE (RESEARCH §13).
#
# DISCOVERY LADDER (plan §3):
#   * Rung-0 — the Nix FOD cache itself: if some store path already realises `outputHash`, Nix returns it
#     and this builder never runs. Automatic, nothing to code.
#   * Rung-1 — a manual DROP: if a payload for this pin is staged on disk under the drop dir, copy it and
#     skip the network entirely (offline / air-gapped / pre-seeded mirror). Keyed by `buildId` (GOG's
#     build id is unique per pin and filesystem-safe; the SRI `outputHash` is base64 and NOT path-safe).
#     Drop base defaults to `/propnix/drop` (already inside the bound /propnix), overridable by the impure
#     env var PROPNIX_DROP_DIR (declared in impureEnvVars so an FOD may read it without changing the hash;
#     the override path must itself be bind-mounted into the sandbox).
#   * Rung-2 — gogdl download (below). Multi-account: try each stored GOG token until one fetches the pinned
#     build (i.e. the account that OWNS it) — a not-owned/expired account fails at manifest resolution, before
#     any bulk download, and we fall through to the next; if none succeed we emit a legible combined error
#     (not-owned / expired token / stale pin).
#
# The versions.json COMPONENT (UPDATE-AUTOMATION §2) is passed straight in; the signature lists every
# schema key explicitly (no `...`, PLAN2 §9). `kind`/`generation`/`manifestId` are carried for provenance
# and future manifest-level pinning; the download itself is fully determined by productId+buildId+os+lang.
{
  lib,
  runCommand,
  gogdl,
  jq,
  coreutils,
  cacert,
}:
{
  pname ? "gog-galaxy-build",
  productId, # NUMERIC GOG product id, e.g. "1308320804" (Hollow Knight). NOT the slug.
  buildId, # the pinned GOG Galaxy build id
  version, # human version string, for the derivation name / provenance
  outputHash, # recursive sha256 (SRI) of the assembled game tree
  outputHashMode ? "recursive",
  outputHashAlgo ? "sha256",
  os ? "windows", # gogdl --platform: windows | osx | linux (default target for wine+FEX)
  lang ? "en", # resolves to the build's only language when there is one (en -> en-US for HK)
  kind ? "game", # provenance only (game | dlc); not consumed by the download
  generation ? 2, # GOG content-system generation (builds API ?generation=…); provenance only here
  manifestId ? null, # optional manifest pin for future manifest-level reproducibility; unused this pass
  # gogdl download parallelism = `--max-workers` (its ONLY throughput knob — gogdl has no bandwidth throttle,
  # unlike the official Galaxy client). gogdl defaults this to the CPU thread count (~8 here), which badly
  # under-uses the link because GOG's CDN throttles EACH connection: aggregate speed ≈ per-connection cap ×
  # workers, so more parallel workers ≈ "unlimited bandwidth". Default it absurdly high (64, ~8× the CPU
  # default) to saturate the pipe; a build-time constant only, so it never affects the content-addressed
  # output (identical bytes at any worker count → same `outputHash`, existing payloads are NOT re-fetched).
  maxWorkers ? 64,
  # DLC-only fetch: when set to a GOG DLC id, download ONLY that DLC's depot files (gogdl `--dlc-only
  # --with-dlcs --dlcs <id>`) from THIS product's build, instead of the base game (`--skip-dlcs`). Both DLC
  # flags are load-bearing: `--dlcs <id>` names WHICH dlc, but gogdl also gates the whole DLC path on the
  # `--with-dlcs` boolean (`dlcs_should_be_downloaded`) — which, absent `--with-dlcs`, defaults to False (its
  # store_true arg is registered first, so it wins the shared-dest default), making gogdl short-circuit to
  # "Owned dlcs []" and download NOTHING *before ever checking ownership*. `--with-dlcs` opens the gate;
  # `--dlcs <id>` then filters the owned set down to just this DLC. The result is the DLC's
  # overlay tree — game-relative paths (e.g. `data/<mod>/…`), no base-game exe — consumed by a game's `dlc`
  # set + makeAppWine's runtime overlay (`withDlc`). null → the normal base-game fetch. The DLC rides the same
  # base `buildId`/`productId` (GOG bundles DLC depots into the base build), so pin those + this `dlcId`.
  dlcId ? null,
}:
# GOG `version` strings are free-form (spaces, parens, dates, e.g. "1.0(A)"); sanitize for the store name.
# The download is determined by buildId, not this string — it's provenance / the derivation name only.
runCommand (lib.strings.sanitizeDerivationName "${pname}-${version}")
  {
    inherit outputHash outputHashMode outputHashAlgo;

    nativeBuildInputs = [
      gogdl
      jq
      coreutils
    ];
    # cacert must be a real build input (RESEARCH §13): with it only in the string, Python's default
    # SSL context loads 0 CA certs and every GOG TLS call fails with a misleading self-signed error.
    buildInputs = [ cacert ];
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    # An FOD may read these ambient vars without perturbing its output hash. proxy vars are standard for a
    # network fetcher; PROPNIX_DROP_DIR is the Rung-1 override (must be bind-mounted to be reachable).
    impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [ "PROPNIX_DROP_DIR" ];

    allowSubstitutes = false;
    preferLocalBuild = true;

    # Passed into the builder env (buildId/productId/os/lang steer gogdl; the rest are provenance).
    inherit productId buildId version os lang kind generation;
    platform = os; # gogdl's flag name for `os`
  }
  ''
    set -euo pipefail
    mkdir -p "$out"

    # ── Rung-1: manual drop ────────────────────────────────────────────────────────────────────────
    # If this exact build is staged on disk, copy it and skip the network. Keyed by buildId (path-safe).
    dropbase="''${PROPNIX_DROP_DIR:-/propnix/drop}"
    if [ -d "$dropbase/$buildId" ] && [ -n "$(find "$dropbase/$buildId" -mindepth 1 -print -quit)" ]; then
      echo "propnix: using staged drop for build $buildId (skipping network)" >&2
      cp -a "$dropbase/$buildId"/. "$out/"
    else
      # ── Rung-2: gogdl download ────────────────────────────────────────────────────────────────────
      if [ ! -r /propnix/credentials.toml ]; then
        echo "propnix: no credentials at /propnix/credentials.toml" >&2
        echo "  Add a GOG account:  propnix cred add gog   (populates /var/lib/propnix)" >&2
        echo "  and enable the sandbox bind (services.propnix.enable, or" >&2
        echo "  --extra-sandbox-paths /propnix=/var/lib/propnix)." >&2
        echo "  (Or stage a drop at \$PROPNIX_DROP_DIR/$buildId to fetch offline.)" >&2
        exit 1
      fi
      # credentialDir is a filesystem path (the in-sandbox credential root, normally /propnix), not a secret.
      creddir=$(grep -oP 'credentialDir\s*=\s*"\K[^"]+' /propnix/credentials.toml)

      # Collect every GOG account token the store offers. The `propnix cred` CLI writes the multi-account
      # layout <root>/gog/<username>/galaxy_tokens.json; the second glob keeps backward-compat with the older
      # single-file model (credentialDir naming the dir that directly holds galaxy_tokens.json). Non-matching
      # globs expand to their literal pattern, which the `-r` test drops. Token PATHS/usernames are never
      # printed (nor the token contents).
      tokens=()
      for _t in "$creddir"/gog/*/galaxy_tokens.json "$creddir"/galaxy_tokens.json; do
        [ -r "$_t" ] && tokens+=("$_t")
      done
      if [ "''${#tokens[@]}" -eq 0 ]; then
        echo "propnix: no GOG account tokens found under the credential store" >&2
        echo "  Add one with:  propnix cred add gog" >&2
        exit 1
      fi

      export HOME="$TMPDIR/home"
      export GOGDL_CONFIG_PATH="$TMPDIR/gogdl-cfg"   # -> manifest cache lands OUTSIDE the game tree
      install -d -m700 "$HOME" "$GOGDL_CONFIG_PATH"
      authcfg="$TMPDIR/gogdl_auth.json"   # MUST be writable: gogdl writes the refreshed token back here

      # Try each account until one can fetch the pinned build — i.e. the account that OWNS the title. This
      # makes multiple GOG accounts transparent (no per-game account selection): a not-owned/expired account
      # fails at manifest resolution (before any bulk download) and we fall through to the next. The output is
      # content-addressed, so WHICH account fetched it never affects the hash.
      fetched=0
      for _tok in "''${tokens[@]}"; do
        rm -rf "$TMPDIR/dl"; mkdir -p "$TMPDIR/dl"
        # Build gogdl's auth-config by a PURE file->file transform (no token value ever reaches stdout):
        #   * key it by GOG's Galaxy client id (gogdl's CLIENT_ID) so gogdl finds the tokens
        #   * loginTime:0 forces gogdl to refresh the access_token from the (non-rotating) refresh_token on
        #     first use — robust regardless of the stored token's age.
        jq '{ "46899977096215655": (. + {loginTime: 0}) }' "$_tok" > "$authcfg"
        chmod 600 "$authcfg"
        # Download the pinned build. NEVER `gogdl auth` (auth.py handle_cli prints tokens to stdout).
        # `--max-workers` = parallel download threads: set high (see `maxWorkers` above) so many concurrent
        # connections beat GOG's per-connection CDN throttle. Content-invariant → FOD hash unchanged.
        # Success = gogdl exits 0 AND produced files. The second check is load-bearing for DLC: when an
        # account does NOT own the requested DLC, gogdl logs "Owned dlcs []" and exits 0 with an EMPTY tree
        # ("Nothing to do") — so a bare exit-code check would wrongly count a not-owned DLC as fetched. A
        # base-game download always yields files, so this is a no-op there. (`--with-dlcs` is required to even
        # reach the ownership check — see the `dlcId` arg doc for the gogdl gate.)
        if gogdl --auth-config-path "$authcfg" \
            download "$productId" \
            --platform "$platform" \
            --build "$buildId" \
            --lang "$lang" \
            ${if dlcId != null then "--dlc-only --with-dlcs --dlcs ${dlcId}" else "--skip-dlcs"} \
            --max-workers ${toString maxWorkers} \
            --path "$TMPDIR/dl" \
          && [ -n "$(find "$TMPDIR/dl" -mindepth 1 -type f -print -quit)" ]; then
          fetched=1
          break
        fi
        echo "propnix: this account could not fetch ${if dlcId != null then "DLC ${dlcId} of " else ""}build $buildId; trying the next configured account" >&2
      done
      if [ "$fetched" -ne 1 ]; then
        echo "propnix: no configured GOG account could fetch ${if dlcId != null then "DLC ${dlcId} of " else ""}build $buildId of product $productId" >&2
        echo "  (none owns it, all tokens are expired/invalid, or the pinned buildId is stale)." >&2
        exit 1
      fi

      echo "=====PROPNIX-LAYOUT-BEGIN====="
      find "$TMPDIR/dl" -maxdepth 2 | sort | head -80
      echo "  file count: $(find "$TMPDIR/dl" -type f | wc -l)"
      echo "=====PROPNIX-LAYOUT-END====="

      # gogdl installs into a single game dir under $TMPDIR/dl (folder_name from the manifest, e.g.
      # "Hollow Knight"); publish its contents as $out.
      inner=$(find "$TMPDIR/dl" -mindepth 1 -maxdepth 1 -type d | head -1)
      if [ -z "$inner" ]; then echo "no install dir produced" >&2; exit 1; fi
      cp -a "$inner"/. "$out/"
    fi

    # ── common post-processing (both rungs) ──────────────────────────────────────────────────────────
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

    # Sanity: a windows BASE-game build must contain the game executable, else the tree was truncated. A
    # DLC-only fetch (dlcId set) has no exe — it's an overlay tree — so skip this check for a DLC.
    if [ "$os" = "windows" ] && [ "${if dlcId != null then "1" else "0"}" = "0" ]; then
      test -n "$(find "$out" -iname '*.exe' -print -quit)" \
        || { echo "install truncated: no .exe in tree" >&2; exit 1; }
    fi
  ''

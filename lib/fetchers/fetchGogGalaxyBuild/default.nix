# fetchGogGalaxyBuild — the production GOG Galaxy fetcher (D15; PLAN2 §3.1).
#
# Downloads a SPECIFIC GOG Galaxy build (pinned by buildId) as a content-addressed FOD, so every package
# pins { version; buildId; outputHash; } nixpkgs-style and stays reproducible across GOG updates (offline
# installers are latest-only and break; see RESEARCH §7 / D15 / PLAN2 §3.1). Galaxy delivers the game TREE
# directly from the content system — no InnoSetup/innoextract step.
#
# THE DOWNLOADER IS `propnix download gog` (pkgs/propnix-cli, src/pin/). It is the same pipeline that
# `propnix pin` uses to COMPUTE these hashes, with files as the sink instead of a NAR hasher: the same
# content-system client, the same zlib/md5 chunk verification, the same credential handling, host scoring
# and concurrency governor. Hashing and fetching with one implementation is what makes the two agree by
# construction rather than by coincidence — VERIFIED against the pins this repo already carries, and
# cross-checked with `nix hash path`.
#
# Nothing about the BUILD RECIPE enters an FOD's output path (that is `hash(name, outputHash)` alone), so
# changing the downloader neither invalidates nor re-fetches a single already-realised payload.
#
# DETERMINISM (mechanism, not just a match):
#   * The tree is exactly what the build manifest describes: every file's path, size, exec bit and chunk
#     list come from the manifest, and each chunk is verified by md5 both compressed and decompressed.
#   * Nothing but manifest content is ever written — no resume files, no download cache, no temp files —
#     so there is no bookkeeping that a partial or interrupted run could leave behind to perturb the hash.
#   * goggame-<id>.{info,hashdb} are DEPOT content (no install-time timestamps), so they are byte-identical
#     across runs.
#   * Nix's NAR hashing normalizes mtimes and sorts entries, so only content and exec bits matter.
#
# A build whose tree is NOT determined by buildId alone is refused rather than guessed at: some builds
# install a dependency (homeworld-rm's `language_setup`) from GOG's GLOBAL dependency repository, which
# buildId does not pin. Such a build must state which repository build it was pinned against
# (`depsBuildId`), and the download asserts it still matches — a clearer failure than fetching a different
# tree and reporting a hash mismatch.
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
#   * Rung-2 — `propnix download gog` (below). Multi-account: it tries each stored GOG token until one
#     fetches the pinned build (i.e. the account that OWNS it) — `secure_link` IS the ownership gate, so a
#     not-owned or expired account is refused before any bulk transfer; if none succeed the error names
#     every account tried (not-owned / expired token / stale pin).
#
# The versions.json COMPONENT (UPDATE-AUTOMATION §2) is passed straight in; the signature lists every
# schema key explicitly (no `...`, PLAN2 §9). `kind`/`generation`/`manifestId` are carried for provenance
# and future manifest-level pinning; the download itself is fully determined by productId+buildId+os+lang.
{
  lib,
  runCommand,
  propnix-cli,
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
  os ? "windows", # windows | osx | linux (default target for wine+FEX)
  lang ? "en", # resolves to the build's only language when there is one (en -> en-US for HK)
  kind ? "game", # provenance only (game | dlc); not consumed by the download
  generation ? 2, # GOG content-system generation (builds API ?generation=…); provenance only here
  manifestId ? null, # optional manifest pin for future manifest-level reproducibility; unused this pass
  # Which GOG GLOBAL dependency-repository build this pin was computed against. Required for — and only
  # for — a build that installs a dependency INTO the game directory (homeworld-rm's `language_setup`),
  # because `buildId` does not pin that: the tree can change without the build changing. The download
  # ASSERTS the repository still serves this build, so drift is reported as "the dependency repository
  # moved" instead of an unexplained hash mismatch. null for the 15 builds that install no dependency.
  depsBuildId ? null,
  # CEILING on concurrent chunk requests, not a setting to tune: the downloader starts at a handful and
  # hill-climbs on measured throughput, holding each rung steady and comparing medians, so it finds the
  # knee for THIS link rather than trusting a number chosen here. GOG's CDN throttles each connection, so
  # the ceiling only needs to be comfortably above any plausible knee. A build-time constant that cannot
  # affect the content-addressed output (identical bytes at any concurrency → same `outputHash`, so
  # existing payloads are NOT re-fetched).
  workers ? 128,
  # DLC-only fetch: when set to a GOG DLC id, download ONLY that DLC's depot files from THIS product's
  # build instead of the base game. The result is the DLC's overlay tree — game-relative paths (e.g.
  # `data/<mod>/…`), no base-game exe — consumed by a game's `dlc` set + mkWineApp's runtime overlay
  # (`withDlc`). The DLC rides the same base `buildId`/`productId` (GOG bundles DLC depots into the base
  # build), so pin those plus this `dlcId`. null → the normal base-game fetch.
  dlcId ? null,
}:
# GOG `version` strings are free-form (spaces, parens, dates, e.g. "1.0(A)"); sanitize for the store name.
# The download is determined by buildId, not this string — it's provenance / the derivation name only.
runCommand (lib.strings.sanitizeDerivationName "${pname}-${version}")
  {
    inherit outputHash outputHashMode outputHashAlgo;

    nativeBuildInputs = [
      propnix-cli
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

    # Passed into the builder env (buildId/productId/os/lang/workers steer the download; the rest are
    # provenance).
    inherit
      productId
      buildId
      version
      os
      lang
      kind
      generation
      workers
      ;
  }
  ''
    set -euo pipefail
    mkdir -p "$out"

    # ── Rung-1: manual drop ────────────────────────────────────────────────────────────────────────
    # If this exact build is staged on disk, copy it and skip the network. Keyed by buildId (path-safe).
    dropbase="''${PROPNIX_DROP_DIR:-/propnix/drop}"
    if [ -d "$dropbase/$buildId" ] && [ -n "$(find "$dropbase/$buildId" -mindepth 1 -print -quit)" ]; then
      echo "propnix: using staged drop for build $buildId (skipping network)" >&2
      # The drop lives on a bind-mounted host dir, so this copy is unavoidable (rename/link cannot cross a
      # mount point — see the download path below); --reflink=auto makes it free where the filesystem
      # supports block cloning and degrades to a plain copy elsewhere.
      cp -a --reflink=auto "$dropbase/$buildId"/. "$out/"
    else
      # ── Rung-2: propnix download ─────────────────────────────────────────────────────────────────
      # Shared credential prologue (credentials.toml check, creddir extraction): cred-lib.sh.
      source ${../cred-lib.sh}
      propnix_require_credentials gog \
        "  (Or stage a drop at \$PROPNIX_DROP_DIR/$buildId to fetch offline.)"
      # Point the CLI's credential store at the in-sandbox root. It walks the stored GOG accounts itself:
      # `secure_link` IS the ownership gate, so a not-owned or expired account is refused before any bulk
      # transfer, and only when every account has refused does it fail — naming all of them. It holds the
      # REFRESH token rather than a minted access token, because a large title takes longer to fetch than
      # an access token lives.
      export PROPNIX_CRED_DIR="$(propnix_creddir)"

      # Writes the game tree DIRECTLY into $out: files at the root, so there is no wrapper directory to
      # promote and no bookkeeping to prune. Chunks are written to their own offsets as they land, so peak
      # disk is 1x the build — staging then moving would need TWICE that, because inside the sandbox
      # /build and /nix/store are SEPARATE BIND MOUNTS and Linux refuses rename(2) across mount points
      # even on one filesystem (man 2 rename, EXDEV), so a `mv` silently degrades to copy+unlink.
      # NB: the optional flags are interpolated INLINE, not on their own continued lines — an empty
      # `optionalString` after a trailing backslash continues onto a blank line, which ends the command.
      propnix download gog \
        --product-id "$productId" --build-id "$buildId" \
        --os "$os" --lang "$lang" \
        ${
          lib.optionalString (dlcId != null) "--dlc-id ${lib.escapeShellArg dlcId} "
          + lib.optionalString (depsBuildId != null) "--deps-build-id ${lib.escapeShellArg depsBuildId} "
        }--workers "$workers" --dir "$out"
    fi

    # ── common post-processing (both rungs) ──────────────────────────────────────────────────────────
    echo "=====PROPNIX-LAYOUT-BEGIN====="
    find "$out" -maxdepth 2 | sort | head -80
    echo "  file count: $(find "$out" -type f | wc -l)"
    echo "=====PROPNIX-LAYOUT-END====="

    # Sanity: a windows BASE-game build must contain the game executable, else the tree was truncated. A
    # DLC-only fetch (dlcId set) has no exe — it's an overlay tree — so skip this check for a DLC.
    if [ "$os" = "windows" ] && [ "${if dlcId != null then "1" else "0"}" = "0" ]; then
      test -n "$(find "$out" -iname '*.exe' -print -quit)" \
        || { echo "install truncated: no .exe in tree" >&2; exit 1; }
    fi
  ''

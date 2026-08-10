# fetchGogGalaxyBuild — the production GOG fetcher (D15; PLAN2 §3.1). Installs a SPECIFIC GOG Galaxy build
# NOTE: superseded by fetchGogGalaxyBuild-gogdl.nix (the gogdl backend).
# (pinned by buildId) as a content-addressed FOD, so every package pins { version; buildId; hash; }
# nixpkgs-style and stays reproducible across GOG updates (offline installers are latest-only and
# break; see D15 / PLAN2 §3.1). Galaxy installs the game TREE directly — no InnoSetup/innoextract step.
#
# Determinism: --galaxy-no-dependencies avoids redistributable installers, and we copy only the game
# install dir into $out (dropping lgogdownloader bookkeeping) so the recursive hash is stable.
#
# !! KNOWN BLOCKER (2026-08-07): nixpkgs lgogdownloader 3.18 crashes NON-DETERMINISTICALLY on
# --galaxy-install (std::out_of_range string bug — same as its bulk --download mode; only
# --download-file is safe). Sometimes it finishes the install then aborts, sometimes it aborts with
# 0 files. 3.18 is the latest release. This fetcher is therefore NOT usable as-is; the intended fix
# is to reimplement it on `gogdl` (nixpkgs `gogdl`, Heroic's downloader — purpose-built for Galaxy
# depots), which needs GOG token auth plumbing distinct from lgogdownloader's credential. See memory
# `gog-fetch-galaxy-builds`. Kept here as the shape/spec of the production fetcher.
#
# Usage:
#   fetchGogGalaxyBuild { product = "^hollow_knight$"; buildId = "59545516053866453";
#                         version = "1.5.12620"; hash = "sha256-…"; }   # platform defaults to windows/x64
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },
}:
{
  product, # anchored gamename regex, e.g. "^hollow_knight$"
  buildId, # the pinned GOG Galaxy build id (from --galaxy-show-builds)
  version, # human version string, for the derivation name/provenance
  hash, # recursive sha256 of the assembled game tree
  platform ? "w", # w=windows (default target for wine+FEX), l=linux, m=mac
  arch ? "x64",
  lang ? "en",
  pname ? "gog-galaxy-build",
}:
pkgs.runCommand "${pname}-${version}"
  {
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = hash;

    nativeBuildInputs = [ pkgs.lgogdownloader ];
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    allowSubstitutes = false;
    preferLocalBuild = true;
  }
  ''
    if [ ! -r /propnix/credentials.toml ]; then
      echo "propnix: no credentials at /propnix/credentials.toml" >&2
      echo "  nix build --extra-sandbox-paths /propnix=/var/tmp/propnix ..." >&2
      exit 1
    fi
    creddir=$(grep -oP 'credentialDir\s*=\s*"\K[^"]+' /propnix/credentials.toml)
    export XDG_CONFIG_HOME="$TMPDIR/cfg" XDG_CACHE_HOME="$TMPDIR/cache"
    install -d -m700 "$XDG_CONFIG_HOME/lgogdownloader" "$XDG_CACHE_HOME"
    install -m600 "$creddir"/* "$XDG_CONFIG_HOME/lgogdownloader/"
    mkdir -p "$TMPDIR/dl"

    # NOTE: this lgogdownloader version aborts with std::out_of_range (a string-replace bug) AFTER
    # a --galaxy-install completes ("Total size installed: … GiB" prints first). The game files are
    # fully written before the crash, so tolerate the abort and validate the tree below.
    lgogdownloader --galaxy-install "${product}/${buildId}" \
      --galaxy-platform ${platform} --galaxy-arch ${arch} --galaxy-language ${lang} \
      --galaxy-no-dependencies \
      --directory "$TMPDIR/dl" || echo "propnix: lgogdownloader exited nonzero (known post-install crash) — validating tree"

    echo "=====PROPNIX-LAYOUT-BEGIN====="
    find "$TMPDIR/dl" -maxdepth 2 | sort | head -80
    echo "  file count: $(find "$TMPDIR/dl" -type f | wc -l)"
    echo "=====PROPNIX-LAYOUT-END====="

    # Galaxy installs into a single game dir under $TMPDIR/dl; publish its contents as $out.
    mkdir -p "$out"
    inner=$(find "$TMPDIR/dl" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -z "$inner" ]; then echo "no install dir produced" >&2; exit 1; fi
    cp -a "$inner"/. "$out/"
    # Drop lgogdownloader bookkeeping that would make the recursive hash non-deterministic.
    find "$out" \( -iname ".gogdownloader" -o -iname "*.gogdb" -o -iname "galaxy-*.json" \) -prune -exec rm -rf {} + 2>/dev/null || true
    # Sanity: the tree must contain the game executable, else the install was truncated.
    test -n "$(find "$out" -iname '*.exe' -print -quit)" || { echo "install truncated: no .exe in tree" >&2; exit 1; }
  ''

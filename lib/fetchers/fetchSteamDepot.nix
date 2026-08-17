# fetchSteamDepot (DepotDownloader backend) — a GOG-free content fetcher for Steam's SteamPipe system, the
# reproducibility-first sibling of the GOG fetchers. Unlike GOG's Linux offline installers (which expose ONLY
# the current version — a moving target that breaks an FOD on every store update), Steam pins content by
# (appId, depotId, manifestId): a manifest is a content-addressed, versioned snapshot, and Steam RETAINS every
# manifest ever shipped. So a pinned manifestId is downloadable forever → an FOD hash stays valid permanently.
#
# WHY DepotDownloader: SteamRE/DepotDownloader (SteamKit2) is the standard scriptable client — it takes
# `-app -depot -manifest` for an exact version pin and downloads the content-addressed chunks. Determinism is
# structural: the depot AES key is identical for all users (so CDNs/LAN caches work), the manifest fixes the
# file set + hashes, and Nix's NAR hashing normalizes mtimes + sorts entries — so a fixed manifestId yields a
# stable `outputHash` (VERIFIED: two independent runs of app 480 depot 481 manifest 3183503801510301321 gave
# byte-identical output). The tool's own `.DepotDownloader/` bookkeeping dir is the only non-content output
# and is stripped before publishing.
#
# CREDENTIALS. `anonymous = true` uses the anonymous account (free/anonymous depots — dedicated-server content,
# the Steamworks example app 480). Owned games need a Steam account: `propnix cred add steam` performs the
# one-time Steam Guard 2FA login (via DepotDownloader) and stores its reusable credential as
# `<credentialDir>/steam/<username>/depotdownloader-store.tar` — a tar of DepotDownloader's isolated-storage
# `account.config` (the JWT refresh token), path-preserving. This fetcher stages that verbatim under $HOME and
# runs `-username <u> -remember-password` non-interactively, trying each stored account until one OWNS the
# depot. The packaged DepotDownloader is pinned identically to the CLI's, so the isolated-storage path matches.
{
  lib,
  runCommand,
  depotdownloader,
  gnutar,
  coreutils,
}:
{
  pname ? "steam-depot",
  appId, # Steam AppID (e.g. 480 = Spacewar)
  depotId, # the DepotID within the app (a Linux content depot, per SteamDB)
  manifestId, # the version PIN — a content-addressed manifest snapshot (retained by Steam forever)
  outputHash, # recursive sha256 (SRI) of the assembled depot tree (bookkeeping stripped)
  outputHashAlgo ? "sha256",
  anonymous ? false, # true → anonymous account (free depots); false → a stored `propnix cred add steam` account
  title ? "this Steam title",
}:
runCommand (lib.strings.sanitizeDerivationName "${pname}")
  {
    inherit outputHash outputHashAlgo;
    outputHashMode = "recursive";

    nativeBuildInputs = [
      depotdownloader
      gnutar
      coreutils
    ];

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    allowSubstitutes = false; # proprietary content — never offer it to a substituter
    preferLocalBuild = true;

    inherit
      appId
      depotId
      manifestId
      title
      ;
    dlArgs = "-app ${toString appId} -depot ${toString depotId} -manifest ${toString manifestId}";
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    # DepotDownloader keeps its account.config in .NET Isolated Storage rooted at $XDG_DATA_HOME/IsolatedStorage
    # — so the credential tar (below) must be replayed under THIS dir, and it must be set even anonymously to
    # keep the tool's state contained + deterministic.
    export XDG_DATA_HOME="$TMPDIR/xdg"
    install -d -m700 "$TMPDIR/dl"

    fetched=0
    ${
      if anonymous then
        ''
          # Anonymous account — free/anonymous depots only.
          install -d -m700 "$HOME" "$XDG_DATA_HOME"
          if DepotDownloader $dlArgs -dir "$TMPDIR/dl" \
            && [ -n "$(find "$TMPDIR/dl" -mindepth 1 -type f -not -path '*/.DepotDownloader/*' -print -quit)" ]; then
            fetched=1
          fi
        ''
      else
        ''
          # Shared credential prologue (credentials.toml check, creddir extraction, account glob): cred-lib.sh.
          source ${./cred-lib.sh}
          propnix_require_credentials steam \
            "  A Steam account is required for $title."
          creddir=$(propnix_creddir)

          # Try each stored Steam account until one owns the depot. The account username is the dir name; its
          # credential tar recreates DepotDownloader's account.config (JWT refresh token) verbatim under $HOME.
          propnix_account_files steam "$creddir"/steam/*/depotdownloader-store.tar

          for _tar in "''${PROPNIX_ACCOUNT_FILES[@]}"; do
            _user=$(basename "$(dirname "$_tar")")
            rm -rf "$HOME" "$XDG_DATA_HOME"; install -d -m700 "$HOME" "$XDG_DATA_HOME"
            # Replay the stored account.config into DepotDownloader's isolated-storage path (path-preserving tar,
            # relative to $XDG_DATA_HOME — where .NET Isolated Storage looks).
            tar -C "$XDG_DATA_HOME" -xf "$_tar"
            rm -rf "$TMPDIR/dl"; install -d -m700 "$TMPDIR/dl"
            # -remember-password makes DepotDownloader USE the stored refresh token (no interactive prompt).
            if DepotDownloader $dlArgs -username "$_user" -remember-password -dir "$TMPDIR/dl" \
              && [ -n "$(find "$TMPDIR/dl" -mindepth 1 -type f -not -path '*/.DepotDownloader/*' -print -quit)" ]; then
              fetched=1
              break
            fi
            echo "propnix: Steam account '$_user' could not fetch app $appId depot $depotId; trying the next" >&2
          done
        ''
    }
    if [ "$fetched" -ne 1 ]; then
      echo "propnix: could not fetch $title (app $appId depot $depotId manifest $manifestId)" >&2
      echo "  (no account owns it, credentials are expired — re-run 'propnix cred add steam' — or the pin is stale)." >&2
      exit 1
    fi

    # Publish content only — drop DepotDownloader's bookkeeping (manifest cache, depot.config, staging), which
    # is tool state, not depot content, and could perturb the recursive hash.
    rm -rf "$TMPDIR/dl/.DepotDownloader"
    # RENAME the download dir straight to $out (no copy). Depots run tens of GB (Stellaris data ≈ 29.5 GB
    # uncompressed) so a `cp` would double the disk + wall-clock; $TMPDIR and $out share the build's fs, so this
    # is an O(1) rename. Content is byte-identical to a copy, so the pinned outputHash is unaffected.
    mv "$TMPDIR/dl" "$out"
  ''

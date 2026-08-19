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
  # PROVENANCE ONLY — deliberately not referenced in the build. Steam publishes no human version strings,
  # so a depot pin is identified purely by `manifestId`; this records the branch BUILD ID the pin was
  # taken at (or a marketing string a human wrote over it), which is what makes the PR table, the commit
  # message and the update issue say something meaningful. It lives in versions.json rather than here
  # because referencing it would churn every existing derivation for a label the download ignores.
  version ? null,
  # Which Steam branch the manifest belongs to. Absent/"public" is the default; a named branch is passed
  # to DepotDownloader as `-beta`, and ONLY then — every existing public pin's `dlArgs` must stay
  # byte-identical. Passworded/hidden branches are out of scope (DepotDownloader's `-betapassword` is
  # the hook if that is ever wanted); `propnix pin` refuses a branch Steam's appinfo does not list.
  branch ? "public",
  # DepotDownloader's `-max-downloads` = concurrent chunk requests. Its default of 8 is the single
  # biggest throughput limit on a depot fetch: Steam's CDN rate-limits PER CONNECTION, so aggregate
  # bandwidth is essentially (per-connection cap x connections). Measured against a real depot from this
  # host — 96 chunks, same set each run:
  #     1 conn  9.2 Mbit/s | 4 conns 32.8 | 8 conns 49.6 | 16 conns 90.9 | 32 conns 114.4
  #     and spread over the ~24 content servers Steam offers: 16 conns 105.3, 32 conns 168.6
  # So the stock 8 caps a fetch near 50 Mbit/s regardless of the link. 32 is ~2.3x that and still well
  # inside what Steam serves without throttling. A build-time constant only — chunk count and content
  # are manifest-fixed, so this never affects the content-addressed output.
  maxDownloads ? 32,
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
    dlArgs =
      "-app ${toString appId} -depot ${toString depotId} -manifest ${toString manifestId} -max-downloads ${toString maxDownloads}"
      + lib.optionalString (branch != "public") " -beta ${branch}";
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    # DepotDownloader keeps its account.config in .NET Isolated Storage rooted at $XDG_DATA_HOME/IsolatedStorage
    # — so the credential tar (below) must be replayed under THIS dir, and it must be set even anonymously to
    # keep the tool's state contained + deterministic.
    export XDG_DATA_HOME="$TMPDIR/xdg"

    # DOWNLOAD STRAIGHT INTO $out — never stage the depot in $TMPDIR. A depot can be hundreds of GB, and
    # staging then moving would require TWICE that free: inside the sandbox /build and /nix/store are
    # SEPARATE BIND MOUNTS (of /nix/var/nix/builds/… and <drv>.chroot/root/nix/store), and Linux refuses
    # rename(2)/link(2) across mount points even when both sit on one filesystem (man 2 rename, EXDEV) —
    # so `mv "$TMPDIR/dl" "$out"` silently degrades to copy+unlink. Measured in a real builder: 2 GiB took
    # 322 ms to `mv` from $TMPDIR to $out versus 2 ms to rename WITHIN /build. Writing into $out from the
    # start keeps peak disk at 1x the depot. (Nix's own publish step is a true rename — verified by polling
    # the final store path, which appears instantly at full size — so 1x holds end to end. The output mode
    # is irrelevant either way: Nix canonicalizes every store path to dr-xr-xr-x root:root.)
    #
    # Everything DepotDownloader does stays inside $out, so its staging→final moves are same-mount renames.
    reset_out() { rm -rf "$out"; install -d -m755 "$out"; }
    # A depot counts as fetched only if real CONTENT landed: an account that does not own the depot still
    # exits 0 having written nothing but the bookkeeping dir, so an exit-code check alone would pass.
    have_content() {
      [ -n "$(find "$out" -mindepth 1 -type f -not -path '*/.DepotDownloader/*' -print -quit)" ]
    }

    fetched=0
    ${
      if anonymous then
        ''
          # Anonymous account — free/anonymous depots only.
          install -d -m700 "$HOME" "$XDG_DATA_HOME"
          reset_out
          if DepotDownloader $dlArgs -dir "$out" && have_content; then
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
            reset_out
            # -remember-password makes DepotDownloader USE the stored refresh token (no interactive prompt).
            if DepotDownloader $dlArgs -username "$_user" -remember-password -dir "$out" && have_content; then
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
    # is tool state, not depot content, and would perturb the recursive hash. $out is already the download
    # dir, so there is nothing left to move.
    rm -rf "$out/.DepotDownloader"
  ''

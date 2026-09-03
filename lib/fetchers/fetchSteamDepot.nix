# fetchSteamDepot — a GOG-free content fetcher for Steam's SteamPipe system, the reproducibility-first
# sibling of the GOG fetchers. Unlike GOG's Linux offline installers (which expose ONLY the current version
# — a moving target that breaks an FOD on every store update), Steam pins content by
# (appId, depotId, manifestId): a manifest is a content-addressed, versioned snapshot, and Steam RETAINS
# every manifest ever shipped. So a pinned manifestId is downloadable forever → an FOD hash stays valid
# permanently.
#
# THE DOWNLOADER IS `propnix download steam` (pkgs/propnix-cli, src/pin/). It is the same pipeline that
# `propnix pin` uses to COMPUTE these hashes, with files as the sink instead of a NAR hasher: the same
# manifest decoder, chunk containers, credential handling, host scoring and concurrency governor. That is
# what makes it safe to hash with one tool and fetch with another — they are one tool.
#
# Determinism is structural: the depot AES key is identical for all users (so CDNs and LAN caches work),
# the manifest fixes the file set, its flags fix the exec bits, and Nix's NAR hashing normalizes mtimes and
# sorts entries. So a fixed manifestId yields a stable `outputHash`. VERIFIED against the pins this repo
# already carries — the tree written here hashes to the recorded value, cross-checked with `nix hash path`.
# Nothing about the BUILD RECIPE enters an FOD's output path (that is `hash(name, outputHash)` alone), so
# changing the downloader does not invalidate or re-fetch a single already-realised payload.
#
# CREDENTIALS. `anonymous = true` uses Steam's anonymous account (free/anonymous depots — dedicated-server
# content, the Steamworks example app 480). Owned games need an account: `propnix cred add steam` performs
# the one-time Steam Guard 2FA login and stores a reusable refresh token under
# `<credentialDir>/steam/<username>/`. The downloader reads that store directly (pointed at the in-sandbox
# root by PROPNIX_CRED_DIR) and tries each stored account until one OWNS the depot — ownership is settled
# by the depot-key request before a single content byte moves, so a wrong account costs a round trip.
{
  lib,
  runCommand,
  propnix-cli,
  coreutils,
}:
{
  pname ? "steam-depot",
  appId, # Steam AppID (e.g. 480 = Spacewar)
  depotId, # the DepotID within the app (a content depot, per SteamDB)
  manifestId, # the version PIN — a content-addressed manifest snapshot (retained by Steam forever)
  outputHash, # recursive sha256 (SRI) of the assembled depot tree
  outputHashAlgo ? "sha256",
  anonymous ? false, # true → anonymous account (free depots); false → a stored `propnix cred add steam` account
  title ? "this Steam title",
  # PROVENANCE ONLY — deliberately not referenced in the build. Steam publishes no human version strings,
  # so a depot pin is identified purely by `manifestId`; this records the branch BUILD ID the pin was taken
  # at (or a marketing string a human wrote over it), which is what makes the PR table, the commit message
  # and the update issue say something meaningful. It lives in versions.json rather than here because
  # referencing it would churn every existing derivation for a label the download ignores.
  version ? null,
  # Which Steam branch the manifest belongs to. Absent/"public" is the default; a named branch is passed
  # through as `--branch`. Passworded/hidden branches are out of scope; `propnix pin` refuses a branch
  # Steam's appinfo does not list.
  branch ? "public",
  # For a depot that ships a DLC: the DLC's own STORE appid, when it differs from `depotId`. Paradox-style
  # titles align the two (the steam-emu entitlement projection falls back to depotId), so most rows omit
  # it. Eval-only (passthru) — never referenced by the build.
  dlcAppId ? null,
  # CEILING on concurrent chunk requests, not a setting to tune: the downloader starts at a handful and
  # hill-climbs on measured throughput, holding each rung steady and comparing medians, so it finds the
  # knee for THIS link rather than trusting a number chosen here. Steam's CDN rate-limits per connection,
  # so the ceiling only needs to be comfortably above any plausible knee. A build-time constant that
  # cannot affect the content-addressed output.
  workers ? 128,
  # Cache trust anchors, from the pin's row (`propnix pin` records them; older rows lack them and that
  # is fine — the download simply keeps its login). With BOTH present and `<credential store>/cache`
  # warm, the fetch makes NO Steam login: the depot key and manifest come from the cache (verified
  # against these hashes — the cache is writable by every sandboxed build, so nothing in it is believed
  # otherwise; see pin/steamcache.rs), and chunk downloads are anonymous HTTP. Steam rate-limits logons
  # hard enough that per-FOD logins broke real bulk runs, which is the whole reason this exists.
  depotKeySha256 ? null,
  manifestSha256 ? null,
}:
runCommand (lib.strings.sanitizeDerivationName "${pname}")
  {
    inherit outputHash outputHashAlgo;

    meta = {
      license = lib.licenses.unfree;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };

    outputHashMode = "recursive";

    nativeBuildInputs = [
      propnix-cli
      coreutils
    ];

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    allowSubstitutes = true;
    preferLocalBuild = true;

    inherit
      appId
      depotId
      manifestId
      branch
      title
      workers
      ;
    # Eval-only identity for consumers (the steam-emu entitlement projection reads dlcAppId/depotId/title
    # off the derivation): passthru never enters the derivation env, so exposing these cannot churn an
    # existing FOD's drvPath — which is exactly why `version` is surfaced here rather than inherited above.
    passthru = { inherit version dlcAppId; };
  }
  ''
    set -euo pipefail
    # `propnix download` creates the output directory itself, and writes ONLY what the manifest describes —
    # no bookkeeping dir to strip afterwards, and no staging: chunks are written straight into $out at their
    # own offsets. That matters at this scale. A depot can be hundreds of GB, and staging then moving would
    # need TWICE that free: inside the sandbox /build and /nix/store are SEPARATE BIND MOUNTS, and Linux
    # refuses rename(2)/link(2) across mount points even when both sit on one filesystem (man 2 rename,
    # EXDEV), so a `mv` silently degrades to copy+unlink. Measured in a real builder: 2 GiB took 322 ms to
    # move $TMPDIR→$out versus 2 ms to rename WITHIN /build. Writing into $out from the start keeps peak
    # disk at 1x the depot. (Nix's own publish step is a true rename, so 1x holds end to end.)
    source ${./cred-lib.sh}
    # Resolve the credential root even on the anonymous path when the bind is present: the artifact
    # CACHE lives beside the credential dirs (<root>/cache — pin/steamcache.rs), and reading it needs
    # no credential, only the bind. Absent bind → the CLI's default root, whose cache simply misses.
    if [ -r /propnix/credentials.toml ]; then
      export PROPNIX_CRED_DIR="$(propnix_creddir)"
    fi
    ${
      # The anchor flags ride inline (NB: interpolated INLINE, never on a continued line — an empty
      # optionalString after a trailing backslash continues onto a blank line, ending the command).
      lib.optionalString (depotKeySha256 != null && manifestSha256 != null) ''
        anchors=(--depot-key-sha256 ${lib.escapeShellArg depotKeySha256} --manifest-sha256 ${lib.escapeShellArg manifestSha256})
      ''
    }
    ${
      if anonymous then
        ''
          # Anonymous account — free/anonymous depots only, so no credential store is consulted.
          propnix download steam \
            --app "$appId" --depot "$depotId" --manifest "$manifestId" \
            "''${anchors[@]}" --branch "$branch" --anonymous --workers "$workers" --dir "$out"
        ''
      else
        ''
          # Shared credential prologue: verifies /propnix/credentials.toml is readable inside the sandbox
          # and prints the actionable message when it is not (missing account, or a build that forgot
          # `--extra-sandbox-paths /propnix=/var/lib/propnix`). Required even though an anchored, warm
          # cache never logs in: a COLD cache falls back to the login path, which needs the store.
          propnix_require_credentials steam \
            "  A Steam account is required for $title."

          propnix download steam \
            --app "$appId" --depot "$depotId" --manifest "$manifestId" \
            "''${anchors[@]}" --branch "$branch" --workers "$workers" --dir "$out"
        ''
    }
  ''

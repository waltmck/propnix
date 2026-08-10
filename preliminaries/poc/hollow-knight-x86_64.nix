# propnix proof of concept #1 — Hollow Knight (GOG, x86_64 Linux build) under box64
# on aarch64. The suffix is the PAYLOAD's architecture, as in slack-arm64.nix.
#
# Axes exercised:
#   * GOG payload behind a credential  -> the credentialed FOD (PLAN2 §3.3)
#   * x86_64 Linux ELF on aarch64      -> box64, no rootfs, no patchelf (PLAN2 §2)
#   * proprietary, non-redistributable -> allowSubstitutes = false
#   * OPTIONAL, SEPARATELY-OWNED CONTENT -> one FOD per DLC, selected by name (§8)
#
# Build:  nix-build hollow-knight-x86_64.nix --option extra-sandbox-paths /propnix=/var/tmp/propnix
# Run:    ./result/bin/hollow-knight
#
# With the DLC this account owns:
#   nix-build hollow-knight-x86_64.nix --arg dlc '[ "gods-nightmares" ]' \
#     --option extra-sandbox-paths /propnix=/var/tmp/propnix
#
# See README.md for credential setup; without it the payload derivation fails with
# acquisition instructions rather than doing anything surprising.
#
# ----------------------------------------------------------------------------
# What "Gods & Nightmares" actually is
# ----------------------------------------------------------------------------
# GOG lists "Hollow Knight - Gods & Nightmares" (product 1450472929) as DLC, but the
# GOG API reports it with **no installers — only two extras**: the Godmaster
# soundtrack as MP3 (148 MB) and as FLAC (281 MB). The Godmaster *gameplay* content
# is free and already inside the base 1.5.12620 build, so owning this DLC adds no
# code and no assets the game loads. Selecting it therefore installs the
# soundtrack as data:
#
#     $out/share/hollow-knight/soundtrack/gods-nightmares/*.flac
#
# and leaves the game tree untouched. That is not a workaround — it is what the
# entitlement contains. The point of packaging it here is the *mechanism*: a
# credentialed FOD per DLC, a named catalogue, and a selection API that changes
# which FODs are built. stellaris-x86_64.nix drives the same mechanism with DLC
# that really is game content.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },

  # PLAN2 §9: a second *native* instance — substitutable, not cross-compiled.
  # PLAN2 §9: we only ever *depend* on these; every derivation below is aarch64.
  pkgsX86 ? import nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; },

  # Which DLC to include, by catalogue key (see `availableDLC` below). Empty by
  # default: an unselected DLC must not be a dependency at all, so a plain
  # `nix-build` of this file never fetches 281 MB of soundtrack. With `dlc = [ ]`
  # this file evaluates to exactly the derivation it did before DLC support
  # existed, so the verified record in ../docs/verified/hollow-knight.json still
  # describes the default build.
  dlc ? [ ],

  # "flac" (lossless, 281 MB) or "mp3" (148 MB). Only reachable via the
  # gods-nightmares entry; interchangeable, so it is a knob rather than two keys.
  ostFormat ? "flac",
}@args:

let
  inherit (pkgs) lib;

  # ----------------------------------------------------------------------
  # 0. The credentialed FOD (PLAN2 §3.3), factored out because there are now
  #    several payloads. The hash pins the exact file; if the store path already
  #    exists this never runs (ladder rung 0). `size` is the OBSERVED byte count,
  #    checked before the hash — GOG's API reports sizes rounded to whole MiB
  #    (RESEARCH §7: 1,214,251,008 claimed vs 1,214,513,063 actual), so the
  #    check exists to turn a 302-to-login into a legible error rather than a
  #    hash mismatch, not to second-guess the API.
  # ----------------------------------------------------------------------
  fetchGog =
    {
      name, # store name == the file's name; hash + name pin the path
      fileId, # lgogdownloader "gamename/fileid" or "gamename/dlcname/fileid"
      hash,
      size,
      title, # rung-4 text must be specific to be useful (PLAN2 §3.3)
      buyUrl,
    }:
    pkgs.runCommand name
      {
        outputHashAlgo = "sha256";
        outputHashMode = "flat";
        outputHash = hash;

        # cacert is a REAL input, not merely interpolated below (RESEARCH §13):
        # a store path that appears only inside a string still enters the
        # closure, but naming it here is what keeps that non-accidental.
        nativeBuildInputs = [ pkgs.lgogdownloader pkgs.cacert ];

        # The sandbox has no CA bundle, so TLS fails with
        # "Use --cacert to set the path for CA certificate bundle".
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

        # Proprietary, non-redistributable: never offer it to a substituter.
        allowSubstitutes = false;
        preferLocalBuild = true;
      }
      ''
        if [ ! -r /propnix/credentials.toml ]; then
          echo "propnix: no credentials at /propnix/credentials.toml" >&2
          echo "" >&2
          echo "Add the credential dir to the build sandbox, e.g.:" >&2
          echo "  nix build --extra-sandbox-paths /propnix=/var/tmp/propnix ..." >&2
          echo "or persistently:" >&2
          echo "  nix.settings.extra-sandbox-paths = [ \"/propnix=/var/tmp/propnix\" ];" >&2
          echo "" >&2
          echo "This payload is ${title}." >&2
          echo "Own it at ${buyUrl}" >&2
          exit 1
        fi

        # The mount is read-only and lgogdownloader rewrites its token on refresh,
        # so work from a writable copy and discard it (PLAN2 §3.3).
        creddir=$(grep -oP 'credentialDir\s*=\s*"\K[^"]+' /propnix/credentials.toml)
        export XDG_CONFIG_HOME="$TMPDIR/cfg"
        export XDG_CACHE_HOME="$TMPDIR/cache"
        install -d -m700 "$XDG_CONFIG_HOME/lgogdownloader" "$XDG_CACHE_HOME"
        install -m600 "$creddir"/* "$XDG_CONFIG_HOME/lgogdownloader/"

        # config.cfg's `directory = .` overrides --directory, so cd instead of fighting it.
        mkdir -p "$TMPDIR/dl" && cd "$TMPDIR/dl"

        lgogdownloader \
          --download-file ${lib.escapeShellArg fileId} \
          --no-remote-xml \
          -o payload.bin

        got=$(stat -c%s payload.bin)
        if [ "$got" != "${toString size}" ]; then
          echo "propnix: ${name} is $got bytes, expected ${toString size}" >&2
          echo "A short file is usually GOG's 302 to the login page — the token" >&2
          echo "in the credential dir has probably expired. Re-run:" >&2
          echo "  lgogdownloader --login" >&2
          echo "and re-copy the credential dir (see poc/README.md)." >&2
          exit 1
        fi

        mv payload.bin "$out"
      '';

  # ----------------------------------------------------------------------
  # 1. Payloads. The base game, plus one entry per owned DLC file.
  # ----------------------------------------------------------------------
  basePayload = fetchGog {
    name = "setup_hollow_knight_1.5.12620.sh";
    fileId = "hollow_knight/en3installer0";
    hash = "sha256-eds/XjOST54jSLwVdi3zbZN2wBVOA2mkaLiVfC3cTc0=";
    size = 1214513063;
    title = "Hollow Knight (Linux installer, 1.5.12620)";
    buyUrl = "https://www.gog.com/game/hollow_knight";
  };

  # ----------------------------------------------------------------------
  # 2. DLC catalogue. Data, not code: `passthru.availableDLC` exposes it so a
  #    user can ask what exists without reading this file.
  #
  #      nix-instantiate --eval --strict -A availableDLC hollow-knight-x86_64.nix
  #
  #    An entry names its GOG files and nothing else; `mkDlc` below turns the
  #    chosen one into a derivation whose $out holds only paths under `share/`.
  #    That output is symlinkJoin'd beside `bin/`, so a DLC can only ADD paths —
  #    it can never reach into the read-only game tree (PLAN2 §4).
  # ----------------------------------------------------------------------
  availableDLC = {
    gods-nightmares = {
      title = "Hollow Knight - Gods & Nightmares";
      buyUrl = "https://www.gog.com/game/hollow_knight_gods_nightmares";
      # Soundtrack only — the Godmaster gameplay content ships free in the base
      # build. See the file header.
      kind = "soundtrack";
      files = {
        flac = {
          name = "hollow_knight_gods_nightmares_flac.zip";
          fileId = "hollow_knight/hollow_knight_gods_nightmares/102578";
          hash = "sha256-ejTUjTzyHiYDbQv++0+tkCtcy+GlYp1bVBOjreaxpr0=";
          size = 281303322;
          # The zip has exactly one top-level directory, named after itself.
          innerDir = "hollow_knight_gods_nightmares_flac";
        };
        mp3 = {
          name = "hollow_knight_gods_nightmares_mp3.zip";
          fileId = "hollow_knight/hollow_knight_gods_nightmares/102575";
          hash = "sha256-Nymxa2aMY2SoGMTJI/xV/ScdhXcns3hunmdeORPG600=";
          size = 147642763;
          innerDir = "hollow_knight_gods_nightmares_mp3";
        };
      };
      # Which of `files` this build actually fetches. Selecting the DLC must pull
      # in ONE payload, not both, so the format knob is resolved here.
      chosenFile = ostFormat;
    };
  };

  dlcNames = lib.attrNames availableDLC;

  unknown = lib.subtractLists dlcNames dlc;

  # Sorted and deduplicated, so the selection is a SET rather than a sequence and
  # two orderings of the same DLC cannot produce two store paths with identical
  # contents. Moot at one catalogue entry; it is the shape that matters, and
  # stellaris-x86_64.nix has eleven.
  checkedDlc = lib.throwIf (unknown != [ ]) ''
    hollow-knight: no such DLC: ${lib.concatStringsSep ", " unknown}
    Available: ${lib.concatStringsSep ", " dlcNames}
  '' (lib.unique (lib.sort (a: b: a < b) dlc));

  # One derivation per selected DLC: fetch its payload, unpack it under share/.
  mkDlc =
    key:
    let
      entry = availableDLC.${key};
      file =
        entry.files.${entry.chosenFile} or (throw
          "hollow-knight: ${key} has no '${entry.chosenFile}' variant (have: ${
            lib.concatStringsSep ", " (lib.attrNames entry.files)
          })"
        );
      payload = fetchGog {
        inherit (file)
          name
          fileId
          hash
          size
          ;
        inherit (entry) title buyUrl;
      };
    in
    pkgs.runCommand "hollow-knight-dlc-${key}-${entry.chosenFile}"
      {
        nativeBuildInputs = [ pkgs.unzip ];
        allowSubstitutes = false;
        preferLocalBuild = true;
      }
      ''
        mkdir -p "$out/share/hollow-knight/soundtrack"
        unzip -q ${payload} -d unpacked
        mv ${lib.escapeShellArg "unpacked/${file.innerDir}"} \
           "$out/share/hollow-knight/soundtrack/${key}"
      '';

  dlcOutputs = map mkDlc checkedDlc;

  # ----------------------------------------------------------------------
  # 3. Unpack. bsdtar reads the MojoSetup payload directly (RESEARCH §8);
  #    the game lives under data/noarch/game, and there is no data/x86_64.
  #    (bsdtar is enough here only because this payload is under 4 GiB — see
  #    stellaris-x86_64.nix §2 for what happens when it is not.)
  # ----------------------------------------------------------------------
  # No `preferLocalBuild` here, unlike the DLC derivations below: it is only a
  # scheduling hint (there is no remote builder to prefer away from), but it is
  # part of the derivation, so adding it would change this path and therefore the
  # package's — retiring the store paths recorded in ../docs/verified/.
  unpacked = pkgs.runCommand "hollow-knight-unpacked-1.5.12620"
    {
      nativeBuildInputs = [ pkgs.libarchive ];
      allowSubstitutes = false;
    }
    ''
      mkdir -p unpack && cd unpack
      bsdtar -xf ${basePayload} 'data/noarch/game'
      mkdir -p $out
      cp -a 'data/noarch/game/.' $out/
      test -e "$out/Hollow Knight" || { echo "main binary missing" >&2; exit 1; }
    '';

  # ----------------------------------------------------------------------
  # 4. Library triage (PLAN2 §7). box64 dlopens the NATIVE aarch64 library
  #    to bridge it, so wrapped sonames must be present as aarch64. Anything
  #    box64 does not wrap must be present as x86_64.
  # ----------------------------------------------------------------------
  # Union of two sets, because neither alone is sufficient:
  #  * the bridging set — sonames box64 wraps, so the NATIVE aarch64 copy must be
  #    present for it to dlopen (RESEARCH §4). Includes libudev0-shim (libudev.so.0)
  #    and pipewire.
  #  * the guest set — the payload's verified DT_NEEDED closure plus what Unity
  #    dlopens, which must be present as x86_64.
  # The author's hand-written wrapper listed only the first and worked because it
  # APPENDED to an inherited LD_LIBRARY_PATH; sealing the environment (D13; PLAN2 §7)
  # removes that crutch and forces the full list to be explicit.
  bridgingSet = p: with p; [
    libgcc libx11 libxext libxcursor libxinerama libxrandr
    libxscrnsaver libxi libxxf86vm libGL libglvnd vulkan-loader
    libxkbcommon wayland SDL2
    systemd libudev0-shim pipewire libpulseaudio alsa-lib
  ];
  guestOnlySet = p: with p; [
    glibc stdenv.cc.cc.lib zlib cairo pango glib dbus.lib
  ];

  # ----------------------------------------------------------------------
  # 5. Wrapper. Sealed per D13 (PLAN2 §7): scrub the whole BOX64_* namespace, then
  #    set only what we mean, and suppress every rcfile so a user's
  #    ~/.box64rc cannot change behaviour.
  # ----------------------------------------------------------------------
  launcher = pkgs.writeShellApplication {
    name = "hollow-knight";
    runtimeInputs = [ pkgs.box64 pkgs.coreutils pkgs.util-linux ]; # util-linux: flock
    text = ''
      # --- D13 seal: drop every BOX64_* the environment may carry ---
      # Also LD_*: the host may set LD_PRELOAD to a NATIVE aarch64 allocator
      # (nixpkgs' malloc-provider does this), which box64 then tries to inject
      # into the x86 guest — observed as "cannot pre-load .../libmimalloc.so".
      # LD_LIBRARY_PATH is set deliberately below, so it is scrubbed then reset.
      while IFS='=' read -r k _; do
        case "$k" in BOX64_*|LD_*) unset "$k" ;; esac
      done < <(env)

      export BOX64_NORCFILES=1        # no rcfile exists here; keeps the run sealed
      export BOX64_PREFER_WRAPPED=1   # the author's known-working setting

      # The author's working wrapper used ONE combined path with both
      # architectures, not a split LD_LIBRARY_PATH / BOX64_LD_LIBRARY_PATH.
      # box64 folds LD_LIBRARY_PATH into its guest search collection too.
      export LD_LIBRARY_PATH=${
        lib.makeLibraryPath (
          bridgingSet pkgs                                  # native, for box64 to bridge
          ++ bridgingSet pkgsX86 ++ guestOnlySet pkgsX86     # x86_64, for the guest itself
        )
      }

      # Run straight from the store. Unity wants to create unity.lock in the game
      # dir and logs a warning when it cannot, but continues — the only thing lost is
      # single-instance protection. Saves go to ~/.config/unity3d, not here. A writable
      # game dir is a per-package escalation, not a default (unlike a wine prefix,
      # where a read-only tree silently discards registry writes).
      # The author's verified working invocation. Without -force-opengl Unity picks a
      # renderer that dies during scene load (black screen with audio playing);
      # SDL_VIDEODRIVER=x11 keeps SDL off the Wayland backend.
      export SDL_VIDEODRIVER=x11

      # Single-instance guard. Unity runs in SingleInstance mode and wants to create
      # unity.lock *in the game directory*, which is a read-only store path, so it
      # logs "Read-only file system" and carries on unprotected. Replicate it here.
      #
      # flock beats a PID file: the lock lives on the open file description and the
      # kernel drops it when the process dies, so a crash cannot leave a stale lock.
      # The fd is not CLOEXEC, so it survives the exec below and is held for the whole
      # life of the game rather than just the wrapper's startup.
      lockdir="''${XDG_RUNTIME_DIR:-/tmp}/propnix"
      mkdir -p "$lockdir"
      exec 9>"$lockdir/hollow-knight.lock"
      if ! flock -n 9; then
        echo "hollow-knight: already running (lock held on $lockdir/hollow-knight.lock)" >&2
        exit 1
      fi

      cd ${unpacked}
      exec box64 "./Hollow Knight" -force-opengl "$@"
    '';
  };

  # ----------------------------------------------------------------------
  # 6. Assembly + the selection API.
  #
  #    With no DLC the package IS the wrapper, unchanged. With DLC it is a
  #    symlinkJoin of the wrapper and one output per DLC, so a DLC can only add
  #    files next to bin/, never modify the game tree.
  #
  #    `withDLC` accepts either shape — the nixpkgs `p: [ p.x ]` selector, which
  #    makes a typo an evaluation error and tab-completes in `nix repl`, or a
  #    plain list of names, which is what `--arg dlc` has to be anyway:
  #
  #      (import ./hollow-knight-x86_64.nix { }).withDLC (d: [ d.gods-nightmares ])
  #      (import ./hollow-knight-x86_64.nix { }).withDLC [ "gods-nightmares" ]
  #      (import ./hollow-knight-x86_64.nix { }).withAllDLC
  #      (import ./hollow-knight-x86_64.nix { }).override { ostFormat = "mp3"; }
  #
  #    All of them go through `reinvoke`, which re-imports this file with the
  #    ORIGINAL argument set merged under the new one. `args` comes from the
  #    `}@args` capture, so it holds only what the caller actually passed —
  #    exactly `lib.makeOverridable`'s semantics — and a `pkgsX86` override
  #    therefore survives a later `.withDLC`. `overrideAttrs` cannot be used for
  #    any of this: `writeShellApplication` bakes the game path into `text`
  #    before mkDerivation sees it, so only a re-call can add or remove a
  #    payload FOD from the graph.
  # ----------------------------------------------------------------------
  reinvoke = a: import ./hollow-knight-x86_64.nix (args // a);

  package =
    if dlcOutputs == [ ] then
      launcher
    else
      pkgs.symlinkJoin {
        name = "hollow-knight+${lib.concatStringsSep "+" checkedDlc}";
        paths = [ launcher ] ++ dlcOutputs;
      };
in
package
// {
  # Data, so `nix repl` / `nix-instantiate --eval -A availableDLC` answers
  # "what DLC does this package know about?" without reading the source. Each
  # entry carries its own key so the selector form can round-trip to a name.
  availableDLC = lib.mapAttrs (k: v: v // { name = k; }) availableDLC;

  withDLC =
    sel:
    reinvoke {
      dlc =
        if lib.isFunction sel then
          map (d: d.name) (sel (lib.mapAttrs (k: v: v // { name = k; }) availableDLC))
        else
          sel;
    };

  withAllDLC = reinvoke { dlc = dlcNames; };
  withoutDLC = reinvoke { dlc = [ ]; };

  # D9: `.override` re-calls the same function with merged args, so it reaches
  # the payload too. Accepts an attrset or a function of the caller-supplied
  # args (which, as with lib.makeOverridable, excludes defaults).
  override = f: reinvoke (if lib.isFunction f then f args else f);

  # The un-wrapped game tree, and the launcher without the DLC join.
  unwrapped = unpacked;
  inherit launcher basePayload;
  selectedDLC = checkedDlc;
}

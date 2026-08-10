# propnix proof of concept — Stellaris (GOG, x86_64 Linux build) under box64 on
# aarch64, with optional DLC. The suffix is the PAYLOAD's architecture, as in
# hollow-knight-x86_64.nix.
#
# Axes exercised beyond PoC 1 (Hollow Knight):
#   * MULTI-PAYLOAD           -> up to 12 credentialed FODs, one per GOG file (PLAN2 §3.3)
#   * REAL DLC                -> DLC that is game content, merged into the tree
#   * a 16 GiB payload        -> ZIP64, which bsdtar cannot read (see §2 below)
#   * a non-Unity engine      -> Clausewitz, statically-linked SDL2, no Mono
#   * a vendor launcher       -> bypassed deliberately (see §5 below)
#
# Build:  nix-build stellaris-x86_64.nix --option extra-sandbox-paths /propnix=/var/tmp/propnix
# Run:    ./result/bin/stellaris
#
# With DLC — the default is vanilla, see the `dlc` argument for why:
#   nix-build stellaris-x86_64.nix --arg dlc '[ "nemesis" "megacorp" ]' \
#     --option extra-sandbox-paths /propnix=/var/tmp/propnix
#
# ----------------------------------------------------------------------------
# Disk cost, stated up front
# ----------------------------------------------------------------------------
# The Linux installer is 15.9 GiB and unpacks to 27.7 GiB, so a first build needs
# roughly 45 GiB of free store.
#
# A second DLC selection is a second 27.7 GiB tree *by NAR size* but costs far
# less than that on disk, because nix's own store optimiser hardlinks identical
# files across store paths. Measured with `auto-optimise-store = true`: the
# vanilla tree and the all-11-DLC tree report 28 GiB each standalone, share the
# 103 MB `stellaris` binary at one inode (nlink 6), and occupy 16.9 GiB together
# — the second selection's real cost is ~375 MB, which is the DLC content and
# nothing else. On a store without optimisation, run `nix-store --optimise` to
# collapse it. That dedup is the reason §3's per-selection tree is affordable.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },

  # PLAN2 §9: a second *native* instance — substitutable, not cross-compiled.
  # PLAN2 §9: we only ever *depend* on these; every derivation below is aarch64.
  pkgsX86 ? import nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; },

  # Which DLC to include, by catalogue key (see `availableDLC` below).
  #
  # **Empty by default, and that is deliberate even though eleven DLC are owned
  # here.** A default of "everything in the catalogue" would make the default
  # derivation depend on the *packager's* entitlements: `nix-build
  # stellaris-x86_64.nix` would fail at rung 4 for anyone who owns nine of the
  # eleven, and the store path a reader sees quoted would be one they cannot
  # produce. Vanilla is the configuration every owner of Stellaris can build, so
  # it is the one the default names. DLC is opt-in:
  #
  #   nix-build stellaris-x86_64.nix --arg dlc '[ "nemesis" "megacorp" ]' ...
  #   (import ./stellaris-x86_64.nix { }).withAllDLC
  dlc ? [ ],
}@args:

let
  inherit (pkgs) lib;

  version = "4.4.6";
  build = "92219"; # GOG build id, part of every payload's filename

  # ----------------------------------------------------------------------
  # 1. The credentialed FOD (PLAN2 §3.3). Identical in shape to the one in
  #    hollow-knight-x86_64.nix — PoCs are deliberately standalone (poc/README.md),
  #    so it is duplicated rather than shared. `size` is the OBSERVED byte count,
  #    checked before the hash: GOG's API reports sizes rounded to whole MiB
  #    (17,098,080,256 claimed here vs 17,098,086,405 actual), so this check
  #    exists to turn a 302-to-login into a legible error rather than a hash
  #    mismatch after a 16 GiB download.
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

  basePayload = fetchGog {
    name = "stellaris_4_4_6_${build}.sh";
    fileId = "stellaris/en3installer0";
    hash = "sha256-MMr0rFgGxRDPc+cqbyTJR9kRD66i4FRCq9EgxyX47tU=";
    size = 17098086405;
    title = "Stellaris (Linux installer, ${version})";
    buyUrl = "https://www.gog.com/game/stellaris";
  };

  # ----------------------------------------------------------------------
  # 2. Unpack. **unzip, not bsdtar** — this is the one place Stellaris departs
  #    from RESEARCH §8's recipe.
  #
  #    A GOG Linux installer is a MojoSetup shell script with a zip appended;
  #    RESEARCH §8 reads it with `bsdtar -xf`, which works for Hollow Knight's
  #    1.2 GB file. Stellaris's is 15.9 GB, so the archive is ZIP64, and
  #    libarchive rejects it outright:
  #
  #        bsdtar: Damaged Zip archive
  #
  #    It is ZIP64 that libarchive cannot handle here, not the prologue as such:
  #    Hollow Knight's prologue is *larger* (795,171 bytes against Stellaris's
  #    653,691, both measured) and bsdtar reads it without complaint. What
  #    libarchive cannot do is reconcile the ZIP64 end-of-central-directory
  #    locator with a non-zero archive start offset. Info-ZIP can — it reports
  #    the shift as a warning and processes the archive correctly:
  #
  #        error: End-of-centdir-64 signature not where expected (prepended bytes?)
  #          (attempting to process anyway)
  #        warning: 653691 extra bytes at beginning or within zipfile
  #
  #    Verified by extracting the LAST entries in the central directory (well
  #    past the 4 GiB mark) and checking their sizes against the listing. The
  #    warning makes unzip exit 1, so the builder tolerates 1 and nothing else.
  #
  #    Triage rule for future GOG payloads: **> 4 GiB means unzip, not bsdtar.**
  # ----------------------------------------------------------------------
  unzipInstaller = ''
    unzipGame() {   # $1 = payload, $2 = zip glob, $3 = destination dir
      local rc=0
      unzip -q "$1" "$2" -d "$3" || rc=$?
      # 1 is Info-ZIP's "warnings only" — here, the prepended MojoSetup script.
      # Anything else is a real failure.
      [ "$rc" -le 1 ] || { echo "unzip failed with status $rc" >&2; exit "$rc"; }
    }
  '';

  # ----------------------------------------------------------------------
  # 3. DLC catalogue and the merged game tree.
  #
  #    Every Stellaris DLC installer contains exactly one directory,
  #    data/noarch/game/dlc/dlcNNN_<name>/, holding a .dlc manifest, a .zip of
  #    the content and a thumbnail. The base game's own dlc/ holds only dlc.txt
  #    (a comment listing every DLC id that has ever existed), so merging is a
  #    union of directories with no file-level conflicts.
  #
  #    **The tree must be real files. A symlink farm does not work here**, and
  #    that is the single most expensive fact in this package. Stellaris serves
  #    its content through PhysFS (`__PHYSFS_Archiver_{DIR,ZIP,7Z}` and
  #    "Failed to mount %s with error %s" are in the binary), and PhysFS refuses
  #    to traverse a symlink unless PHYSFS_setSymbolicLinksPermitted(1) is called
  #    — Clausewitz never calls it. Measured, with the top-level directories
  #    symlinked into a shared unpacked base:
  #
  #        [virtualfilesystem_physfs.cpp:795] File 'gfx/loadingscreens/init.bmp'
  #            does not exist : symlinks are forbidden
  #        terminate called after throwing an instance of 'std::logic_error'
  #
  #    before any window appeared. Note that box64 is irrelevant to this — PhysFS
  #    lstat()s the path components itself.
  #
  #    So extraction and composition are FUSED into this one derivation rather
  #    than split into a shared `unpacked` plus a per-selection copy. Splitting
  #    would buy nothing: copying 27.7 GiB is no cheaper than extracting it, so
  #    the split costs the same wall clock and twice the store.
  #
  #    **Sharing between selections is nix's job, not this package's.** The
  #    store optimiser hardlinks identical files across paths, so two selections
  #    that differ only in dlc/ occupy one copy of the 27.7 GiB they have in
  #    common — measured at nlink 6 on the shared `stellaris` binary, 16.9 GiB
  #    for both trees together. That is strictly better than the symlink farm it
  #    replaces: it is invisible to the application, it needs no privileges and
  #    no runtime indirection, and each tree stays an independent, separately
  #    collectable store path instead of holding a reference to a shared base.
  #
  #    `availableDLC` is plain data, so a user can ask what exists without
  #    reading this file:
  #      nix-instantiate --eval --strict -A availableDLC stellaris-x86_64.nix
  # ----------------------------------------------------------------------
  mkDlcEntry =
    {
      key,
      title,
      gogName, # lgogdownloader dlc gamename
      fileName, # NOT always "stellaris_<gogName>_…" — ancient relics differs
      hash,
      size,
      dir, # the directory it drops into dlc/
    }:
    {
      inherit
        key
        title
        gogName
        dir
        ;
      buyUrl = "https://www.gog.com/game/${gogName}";
      payload = fetchGog {
        name = fileName;
        fileId = "stellaris/${gogName}/en3installer0";
        inherit hash size title;
        buyUrl = "https://www.gog.com/game/${gogName}";
      };
    };

  availableDLC = lib.listToAttrs (
    map (e: lib.nameValuePair e.key (mkDlcEntry e)) [
      {
        key = "plantoids";
        title = "Stellaris: Plantoids Species Pack";
        gogName = "stellaris_plantoids_species_pack";
        fileName = "stellaris_plantoids_species_pack_4_4_6_${build}.sh";
        hash = "sha256-MbC7FA0GkfpVuA7+ZH5OYgiEwYjvgcYN00NgAL7hquQ=";
        size = 1128537;
        dir = "dlc004_plantoid";
      }
      {
        key = "leviathans";
        title = "Stellaris: Leviathans Story Pack";
        gogName = "stellaris_leviathans_story_pack";
        fileName = "stellaris_leviathans_story_pack_4_4_6_${build}.sh";
        hash = "sha256-6zPQp0zppCHkBfqrxY6L9k0fuhudlQ+U1jKTkVS/FH4=";
        size = 60099796;
        dir = "dlc012_leviathans";
      }
      {
        key = "apocalypse";
        title = "Stellaris: Apocalypse";
        gogName = "stellaris_apocalypse";
        fileName = "stellaris_apocalypse_4_4_6_${build}.sh";
        hash = "sha256-o2jqisqOpEuB8tNR9sMzXjlnpIkyHHrDytC7EzN8ppA=";
        size = 39057675;
        dir = "dlc017_apocalypse";
      }
      {
        key = "distant-stars";
        title = "Stellaris: Distant Stars Story Pack";
        gogName = "stellaris_distant_stars_story_pack";
        fileName = "stellaris_distant_stars_story_pack_4_4_6_${build}.sh";
        hash = "sha256-itBH4yiKaWGsFt8u3Y7ZPt5C2byiEKqqYgC7URsKz8Y=";
        size = 21603590;
        dir = "dlc019_distant_stars";
      }
      {
        key = "megacorp";
        title = "Stellaris: MegaCorp";
        gogName = "stellaris_megacorp";
        fileName = "stellaris_megacorp_4_4_6_${build}.sh";
        hash = "sha256-s0dNX5Fi04RMPAzRYmFMQTgqMFjl3HCcE8nscHncVcI=";
        size = 92845613;
        dir = "dlc020_megacorp";
      }
      {
        key = "ancient-relics";
        title = "Stellaris: Ancient Relics Story Pack";
        gogName = "stellaris_ancient_relics_story_pack";
        # the only file whose name is not the gamename + version
        fileName = "stellaris_ancient_relics_4_4_6_${build}.sh";
        hash = "sha256-Yowct5o0MsiNvYBPb3eMK7ppDAr/KpKy15caaghiq7k=";
        size = 33796723;
        dir = "dlc021_ancient_relics";
      }
      {
        key = "lithoids";
        title = "Stellaris: Lithoids Species Pack";
        gogName = "stellaris_lithoids_species_pack";
        fileName = "stellaris_lithoids_species_pack_4_4_6_${build}.sh";
        hash = "sha256-M/jMBjF2pZJ+zGxeZejKTsfadqGOBpgtO2+m7EKp6LA=";
        size = 26498051;
        dir = "dlc022_lithoids";
      }
      {
        key = "federations";
        title = "Stellaris: Federations";
        gogName = "stellaris_federations";
        fileName = "stellaris_federations_4_4_6_${build}.sh";
        hash = "sha256-RADcSQu3jJlC3qq6Qig11wOfw1atRl6Nc9Z3LZRygF0=";
        size = 15049405;
        dir = "dlc023_federations";
      }
      {
        key = "necroids";
        title = "Stellaris: Necroids Species Pack";
        gogName = "stellaris_necroids_species_pack";
        fileName = "stellaris_necroids_species_pack_4_4_6_${build}.sh";
        hash = "sha256-E7RmuGRFbeS2eDypQNnr/zlHv0sODK/xoddFWXuiKYs=";
        size = 25750192;
        dir = "dlc024_necroids";
      }
      {
        key = "nemesis";
        title = "Stellaris: Nemesis";
        gogName = "stellaris_nemesis";
        fileName = "stellaris_nemesis_4_4_6_${build}.sh";
        hash = "sha256-6vG7S8kptSDw6lNckN9LfKcCeJso87crWw6YfLFhyIU=";
        size = 39735304;
        dir = "dlc025_nemesis";
      }
      {
        key = "astral-planes";
        title = "Stellaris: Astral Planes";
        gogName = "stellaris_astral_planes";
        fileName = "stellaris_astral_planes_4_4_6_${build}.sh";
        hash = "sha256-c0xRm7LJ3MPzCIor4imA+wAy74RZoRR6ls+22hqFcsU=";
        size = 48183617;
        dir = "dlc031_astral_planes";
      }
    ]
  );

  dlcNames = lib.attrNames availableDLC;
  # Sorted and deduplicated, so the selection is a SET rather than a sequence:
  # `[ "nemesis" "megacorp" ]` and `[ "megacorp" "nemesis" ]` describe the same
  # game and must therefore be the same store path. Without the sort the builder
  # script differs by merge order and nix hands back two paths with byte-identical
  # contents.
  requested = lib.unique (lib.sort (a: b: a < b) dlc);
  unknown = lib.subtractLists dlcNames requested;

  selected = lib.throwIf (unknown != [ ]) ''
    stellaris: no such DLC: ${lib.concatStringsSep ", " unknown}
    Available: ${lib.concatStringsSep ", " dlcNames}
  '' requested;

  # The DLC count, not the names: eleven keys would make a 200-character store
  # path. Two different subsets of the same size share a *label*, never a path —
  # the input hash still separates them.
  treeName =
    "stellaris-${version}"
    + lib.optionalString (selected != [ ]) "-with-${toString (lib.length selected)}-dlc";

  gameTree = pkgs.runCommand treeName
    {
      nativeBuildInputs = [ pkgs.unzip ];
      allowSubstitutes = false;
      preferLocalBuild = true;
    }
    ''
      ${unzipInstaller}

      # Extract straight into $out and lift the tree up one level with renames.
      # Unpacking to $TMPDIR first and moving would risk a 27.7 GiB *copy* rather
      # than a rename, because `mv` degrades to copy-and-unlink across
      # filesystems and nothing guarantees the build directory shares one with
      # the store.
      mkdir -p "$out"
      cd "$out"
      unzipGame ${basePayload} 'data/noarch/game/*' .
      shopt -s dotglob            # data/noarch/game/.gitignore
      mv data/noarch/game/* .
      shopt -u dotglob
      rm -rf data

      test -x "$out/stellaris" || { echo "main binary missing" >&2; exit 1; }
      test -e "$out/launcher-settings.json" || { echo "launcher-settings.json missing" >&2; exit 1; }

      # The base game's dlc/ holds only dlc.txt; owned DLC join it here.
      test -d "$out/dlc" || { echo "base dlc/ missing" >&2; exit 1; }
      cd "$NIX_BUILD_TOP"

      ${lib.concatMapStrings (key: let e = availableDLC.${key}; in ''
        echo "propnix: merging ${e.title} (${e.dir})"
        rm -rf tmp-${e.key} && mkdir tmp-${e.key}
        unzipGame ${e.payload} ${lib.escapeShellArg "data/noarch/game/dlc/${e.dir}/*"} tmp-${e.key}
        test -e ${lib.escapeShellArg "tmp-${e.key}/data/noarch/game/dlc/${e.dir}"} \
          || { echo "${e.key}: ${e.dir} not in payload" >&2; exit 1; }
        mv ${lib.escapeShellArg "tmp-${e.key}/data/noarch/game/dlc/${e.dir}"} "$out/dlc/"
        rm -rf tmp-${e.key}
      '') selected}

      # DT_RUNPATH on ./stellaris is `$ORIGIN`, so the two bundled libraries have
      # to sit beside it in this very tree.
      test -e "$out/libPDXSDK.so" || { echo "libPDXSDK.so missing" >&2; exit 1; }
      test -e "$out/libnakama-cpp.so" || { echo "libnakama-cpp.so missing" >&2; exit 1; }

      # Nothing in the tree may be a symlink: PhysFS refuses to traverse one, and
      # the failure mode is a crash before the first window rather than an error.
      if find "$out" -type l -print -quit | grep -q .; then
        echo "symlink in the game tree — PhysFS will refuse to traverse it" >&2
        find "$out" -type l | head >&2
        exit 1
      fi
    '';

  # ----------------------------------------------------------------------
  # 4. Library triage (PLAN2 §7). box64 dlopens the NATIVE aarch64 library to
  #    bridge it, so wrapped sonames must be present as aarch64; anything box64
  #    does not wrap must be present as x86_64. The set is the UNION, and only a
  #    sealed environment (D13) proves it — a wrapper that lists just the
  #    bridging set can appear to work by borrowing guest libraries from the
  #    ambient session.
  #
  #    Derived from the payload, not guessed. `stellaris` links
  #      libdl libX11 libpthread libnakama-cpp libPDXSDK libGL libstdc++ libm
  #      libgcc_s libc
  #    with DT_RUNPATH `$ORIGIN` for the two bundled ones, and carries a
  #    statically-linked SDL2 whose dlopen table adds
  #      libasound libdbus-1 libEGL libGLESv2 libpulse-simple libvulkan
  #      libwayland-{client,cursor,egl} libX11-xcb libXcursor libXext libXfixes
  #      libXi libxkbcommon libXrandr libXss
  #    Notably absent versus Hollow Knight: no Mono, no bundled SDL2 .so, and
  #    nothing needing libudev — but libdbus-1 and libXfixes are new.
  # ----------------------------------------------------------------------
  bridgingSet = p: with p; [
    libgcc libx11 libxext libxcursor libxrandr libxi libxfixes
    libxscrnsaver libGL libglvnd vulkan-loader
    libxkbcommon wayland
    dbus.lib libpulseaudio alsa-lib
    # libX11-xcb.so.1 ships in libx11, above; libxcb is what it links against and
    # is listed so the resolution does not depend on that library's own RUNPATH.
    libxcb
    # zlib is in BOTH sets. It is wrapped, so box64 wants the native copy —
    # measured: without it the run opens with
    #   BOX64: Error initializing native libz.so.1 (last dlerror is libz.so: ...)
    # — and libPDXSDK.so links libz.so.1 as a guest, so the x86_64 copy is needed
    # too. That is the union rule (PLAN2 §7) showing up in one soname.
    zlib
  ];
  guestOnlySet = p: with p; [
    glibc stdenv.cc.cc.lib zlib
  ];

  # ----------------------------------------------------------------------
  # 5. Wrapper. Sealed per D13 (PLAN2 §7): scrub the whole BOX64_* namespace, then set
  #    only what we mean, and suppress every rcfile so a user's ~/.box64rc cannot
  #    change behaviour.
  #
  #    **The Paradox Launcher is bypassed on purpose.** GOG's own start.sh does
  #    `cd game && ./dowser`, and dowser bootstraps `pdx_launcher`, an Electron
  #    app; launcher-settings.json records what the launcher would then exec:
  #
  #        "exePath": "./stellaris", "exeArgs": [ "-gdpr-compliant" ]
  #
  #    So the wrapper runs exactly that, and a whole Chromium stack never has to
  #    survive emulation. What is given up is the launcher's UI for mods,
  #    playsets and per-DLC toggles — none of which is needed to run the game
  #    with every owned DLC enabled, which is the default state.
  # ----------------------------------------------------------------------
  launcher = pkgs.writeShellApplication {
    name = "stellaris";
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
      export BOX64_PREFER_WRAPPED=1   # PLAN2 §7: required, and all-or-nothing

      # One combined path with both architectures: box64 folds LD_LIBRARY_PATH
      # into its guest search collection as well as using it natively.
      export LD_LIBRARY_PATH=${
        lib.makeLibraryPath (
          bridgingSet pkgs                                  # native, for box64 to bridge
          ++ bridgingSet pkgsX86 ++ guestOnlySet pkgsX86     # x86_64, for the guest itself
        )
      }

      # Video backend. **Wayland is preferred here, and that is measured, not
      # inherited** — Hollow Knight's `SDL_VIDEODRIVER=x11` is Unity-specific and
      # is not a general default (the same correction zoom-arm64.nix had to make
      # to slack-arm64.nix's).
      #
      # Stellaris links SDL2 statically, and its dlopen table is satisfied
      # natively either way: under wayland the process maps libwayland-{client,
      # cursor,egl} and libxkbcommon, all aarch64, and reaches the frontend with
      # the same OpenGL 4.6 Mesa device as under x11.
      #
      # The two paths are not equivalent, so this is a knob rather than a
      # hardcoded win. On this 2560x1664 panel at compositor scale 1.6:
      #   wayland -> SDL reports the LOGICAL size, 1600x1040, and the compositor
      #              upscales. 2.56x fewer pixels and no XWayland indirection —
      #              visibly smoother — at the cost of an upscaled image.
      #   x11     -> XWayland reports 2560x1664 and the game renders pixel-exact,
      #              but pays for every one of those pixels and gets a UI scaled
      #              for a non-HiDPI display.
      #
      # Detecting the session is a runtime decision about a VALUE, not about a
      # dependency, which is why it belongs here and not in the derivation
      # graph (PLAN2 §5). PROPNIX_* is the namespace for runtime knobs, and the
      # D13 scrub above deliberately does not touch it.
      if [ -n "''${PROPNIX_SDL_VIDEODRIVER:-}" ]; then
        export SDL_VIDEODRIVER="$PROPNIX_SDL_VIDEODRIVER"
      elif [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        export SDL_VIDEODRIVER=wayland
      else
        export SDL_VIDEODRIVER=x11
      fi

      # State lives outside the store (PLAN2 §7.2). Stellaris derives it from
      # launcher-settings.json's "$LINUX_DATA_HOME/Paradox Interactive/Stellaris",
      # i.e. XDG_DATA_HOME — saves, settings.txt, logs, mods and dlc_load.json.
      # Nothing is written into the game tree, so it stays read-only in the store.
      export XDG_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
      stateDir="$XDG_DATA_HOME/Paradox Interactive/Stellaris"
      mkdir -p "$stateDir"

      # Warn about enabled mods. Bypassing the launcher (§5) means nothing
      # reconciles dlc_load.json against the installed version any more, and a
      # playset left behind by an older install is loaded silently. Measured:
      # 21 mods from a Stellaris 3.x-era install produced 582 "Wrong scope"
      # errors — 4.x split the planet and colony scopes — and then SIGSEGV
      # during galaxy generation. The same tree with no mods runs fine.
      #
      # This only ever prints. dlc_load.json belongs to the launcher and to
      # every third-party mod manager; rewriting it would destroy a playset.
      # Parsed with bash string ops rather than jq to avoid a dependency for a
      # warning.
      dlcLoad="$stateDir/dlc_load.json"
      if [ -r "$dlcLoad" ]; then
        enabled=$(tr -d ' \n' < "$dlcLoad")
        enabled=''${enabled#*\"enabled_mods\":[}
        enabled=''${enabled%%]*}
        modCount=0
        while [ "$enabled" != "''${enabled#*.mod}" ]; do
          enabled=''${enabled#*.mod}
          modCount=$((modCount + 1))
        done
        if [ "$modCount" -gt 0 ]; then
          echo "stellaris: $modCount mod(s) enabled in $dlcLoad" >&2
          echo "  This wrapper bypasses the Paradox Launcher, so nothing checks them against ${version}." >&2
          echo "  Mods for an older release crash the game; set \"enabled_mods\":[] there to play unmodded." >&2
        fi
      fi

      # Single-instance guard, per PLAN2 §5.1: it belongs in the box64 wrapper.
      # The lock lives on the open file description, so the kernel drops it if we
      # crash; the fd is not CLOEXEC, so it survives the exec into box64.
      lockdir="''${XDG_RUNTIME_DIR:-/tmp}/propnix"
      mkdir -p "$lockdir"
      exec 9>"$lockdir/stellaris.lock"
      if ! flock -n 9; then
        echo "stellaris: already running (lock held on $lockdir/stellaris.lock)" >&2
        exit 1
      fi

      # Clausewitz resolves its game root from the working directory, which is
      # why GOG's start.sh cds first.
      cd ${gameTree}
      exec box64 ./stellaris -gdpr-compliant "$@"
    '';
  };

  # ----------------------------------------------------------------------
  # 6. Selection API, identical in shape to hollow-knight-x86_64.nix:
  #
  #      (import ./stellaris-x86_64.nix { }).withDLC (d: [ d.nemesis d.megacorp ])
  #      (import ./stellaris-x86_64.nix { }).withDLC [ "nemesis" ]
  #      (import ./stellaris-x86_64.nix { }).withAllDLC     # everything owned here
  #      (import ./stellaris-x86_64.nix { }).withoutDLC     # back to the default
  #      (import ./stellaris-x86_64.nix { }).override { pkgsX86 = myX86; }
  #
  #    `args` is the `}@args` capture — only what the caller actually passed, so
  #    a `pkgsX86` override survives a later `.withDLC`. `overrideAttrs` cannot
  #    do any of this: `writeShellApplication` bakes the game path into `text`
  #    before mkDerivation sees it, so only a re-call can add or remove a payload
  #    FOD from the graph.
  # ----------------------------------------------------------------------
  reinvoke = a: import ./stellaris-x86_64.nix (args // a);
in
launcher
// {
  inherit availableDLC;

  withDLC =
    sel: reinvoke { dlc = if lib.isFunction sel then map (d: d.key) (sel availableDLC) else sel; };

  withAllDLC = reinvoke { dlc = dlcNames; };
  withoutDLC = reinvoke { dlc = [ ]; };

  # D9: `.override` re-calls the same function with merged args, so it reaches
  # the payload too. Accepts an attrset or a function of the caller-supplied
  # args (which, as with lib.makeOverridable, excludes defaults).
  override = f: reinvoke (if lib.isFunction f then f args else f);

  unwrapped = gameTree;
  inherit basePayload;
  selectedDLC = selected;
}

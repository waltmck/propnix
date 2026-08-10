# propnix proof of concept — Hollow Knight (GOG, x86_64 Linux build) under
# fex-portable on aarch64 with a 16K host page. Sibling of hollow-knight-x86_64.nix
# (which uses box64); this one runs the whole guest x86_64 stack under FEX instead.
#
# Why a FEX variant at all: FEX honours the guest ELF interpreter and runs the guest's
# own x86_64 libraries under emulation (box64, by contrast, bridges native aarch64
# libraries). Getting here required the fex-portable fork — stock FEX 2605 cannot run
# on a 16K host, and even after that, dynamic linking needed the sub-host-page mmap
# emulation (see ../fex-portable/README.md, wall 9). This package is the first real app
# on that base.
#
# STATUS (2026-08-06): this reaches Unity + Mono init and then crashes — it is NOT yet
# playable. Measured under fex-portable on the 16K host:
#   * Unity starts, configures its allocators, reaches "Loading in SingleInstance mode".
#   * The bundled Mono runtime (libmonobdwgc-2.0.so) now dlopens successfully — this needed
#     fex-portable wall 9 (sub-host-page mmap emulation); without it the load failed outright.
#   * Then a guest SIGSEGV. Leading suspect: the Mono JIT emits code at runtime and relies on
#     FEX's SMC (self-modifying-code) tracking to re-translate it, but SMC is non-functional on
#     a 16K host — it is disabled by default (wall 6) and its protect path
#     (SyscallsSMCTracking.cpp MarkGuestExecutableRange, mprotect(PROT_READ)) is 4K-granular and
#     unfixed for large pages. Making SMC correct on 16K is the hard mixed-permission problem
#     (protecting one 4K code page also protects three neighbouring data pages).
#
# Also unresolved even past that: no GL thunks, so the guest would load x86_64 Mesa (llvmpipe
# software rendering, no Apple-GPU driver). The box64 sibling runs this game today with hardware
# GL via native bridging; FEX is the research path. Next steps for FEX: (1) large-page SMC, then
# (2) FEX GL/X11 thunks to native aarch64 (RESEARCH §5).
#
# Build:  nix-build hollow-knight-x86_64-fex.nix --option extra-sandbox-paths /propnix=/var/tmp/propnix
# Run:    ./result/bin/hollow-knight-fex
#
# See README.md for GOG credential setup; without it the payload derivation fails with
# acquisition instructions rather than doing anything surprising.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },

  # A second *native* instance (substitutable, not cross-compiled): the guest's x86_64
  # interpreter and libraries. Every derivation below is still aarch64.
  pkgsX86 ? import nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; },
}:

let
  inherit (pkgs) lib;

  # The patched emulator: FEX-Emu 2605 with large-host-page + dynamic-linking support.
  fexPortable = import ../fex-portable { inherit nixpkgs pkgs; };

  # ----------------------------------------------------------------------
  # 1-2. Payload + unpack. Identical to the box64 sibling (same GOG file, same
  #      hash, same MojoSetup layout, RESEARCH §7-8); kept inline so this file is
  #      self-contained and the working box64 package is never disturbed.
  # ----------------------------------------------------------------------
  payload = pkgs.runCommand "setup_hollow_knight_1.5.12620.sh"
    {
      outputHashAlgo = "sha256";
      outputHashMode = "flat";
      outputHash = "sha256-eds/XjOST54jSLwVdi3zbZN2wBVOA2mkaLiVfC3cTc0=";
      nativeBuildInputs = [ pkgs.lgogdownloader pkgs.jq ];
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      allowSubstitutes = false;
      preferLocalBuild = true;
    }
    ''
      if [ ! -r /propnix/credentials.toml ]; then
        echo "propnix: no credentials at /propnix/credentials.toml" >&2
        echo "Add the credential dir to the build sandbox, e.g.:" >&2
        echo "  nix build --extra-sandbox-paths /propnix=/var/tmp/propnix ..." >&2
        exit 1
      fi
      creddir=$(grep -oP 'credentialDir\s*=\s*"\K[^"]+' /propnix/credentials.toml)
      export XDG_CONFIG_HOME="$TMPDIR/cfg"
      export XDG_CACHE_HOME="$TMPDIR/cache"
      install -d -m700 "$XDG_CONFIG_HOME/lgogdownloader" "$XDG_CACHE_HOME"
      install -m600 "$creddir"/* "$XDG_CONFIG_HOME/lgogdownloader/"
      mkdir -p "$TMPDIR/dl" && cd "$TMPDIR/dl"
      lgogdownloader \
        --download-file "hollow_knight/en3installer0" \
        --no-remote-xml \
        -o setup_hollow_knight_1.5.12620.sh
      mv setup_hollow_knight_1.5.12620.sh "$out"
    '';

  unpacked = pkgs.runCommand "hollow-knight-unpacked-1.5.12620"
    {
      nativeBuildInputs = [ pkgs.libarchive ];
      allowSubstitutes = false;
    }
    ''
      mkdir -p unpack && cd unpack
      bsdtar -xf ${payload} 'data/noarch/game'
      mkdir -p $out
      cp -a 'data/noarch/game/.' $out/
      test -e "$out/Hollow Knight" || { echo "main binary missing" >&2; exit 1; }
    '';

  # ----------------------------------------------------------------------
  # 3. Patch the guest ELF interpreter. The GOG binary expects
  #    /lib64/ld-linux-x86-64.so.2, which does not exist under FEX_ROOTFS=/. Point it
  #    at the x86_64 glibc loader's store path (RESEARCH §2: FEX resolves ELFs when the
  #    interpreter is an absolute store path). Only the main executable carries an
  #    interpreter; the bundled .so's are found via LD_LIBRARY_PATH below.
  # ----------------------------------------------------------------------
  patched = pkgs.runCommand "hollow-knight-fex-patched-1.5.12620"
    {
      nativeBuildInputs = [ pkgs.patchelf pkgs.coreutils ];
      allowSubstitutes = false;
    }
    ''
      cp -a ${unpacked} game && chmod -R u+w game
      patchelf --set-interpreter "${pkgsX86.glibc}/lib/ld-linux-x86-64.so.2" "game/Hollow Knight"
      mkdir -p $out && cp -a game/. $out/
    '';

  # ----------------------------------------------------------------------
  # 4. Guest library set. Under FEX everything the guest links or dlopens must be
  #    present as x86_64 (there is no native bridging as with box64). This is the
  #    union of the box64 sibling's two sets, all resolved from pkgsX86.
  # ----------------------------------------------------------------------
  guestLibs = p: with p; [
    glibc stdenv.cc.cc.lib zlib cairo pango glib dbus.lib
    libgcc libx11 libxext libxcursor libxinerama libxrandr
    libxscrnsaver libxi libxxf86vm libGL libglvnd vulkan-loader
    libxkbcommon wayland SDL2
    systemd libudev0-shim pipewire libpulseaudio alsa-lib
  ];

  hollow-knight-fex = pkgs.writeShellApplication {
    name = "hollow-knight-fex";
    runtimeInputs = [ fexPortable pkgs.coreutils pkgs.util-linux ];
    text = ''
      # ============================================================================
      # KNOWN NON-WORKING research PoC. This is the LINUX x86_64 build under fex-portable
      # (FEXInterpreter). It boots Unity but CRASHES at Mono runtime init with a guest
      # SIGSEGV (SEGV_MAPERR at NULL) — the Mono JIT + guest GC need exact 4K-granular
      # permissions that a 16K host cannot provide without a soft-MMU (see the STATUS header
      # above and RESEARCH §14). No environment variable fixes this; it is a fundamental limit.
      #
      #   * For a PLAYABLE Hollow Knight, use the WINDOWS build:  ../wine-fex/hollow-knight-win.nix
      #   * For a working LINUX Hollow Knight (hardware GL, box64):  ./hollow-knight-x86_64.nix
      # This file is kept only to document the Linux-FEX-on-16K wall for the FEX maintainers.
      # ============================================================================
      echo "hollow-knight-fex: KNOWN-FAILING Linux-FEX PoC (crashes at Mono init on 16K)." >&2
      echo "  -> playable Windows build: nix-build ../wine-fex/hollow-knight-win.nix" >&2
      echo "  -> working Linux build:    nix-build ./hollow-knight-x86_64.nix" >&2

      # --- seal the environment (mirrors the box64 sibling's D13 seal) ---
      # LD_PRELOAD in particular: the host injects a NATIVE aarch64 allocator
      # (nixpkgs' malloc-provider) which the x86_64 guest ld.so cannot preload.
      # LD_LIBRARY_PATH is set deliberately below, so scrub then reset.
      while IFS='=' read -r k _; do
        case "$k" in LD_*|FEX_*) unset "$k" ;; esac
      done < <(env)

      # FEX honours the interpreter and roots absolute store paths directly.
      # Unset FEX_ROOTFS hangs forever (RESEARCH §2), so pin it to the host root.
      export FEX_ROOTFS=/

      # The guest's x86_64 libraries. The game dir itself is first so bundled libs
      # (UnityPlayer.so, the Mono runtime) win over system copies.
      export LD_LIBRARY_PATH=${patched}:${lib.makeLibraryPath (guestLibs pkgsX86)}

      # Keep SDL off the Wayland backend (matches the box64 sibling's verified setup).
      export SDL_VIDEODRIVER=x11

      # Single-instance guard on an open fd; the kernel drops it if we crash.
      lockdir="''${XDG_RUNTIME_DIR:-/tmp}/propnix"
      mkdir -p "$lockdir"
      exec 9>"$lockdir/hollow-knight-fex.lock"
      if ! flock -n 9; then
        echo "hollow-knight-fex: already running" >&2
        exit 1
      fi

      cd ${patched}
      # -force-opengl: without it Unity picks a renderer that dies during scene load.
      exec FEX "./Hollow Knight" -force-opengl "$@"
    '';
  };
in
hollow-knight-fex

# propnix proof of concept #3 — WhatsApp Desktop (Microsoft Store, ARM64 Windows)
# under wine on aarch64. The suffix is the PAYLOAD's architecture, as in the others.
#
# Axes exercised, none of which the earlier PoCs covered:
#   * Microsoft Store payload, resolved and fetched INSIDE a FOD   -> PLAN2 §3.4
#   * a payload whose URL cannot be pinned, only its hash          -> PLAN2 §3.3 rung 3
#   * a multi-payload package: app + vendor-published framework deps
#   * MsixBundle -> inner per-arch MSIX (two levels of ZIP)
#   * .NET (self-contained CoreCLR) + WinUI 3 under wine on ARM64
#
# Build:  nix-build whatsapp-arm64.nix
# Run:    ./result/bin/whatsapp
#
# No credentials of any kind. See msstore/README.md for the protocol and for the
# measurements behind the pinned-root TLS decision.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },
}:

let
  inherit (pkgs) lib;

  productId = "9NKSQGP7F2NH";

  # The resolver. Python, deliberately: it is the protocol spike, and PLAN's Rust rule
  # applies to the real lib/ implementation rather than to a PoC that exists to find out
  # whether this works at all.
  resolver = pkgs.runCommand "propnix-msstore-resolver" { } ''
    mkdir -p $out/bin
    cp ${./msstore/fe3.py} $out/bin/fe3.py
    # fe3.py locates the pinned trust anchor relative to its own directory.
    cp ${./msstore/msroot2011.pem} $out/bin/msroot2011.pem
    chmod +x $out/bin/fe3.py
  '';

  # ----------------------------------------------------------------------
  # 1. Payloads. Store download URLs are signed and expire in hours, so the URL is
  #    NOT pinnable — the (productId, identity) pair is, and the hash gates the result.
  #    This is exactly the fixed-output contract, so nothing is lost: the FOD re-resolves
  #    on every cache miss and nix rejects anything that does not match.
  #
  #    fe3.py additionally checks FE3's own size + SHA1 + SHA256 before exiting, so a
  #    mismatch is reported against the *service's* published digest rather than only as
  #    an opaque nix hash mismatch.
  # ----------------------------------------------------------------------
  fetchStore = { name, identity, hash }:
    pkgs.runCommand name
      {
        outputHashAlgo = "sha256";
        outputHashMode = "flat";
        outputHash = hash;

        # cacert must be a real BUILD INPUT, not merely interpolated into SSL_CERT_FILE
        # below. nix already sets SSL_CERT_FILE in a fixed-output sandbox, and it points at
        # this very store path — but the path is only *mounted* if it is in the
        # derivation's input closure. Without it here the variable is set and the file is
        # absent, so Python silently loads 0 CA certs and the failure surfaces as
        # `CERTIFICATE_VERIFY_FAILED ... self-signed certificate in certificate chain`,
        # which reads like a server or proxy problem rather than a missing file. Measured.
        nativeBuildInputs = [ pkgs.python3 pkgs.cacert ];

        # The DisplayCatalog leg is ordinary public WebPKI and cannot verify without a
        # bundle. (The FE3 leg is unaffected — it carries its own pinned Microsoft root.)
        # Same trap PoC 1 hit with lgogdownloader; PLAN2 §3.3 records it as something every
        # network FOD must set.
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

        # Proprietary and not ours to redistribute.
        allowSubstitutes = false;
        preferLocalBuild = true;
      }
      ''
        test -r "$SSL_CERT_FILE" || {
          echo "propnix: CA bundle $SSL_CERT_FILE is not readable in the sandbox" >&2
          exit 1
        }
        python3 ${resolver}/bin/fe3.py ${productId} \
          --identity '${identity}' \
          --out "$out"
      '';

  version = "2.2630.101.0";

  bundle = fetchStore {
    name = "whatsapp-${version}.msixbundle";
    identity = "5319275A.WhatsAppDesktop_${version}_neutral_~_cv1g1gvanyjgm";
    hash = "sha256-I/MVywKPAIYHPUYmIuhMgpo20O+AjInq5jBMKOiiz0s=";
  };

  # WhatsApp's AppxManifest declares these two as PackageDependency, and they really are
  # absent from the app package: msvcp140.dll / vcruntime140.dll are not inside it. FE3
  # returns them alongside the app, so this list is the VENDOR's dependency closure rather
  # than the hand-tuned kind PLAN2 §7 needs for box64.
  vclibs = fetchStore {
    name = "vclibs-140-14.0.33519.0-arm64.appx";
    identity = "Microsoft.VCLibs.140.00_14.0.33519.0_arm64__8wekyb3d8bbwe";
    hash = "sha256-xz0PVd2jMfncvvyZ/1pCC2ISB3PSkXOHY5OCqkeFM+4=";
  };

  vclibsDesktop = fetchStore {
    name = "vclibs-140-uwpdesktop-14.0.33728.0-arm64.appx";
    identity = "Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_arm64__8wekyb3d8bbwe";
    hash = "sha256-gxEY8vXKyOKShOTswjv0I2Q2zMLqSnwiXElG+M/SndM=";
  };

  # ----------------------------------------------------------------------
  # 2. Unpack. Two levels: the .msixbundle contains one MSIX per architecture plus
  #    scale-* resource packages; we want only the arm64 one. Both levels are plain ZIP,
  #    so bsdtar handles them and wine's missing AppX deployment stack is irrelevant
  #    (PLAN2 §2, proven by slack-arm64.nix).
  # ----------------------------------------------------------------------
  unpacked = pkgs.runCommand "whatsapp-unpacked-${version}"
    {
      nativeBuildInputs = [ pkgs.libarchive pkgs.python3 ];
      allowSubstitutes = false;
    }
    ''
      mkdir -p $out

      inner="WhatsApp.Root_${version}_arm64.msix"
      bsdtar -xf ${bundle} "$inner"
      bsdtar -C $out -xf "$inner"

      # Framework DLLs go beside the executable: Windows' loader searches the exe's
      # directory first, which is what a deployed AppX gets via its package graph. Only
      # the arm64 payloads are staged; a foreign-arch DLL here would be found and then
      # fail to load, which is worse than absent.
      for appx in ${vclibs} ${vclibsDesktop}; do
        tmp=$(mktemp -d)
        bsdtar -C "$tmp" -xf "$appx"
        find "$tmp" -maxdepth 1 -type f -iname '*.dll' -exec cp -n {} $out/ \;
        rm -rf "$tmp"
      done

      test -e "$out/WhatsApp.Root.exe" || { echo "main binary missing" >&2; exit 1; }

      # A silent flip to x86_64 would void the no-emulation premise, so fail the BUILD
      # rather than discovering it at runtime. Same assertion as slack-arm64.nix.
      python3 - "$out/WhatsApp.Root.exe" <<'EOF'
      import struct, sys
      with open(sys.argv[1], "rb") as f:
          d = f.read(0x400)
      mach = struct.unpack_from("<H", d, struct.unpack_from("<I", d, 0x3C)[0] + 4)[0]
      if mach != 0xAA64:
          sys.exit(f"expected ARM64 PE (0xaa64), got 0x{mach:04x}")
      print("PE machine 0xaa64 (ARM64) confirmed")
      EOF

      # Prove the external dependency actually got satisfied, rather than trusting that
      # the appx layout was what we assumed.
      for dll in msvcp140.dll vcruntime140.dll; do
        test -e "$out/$dll" || { echo "framework dep $dll not staged" >&2; exit 1; }
      done
    '';

  wine = pkgs.wineWow64Packages.stable;

  # ----------------------------------------------------------------------
  # 3. Wrapper. Sealed per PLAN2 §7 (D13); prefix layout per PLAN2 §7.2.
  # ----------------------------------------------------------------------
  whatsapp = pkgs.writeShellApplication {
    name = "whatsapp";
    runtimeInputs = [ wine pkgs.coreutils pkgs.gnugrep ];
    text = ''
      # --- D13 seal: drop anything the session may have set that would change behaviour.
      # DXVK_* is included because a user's global DXVK config would otherwise leak into
      # a prefix that has no DXVK installed at all.
      while IFS='=' read -r k _; do
        case "$k" in WINE*|LD_*|DXVK_*) unset "$k" ;; esac
      done < <(env)

      # PLAN2 §7.2: nix-managed state nowhere, user state in a standardised place.
      state="''${XDG_STATE_HOME:-$HOME/.local/state}/propnix/whatsapp-arm64"
      export WINEPREFIX="$state/prefix"
      export WINEARCH=win64          # never win32; deprecated in wine 11
      # Gecko only. NOT "mscoree,mshtml=" as in slack-arm64.nix: WhatsApp is a .NET app,
      # and disabling mscoree makes wine's loader refuse its managed assemblies outright —
      # `err:module:fixup_imports_ilonly mscoree.dll not found, IL-only binary
      # L"System.Runtime.dll" cannot be loaded`, then a hang. Wine's builtin mscoree is
      # present for aarch64-windows and is all that is needed: the app carries its own
      # CoreCLR, so mscoree only has to service the IL-only PE fixup path, never execute
      # anything. This is per-package tuning data, exactly the kind PLAN2 §7.1 exists to hold.
      export WINEDLLOVERRIDES="mshtml="
      mkdir -p "$state"

      # Recreate the prefix when the wine build changes, not on every launch. Keyed on
      # wine's STORE PATH, so a wine upgrade is detected precisely.
      stamp="$state/.wine-store-path"
      if [ ! -e "$stamp" ] || [ "$(cat "$stamp")" != "${wine}" ]; then
        echo "whatsapp: preparing wine prefix (first run or wine changed)..." >&2
        # Everything that touches the prefix runs in ONE headless block, and the block
        # ends by waiting for wineserver to exit.
        #
        # Headless because with DISPLAY/WAYLAND_DISPLAY set, wineboot pops up a modal
        # "configuration is being updated" dialog on the user's desktop (measured twice).
        #
        # Waiting matters more than it looks: a wineserver started here WITHOUT display
        # variables outlives the subshell by default, the app then attaches to that same
        # server, and every window creation fails with
        # `err:winediag:nodrv_CreateWindow Application tried to create a window, but no
        # driver could be loaded`. Measured — and it presents as a display-server problem
        # rather than as a leftover daemon, which is what makes it worth a comment.
        ( unset DISPLAY WAYLAND_DISPLAY
          wineboot -u >/dev/null 2>&1 || true
          # Driver choice is a runtime registry setting, not a package property, so it
          # belongs in prefix setup rather than on the launch path. Wayland first: verified
          # working on this host with wine's notepad under wineWow64 (slack-arm64.json).
          wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d 'wayland,x11' /f \
            >/dev/null 2>&1 || true

          # Disable wine's automatic crash debugger. Wine's default AeDebug handler is
          # `winedbg --auto`, which on a crash opens a "Wine Debugger" console window; the
          # crashed process is already dead, so that window has no working close path and
          # must be killed by PID from outside. This app aborts reliably (RESEARCH §11),
          # so without this every launch strands another undismissable window.
          #
          # The value must be NON-EMPTY and must NOT resolve. From wine's start_debugger()
          # in dlls/kernelbase/debug.c:
          #   * `format` is only taken when NtQueryValueKey returns STATUS_BUFFER_TOO_SMALL,
          #     which a zero-length value never does — so an EMPTY Debugger is treated
          #     exactly like an absent one and wine falls back to its built-in
          #     `winedbg --auto`. Measured: setting it empty changed nothing.
          #   * a non-empty value is used as the command line; if CreateProcessW fails,
          #     start_debugger returns FALSE with no fallback and the process dies quietly.
          # So a path that cannot exist is the reliable "no debugger" setting. One
          # `Couldn't start debugger` line in the log is expected, and is the confirmation.
          #
          # Auto=1 (not 0) on purpose: with Auto=0 wine first tries a MessageBox asking
          # whether to debug, which is another dialog on the user's desktop.
          #
          # No '%' in the value: wine passes it through swprintf as a format string.
          #
          # This belongs in EVERY propnix wine package. A packaged app crashing is normal,
          # and littering the desktop with dead consoles is not an acceptable failure mode.
          # It is also part of D13 sealing: the user's own AeDebug preference must not
          # change how a sealed package behaves.
          wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' \
            /v Debugger /t REG_SZ \
            /d 'C:\windows\system32\propnix-debugger-disabled.exe' /f >/dev/null 2>&1 || true
          wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' \
            /v Auto /t REG_SZ /d 1 /f >/dev/null 2>&1 || true

          wineserver -w ) || true
        printf '%s' "${wine}" > "$stamp"
      fi

      # WhatsApp is an MSIX app run WITHOUT AppX deployment, so nothing registered its
      # package identity. Run from the store directory so the loader finds the staged
      # framework DLLs next to the exe.
      cd ${unpacked}
      exec wine ./WhatsApp.Root.exe "$@"
    '';
  };
in
whatsapp

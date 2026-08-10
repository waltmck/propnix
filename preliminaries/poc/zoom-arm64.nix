# propnix proof of concept #4 — Zoom Workplace (Microsoft Store, ARM64 Windows) under
# wine on aarch64. The suffix is the PAYLOAD's architecture, as in the others.
#
# Axes exercised that the earlier PoCs did not:
#   * the Store's WIN32 acquisition path (winget manifests), not MSIX/FE3
#   * a content-addressed CDN URL, so plain fetchurl suffices — no resolver in the FOD
#   * an INSTALLER payload (7z SFX -> CAB) unpacked rather than executed
#   * a native C++ app that PASSES the RESEARCH §11 wine triage rule
#
# Build:  nix-build zoom-arm64.nix
# Run:    ./result/bin/zoom
#
# No credentials. Unlike whatsapp-arm64.nix this needs no SOAP, no cookies, no tree walk
# and no pinned private CA — see the acquisition note below.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },

  # Subject of the certificate that re-signs the patched modules (section 0). A list, in
  # order, so comma-containing values need no RFC 4514 escaping. The key is derived from this
  # subject deterministically inside the build — nothing committed, nothing random
  # (tools/mk-codesign-cert.py). The default suffices for apps that check signature VALIDITY.
  # It does NOT satisfy Zoom, which pins the signer's publisher AND CA by name; no locally
  # issued certificate can (RESEARCH §12.2), so Zoom's dialogs are accepted as-is.
  signingSubject ? [
    { name = "O"; value = "propnix"; }
    { name = "CN"; value = "propnix local code signing"; }
  ],

  # Short by design: Authenticode signatures here are untimestamped, so they expire with the
  # certificate. That is the ONLY dimension X.509 lets us restrict — see the generator's
  # note on why nameConstraints cannot help.
  signingDays ? 3650,
}:

let
  inherit (pkgs) lib;

  # The version the BINARIES report. The Store manifest files this installer under
  # PackageVersion "6.6.11 (23272)", which is simply wrong: Zoom.exe's PE version
  # resource says 7.1.5.43453. Same class of problem as DisplayCatalog vs FE3 in
  # PLAN2 §3.4 — Store metadata is not authoritative about its own payload — so the
  # package is named after the bytes, not the label.
  version = "7.1.5.43453";
  manifestVersionLabel = "6.6.11 (23272)";

  # ----------------------------------------------------------------------
  # 0. Local code-signing identity, generated deterministically.
  #
  # The byte fixups below break the patched files' Authenticode digests, so any app that
  # verifies the modules it loads will object. Re-signing (section below) restores a valid,
  # trusted signature — the reusable fix for apps that check signature VALIDITY. It leaves the
  # binaries honestly signed rather than digest-broken, and is retained even though it does
  # not silence Zoom (which additionally pins publisher+CA; see RESEARCH §12.2).
  #
  # The key/cert are derived from the subject DETERMINISTICALLY so nothing random enters an
  # input-addressed store path, and nothing is committed. Capabilities are ASSERTED by the
  # generator, not just requested: CA:FALSE + keyUsage=digitalSignature (no keyCertSign) +
  # EKU=codeSigning, all critical — the key can sign code and nothing else. See
  # tools/mk-codesign-cert.py and RESEARCH §12.3.
  codesign = pkgs.runCommand "propnix-codesign-material"
    {
      nativeBuildInputs = [
        pkgs.python3
        pkgs.python3Packages.pycryptodome
        pkgs.python3Packages.cryptography
      ];
      subjectJson = builtins.toJSON signingSubject;
      passAsFile = [ "subjectJson" ];
    }
    ''
      python3 ${../tools/mk-codesign-cert.py} \
        --subject-json "$subjectJsonPath" \
        --days ${toString signingDays} \
        --out $out
    '';

  # ----------------------------------------------------------------------
  # 1. Payload.
  #
  # Product XP99J3KP4XZ4VV is a Store *Win32* listing, so DisplayCatalog 404s on it and
  # the FE3 chain does not apply at all. Its installers are published as winget manifests:
  #
  #   https://storeedgefd.dsx.mp.microsoft.com/v9.0/packageManifests/XP99J3KP4XZ4VV
  #
  # which is plain public JSON over ordinary WebPKI and carries an authoritative
  # InstallerSha256 per architecture. This is a strictly easier rung than PLAN2 §3.4's FE3 path:
  # no SOAP, no cookie, no fixpoint sync, no private-CA trust anchor.
  #
  # Better still, the CDN URL is CONTENT-ADDRESSED — the sha256 is a path component — so
  # unlike an FE3 signed URL it does not expire and can be pinned directly. Hence plain
  # fetchurl rather than a resolver inside the FOD. The manifest endpoint remains the
  # discovery mechanism for a future updateScript.
  #
  # Verified: fetches unauthenticated (HTTP 200, 115,538,048 bytes) and the sha256 matches.
  sha256 = "13c07b946ce198dd6a18033e63fb2e87f7bcf34cd423f9bfbedee1d3b870f2de";

  payload = pkgs.fetchurl {
    name = "ZoomInstallerFull-${version}-arm64.exe";
    url =
      "https://cdn.storeedgefd.dsx.mp.microsoft.com/eus2/cachedpackages"
      + "/33785810/8e376d36-34a3-46aa-93a1-e82709b19566/${sha256}/file";
    hash = "sha256-E8B7lGzhmN1qGAM+Y/suh/e880zUI/m/vt7h07hw8t4=";
  };

  # ----------------------------------------------------------------------
  # 2. Unpack. Two nested archives, and neither needs the installer to RUN:
  #      ZoomInstallerFull.exe   7z SFX  -> Installer.exe + ZoomFull_Sip.cab
  #      ZoomFull_Sip.cab        CAB     -> the app tree, flat, 248 files
  #    bsdtar reads both, so this stays a pure extraction like the MSIX PoCs. Running the
  #    installer under wine would mean a mutable prefix at build time and a registry the
  #    store path cannot hold; extraction sidesteps both.
  # ----------------------------------------------------------------------
  unpacked = pkgs.runCommand "zoom-unpacked-${version}"
    {
      nativeBuildInputs = [ pkgs.libarchive pkgs.python3 pkgs.osslsigncode ];
      allowSubstitutes = false;
    }
    ''
      export PATCHED_LIST="$PWD/patched.txt"
      : > "$PATCHED_LIST"

      mkdir -p sfx && cd sfx
      bsdtar -xf ${payload}
      test -e ZoomFull_Sip.cab || { echo "SFX layout changed: no ZoomFull_Sip.cab" >&2; exit 1; }

      mkdir -p $out
      bsdtar -C $out -xf ZoomFull_Sip.cab

      test -e "$out/Zoom.exe" || { echo "Zoom.exe missing from cab" >&2; exit 1; }

      # --- EL0 PMU access fixup ---------------------------------------------------------
      # Zoom reads the PMU cycle counter directly for timing:
      #     mrs Xt, pmccntr_el0            (d53b9d00 | Rt)
      # Windows on ARM64 lets EL0 read that register, and MSVC emits it for __rdtsc-style
      # intrinsics. Linux does NOT enable EL0 PMU access by default, so the instruction
      # traps and the process dies with STATUS_ILLEGAL_INSTRUCTION (0xc000001d).
      #
      # Diagnosed from Zoom's own crash report rather than guessed:
      #     ExceptionModule zlt.dll  base 0x6fffea610000  address 0x6fffea8edd68
      #     ExceptionCode   0xc000001d
      # -> offset 0x2ddd68, which disassembles to exactly `mrs x22, pmccntr_el0`.
      # It fires immediately after joining a meeting, so it is squarely in the way.
      #
      # The host route is unavailable: arm64 Linux >= 6.1 can grant EL0 PMU access via
      # /proc/sys/kernel/perf_user_access, but that file does not exist on this kernel
      # (7.1.5, Asahi) — Apple's PMU driver does not implement it. So fix the payload.
      #
      # Substitute CNTVCT_EL0, the virtual timer counter (d53be040 | Rt), which IS
      # EL0-readable on Linux — it is what the vDSO clock reads — and is a same-width
      # monotonically increasing counter, so it is a drop-in for timing deltas.
      #
      # CAVEAT, stated because it is a real semantic change and not a no-op: CNTVCT ticks
      # at the architectural timer frequency (~24 MHz here), not at the CPU clock, so any
      # code interpreting the delta as *cycles* will read low by ~2 orders of magnitude.
      # For elapsed-time measurement that is harmless; code deriving a CPU frequency from
      # it would be wrong. Preferred over `mov Xt, #0` regardless, since a frozen counter
      # invites division by zero and unbounded spin loops.
      python3 - $out <<'EOF'
      import glob, os, struct, sys

      PMCCNTR = 0xD53B9D00      # mrs Xt, pmccntr_el0   (Rt in low 5 bits)
      CNTVCT  = 0xD53BE040      # mrs Xt, cntvct_el0
      MASK    = 0xFFFFFFE0

      root = sys.argv[1]
      total, per_file = 0, []
      for path in sorted(glob.glob(os.path.join(root, "*.dll")) + glob.glob(os.path.join(root, "*.exe"))):
          data = bytearray(open(path, "rb").read())
          n = 0
          # 4-byte aligned scan: every A64 instruction is a naturally aligned word, so an
          # aligned match cannot be a misread of embedded data at an odd offset.
          for i in range(0, len(data) - 3, 4):
              w = struct.unpack_from("<I", data, i)[0]
              if (w & MASK) == PMCCNTR:
                  struct.pack_into("<I", data, i, CNTVCT | (w & 0x1F))
                  n += 1
          if n:
              open(path, "wb").write(data)
              per_file.append((os.path.basename(path), n))
              total += n

      if not total:
          sys.exit("expected at least one `mrs Xt, pmccntr_el0`; found none. "
                   "If upstream stopped using it, drop this fixup.")
      # Record what was touched, so exactly those files get re-signed below.
      with open(os.environ["PATCHED_LIST"], "a") as f:
          for name, _ in per_file:
              f.write(name + "\n")
      for name, n in per_file:
          print(f"PMU fixup: {name}: {n} x pmccntr_el0 -> cntvct_el0")
      print(f"PMU fixup: {total} instruction(s) in {len(per_file)} binaries")
      EOF

      # --- 16K-page fixup -------------------------------------------------------------
      # This host has 16K pages; the payload is built for Windows, which uses 4K pages on
      # ARM64 too, so its SectionAlignment is 0x1000. Wine 11.0 handles that fine in
      # general (it tracks an emulated page_mask separately from host_page_mask), with one
      # deliberate exception: a section that is WRITABLE **and** SHARED and does not land
      # on a host page boundary. dlls/ntdll/unix/virtual.c only mmaps when
      # host_addr == map_addr, and its fallback copies bytes instead of sharing them —
      # which would silently break cross-process visibility — so it refuses:
      #     err:virtual:map_file_into_view unaligned shared mapping ... not supported
      #     err:module:map_image_into_view Could not map ... shared section .PROPSEC
      #     err:module:import_dll Loading library zCrashReport64.dll failed (c000007b)
      # and Zoom.exe then fails to load at all (c0000135), exit 53.
      #
      # Note NT's 64K allocation granularity does NOT save us: it aligns image *bases*,
      # while .PROPSEC sits at base+0x65000, which is 0x1000 (mod 0x4000) — no 64K-aligned
      # base can make it 16K-aligned.
      #
      # Exactly ONE section in the whole 153-binary payload is writable+shared, and it
      # belongs to the crash reporter. Clearing IMAGE_SCN_MEM_SHARED (0x10000000) makes it
      # private/copy-on-write, so wine's ordinary path maps it. The cost is that Zoom's
      # processes no longer share crash-reporter state; normal operation is unaffected.
      #
      # This is per-package tuning data of the kind PLAN2 §7.1 exists to hold, and it is
      # asserted rather than assumed: the build fails if the section is not found, is
      # already unshared, or if any OTHER writable+shared section appears in a future
      # version (which would need its own decision rather than silent inclusion).
      python3 - $out <<'EOF'
      import glob, os, struct, sys

      SHARED, WRITE = 0x10000000, 0x80000000
      root = sys.argv[1]
      expected = ("zCrashReport64.dll", ".PROPSEC")
      patched, others = [], []

      for path in sorted(glob.glob(os.path.join(root, "*.dll")) + glob.glob(os.path.join(root, "*.exe"))):
          with open(path, "rb") as f:
              data = bytearray(f.read())
          if data[:2] != b"MZ":
              continue
          pe = struct.unpack_from("<I", data, 0x3C)[0]
          if data[pe:pe+4] != b"PE\0\0":
              continue
          nsec = struct.unpack_from("<H", data, pe + 6)[0]
          opt_size = struct.unpack_from("<H", data, pe + 20)[0]
          sec0 = pe + 24 + opt_size
          for i in range(nsec):
              off = sec0 + i * 40
              name = data[off:off+8].rstrip(b"\0").decode("ascii", "replace")
              chars = struct.unpack_from("<I", data, off + 36)[0]
              if not (chars & SHARED and chars & WRITE):
                  continue
              key = (os.path.basename(path), name)
              if key != expected:
                  others.append(f"{key[0]}:{key[1]}")
                  continue
              struct.pack_into("<I", data, off + 36, chars & ~SHARED)
              with open(path, "wb") as f:
                  f.write(data)
              patched.append(f"{key[0]}:{key[1]} 0x{chars:08x} -> 0x{chars & ~SHARED:08x}")

      if others:
          sys.exit("unexpected writable+shared section(s), needs a decision: " + ", ".join(others))
      if not patched:
          sys.exit(f"expected a writable+shared {expected[1]} in {expected[0]}; not found. "
                   "If upstream fixed the alignment, drop this fixup.")
      # Record what was touched, so exactly those files get re-signed below.
      with open(os.environ["PATCHED_LIST"], "a") as f:
          for p in patched:
              f.write(p.split(":")[0] + "\n")
      for p in patched:
          print("16K fixup: cleared IMAGE_SCN_MEM_SHARED on " + p)
      EOF

      # --- re-sign every patched file ---------------------------------------------------
      # Restore a valid, trusted Authenticode signature on each patched module; the prefix is
      # made to trust the signer at first run (in the wrapper). Reusable infrastructure that
      # removes the "unknown publisher" warning for apps checking signature VALIDITY, and
      # leaves compat-patched binaries honestly signed. It does not satisfy Zoom specifically
      # (publisher+CA pin) — Zoom's dialogs are accepted as-is. RESEARCH §12.2.
      sort -u "$PATCHED_LIST" > patched-unique.txt
      echo "re-signing $(wc -l < patched-unique.txt) patched file(s)"
      while read -r f; do
        [ -n "$f" ] || continue
        # -time is REQUIRED for reproducibility: without it osslsigncode embeds a signingTime
        # attribute and two builds of the same input produce different bytes (measured —
        # differing sha256 without it, identical with it). 1767225600 = 2026-01-01T00:00:00Z,
        # matching the certificate's notBefore. Note this is a signingTime ATTRIBUTE, not a
        # trusted timestamp countersignature: signatures still expire with the cert, which is
        # deliberate (see the generator's note on time being the only lever X.509 gives us).
        osslsigncode sign -certs ${codesign}/cert.crt -key ${codesign}/cert.key \
          -h sha256 -time 1767225600 -in "$out/$f" -out "$out/$f.signed" >/dev/null 2>&1 \
          || { echo "signing failed for $f" >&2; exit 1; }
        mv -f "$out/$f.signed" "$out/$f"
        # Assert it actually verifies against our CA, rather than trusting exit status.
        osslsigncode verify -CAfile ${codesign}/cert.crt "$out/$f" 2>&1 \
          | grep -q "Signature verification: ok" \
          || { echo "signature does not verify for $f" >&2; exit 1; }
        echo "  signed + verified: $f"
      done < patched-unique.txt

      # Assert the whole app is ARM64, not just the entry point. A silent flip to x86_64
      # in any of these would void the no-emulation premise, so fail the BUILD.
      python3 - $out <<'EOF'
      import glob, os, struct, sys
      root = sys.argv[1]
      bad = []
      for f in sorted(glob.glob(os.path.join(root, "*.exe"))):
          with open(f, "rb") as fh:
              d = fh.read(0x400)
          mach = struct.unpack_from("<H", d, struct.unpack_from("<I", d, 0x3C)[0] + 4)[0]
          if mach != 0xAA64:
              bad.append(f"{os.path.basename(f)}=0x{mach:04x}")
      if bad:
          sys.exit("expected ARM64 (0xaa64) for every .exe, got: " + ", ".join(bad))
      print(f"all {len(glob.glob(os.path.join(root, '*.exe')))} executables are ARM64 (0xaa64)")
      EOF
    '';

  # STAGING, not stable — a measured per-package requirement, not a preference.
  # zLooper.dll (pulled in transitively by Cmmlib.dll/ZoomTask.dll, which Zoom.exe imports
  # statically) needs KERNEL32.SetThreadpoolTimerEx. Measured across the three nixpkgs
  # builds:
  #     stable   11.0            SetThreadpoolTimerEx=no   SetThreadpoolWaitEx=no
  #     unstable 11.12           SetThreadpoolTimerEx=no    SetThreadpoolWaitEx=no
  #     staging  11.12           SetThreadpoolTimerEx=YES   SetThreadpoolWaitEx=no
  # On stable the app aborts with
  #     wine: Call from ... to unimplemented function KERNEL32.dll.SetThreadpoolTimerEx
  # SetThreadpoolWaitEx is still missing everywhere; it is needed by zAssistant.dll, which
  # is not a static import of Zoom.exe, so whether it is reached is a question about which
  # features get used rather than about startup.
  wine = pkgs.wineWow64Packages.staging;

  # ----------------------------------------------------------------------
  # 3. Wrapper. Sealed per D13 (PLAN2 §7); prefix layout per PLAN2 §7.2.
  # ----------------------------------------------------------------------
  zoom = pkgs.writeShellApplication {
    name = "zoom";
    runtimeInputs = [ wine pkgs.coreutils pkgs.gnused pkgs.xrdb ];
    text = ''
      # --- D13 seal ---
      # Captured BEFORE the scrub: the seal's WINE* glob also matches WINEDEBUG, so a
      # plain `WINEDEBUG=+loaddll ./zoom` is silently swallowed and debugging appears to
      # do nothing (measured — it cost a wasted crash-reproduction round). Rather than
      # poke a hole in the glob, take the value through a propnix-namespaced variable and
      # re-export it after scrubbing, so nothing leaks in unless it was asked for by name.
      #
      #   PROPNIX_WINEDEBUG=+loaddll        map fault addresses to modules
      #   PROPNIX_WINEDEBUG=+seh,+richedit  channel-specific tracing
      #
      # This is the narrow, auditable form of PLAN2 §7's --propnix-unseal.
      propnix_winedebug="''${PROPNIX_WINEDEBUG:-}"

      while IFS='=' read -r k _; do
        case "$k" in WINE*|LD_*|DXVK_*) unset "$k" ;; esac
      done < <(env)

      [ -n "$propnix_winedebug" ] && export WINEDEBUG="$propnix_winedebug"

      state="''${XDG_STATE_HOME:-$HOME/.local/state}/propnix/zoom-arm64"
      export WINEPREFIX="$state/prefix"
      export WINEARCH=win64
      # Gecko/Mono prompts only. Zoom is native C++ with no managed code, so unlike
      # whatsapp-arm64.nix there is no reason to keep mscoree enabled.
      export WINEDLLOVERRIDES="mscoree,mshtml="
      mkdir -p "$state"

      stamp="$state/.wine-store-path"
      if [ ! -e "$stamp" ] || [ "$(cat "$stamp")" != "${wine}" ]; then
        echo "zoom: preparing wine prefix (first run or wine changed)..." >&2
        # One headless block, ending in `wineserver -w`. Headless so wineboot's
        # "configuration is being updated" dialog never reaches the desktop; waiting so no
        # displayless wineserver survives to break window creation with
        # nodrv_CreateWindow. Both measured — see docs/verified/whatsapp-arm64.json.
        ( unset DISPLAY WAYLAND_DISPLAY
          wineboot -u >/dev/null 2>&1 || true

          # (The graphics driver is applied below as a live knob, not here, so it can be
          # retested without recreating the prefix — see the note there.)

          # (AeDebug and the systray are applied below rather than here, so their knobs
          # stay live — see the notes there.)

          wineserver -w ) || true
        printf '%s' "${wine}" > "$stamp"
      fi

      # --- trust the local code-signing cert --------------------------------------------
      # The patched files are re-signed at build time with the cert in `codesign`; this makes
      # the prefix trust that signer, so Zoom's module verification passes and the
      # "unknown publisher" dialogs stop.
      #
      # Installed by writing the registry stores directly, because wine has no working tool
      # for it: programs/certutil implements only -decodehex, and cryptext's PFX entry points
      # are stubs. dlls/crypt32/regstore.c reads a REG_BINARY "Blob" from a subkey named
      # after the SHA1 thumbprint, and the blob format is built in the `codesign` derivation.
      #
      # Root gives a trusted chain; TrustedPublisher marks the publisher itself as trusted.
      # HKLM and HKCU both, since wine consults machine and user stores.
      certstamp="$state/.codesign-thumbprint"
      thumb=$(cat ${codesign}/thumbprint)
      if [ ! -e "$certstamp" ] || [ "$(cat "$certstamp")" != "$thumb" ]; then
        echo "zoom: trusting propnix code-signing cert $thumb in the prefix" >&2
        blob=$(cat ${codesign}/blob.hex)
        ( unset DISPLAY WAYLAND_DISPLAY
          for root in HKLM HKCU; do
            for store in Root TrustedPublisher; do
              wine reg add \
                "$root\\Software\\Microsoft\\SystemCertificates\\$store\\Certificates\\$thumb" \
                /v Blob /t REG_BINARY /d "$blob" /f >/dev/null 2>&1 || true
            done
          done
          wineserver -w ) || true
        printf '%s' "$thumb" > "$certstamp"
      fi

      # --- crash debugger ---------------------------------------------------------------
      # Normally suppressed. Wine's default AeDebug handler is `winedbg --auto`, which on a
      # crash opens a "Wine Debugger" console; the crashed process is already dead, so that
      # window has no working close path and must be killed by PID. The value must be
      # NON-EMPTY and must not resolve: wine only honours it when the registry read returns
      # STATUS_BUFFER_TOO_SMALL, so an EMPTY value falls back to the built-in winedbg
      # anyway (measured). Auto=1 skips the "do you wish to debug?" MessageBox.
      #
      # PROPNIX_WINEDBG=1 restores the real debugger, because suppressing it also
      # suppresses the BACKTRACE — a crash then reports only
      #     wine: Unhandled page fault on read access to <addr> at address <addr>
      # with no module or symbol, which is not enough to diagnose anything. This is the
      # debug escape hatch PLAN2 §7 calls for, and it is needed as soon as a sealed package
      # crashes for a reason you actually want to understand.
      #
      # CAUTION, measured: turning this on can change the failure mode instead of
      # explaining it. On this app winedbg deadlocked on kernelbase's console_section
      # (`err:sync:RtlpWaitForCriticalSection ... console.c: console_section wait timed
      # out`) and never produced a backtrace, replacing a clean page fault with a hang.
      # Prefer PROPNIX_WINEDEBUG=+loaddll first: the page-fault message already prints the
      # faulting address, and the module bases are enough to identify the culprit without
      # attaching anything.
      if [ "''${PROPNIX_WINEDBG:-0}" = "1" ]; then
        aedebug='winedbg --auto %ld %ld'
      else
        aedebug='C:\windows\system32\propnix-debugger-disabled.exe'
      fi
      aedbgstamp="$state/.aedebug"
      if [ ! -e "$aedbgstamp" ] || [ "$(cat "$aedbgstamp")" != "$aedebug" ]; then
        ( unset DISPLAY WAYLAND_DISPLAY
          wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' \
            /v Debugger /t REG_SZ /d "$aedebug" /f >/dev/null 2>&1 || true
          wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' \
            /v Auto /t REG_SZ /d 1 /f >/dev/null 2>&1 || true
          wineserver -w ) || true
        printf '%s' "$aedebug" > "$aedbgstamp"
      fi

      # --- wine systray -----------------------------------------------------------------
      # Key and type read from programs/explorer/desktop.c: HKCU\Software\Wine\Explorer,
      # value ShowSystray, queried with RRF_RT_REG_DWORD, default ON.
      #
      # Default off here because when no XEmbed system tray exists on the display — and
      # there is none under a wlroots compositor, whose bar speaks StatusNotifier over
      # D-Bus instead — wine's explorer.exe draws its own standalone window, which appears
      # as a small thin ~100x13 window in the top-left corner on every launch
      # (user-reported).
      #
      # TRADE-OFF, hence a knob rather than a hard-coded 0: with the systray suppressed
      # tray icons have nowhere to go, so if Zoom is set to "minimize to notification
      # area" its window can become unreachable. PROPNIX_SYSTRAY=1 restores it.
      #
      # Applied on change like the DPI below, NOT during prefix creation — otherwise
      # flipping the variable would silently do nothing until the prefix was deleted.
      # That is a trap worth avoiding for every user-facing knob.
      systray=$([ "''${PROPNIX_SYSTRAY:-0}" = "1" ] && echo 1 || echo 0)
      systraystamp="$state/.systray"
      if [ ! -e "$systraystamp" ] || [ "$(cat "$systraystamp")" != "$systray" ]; then
        ( unset DISPLAY WAYLAND_DISPLAY
          wine reg add 'HKCU\Software\Wine\Explorer' /v ShowSystray /t REG_DWORD \
            /d "$systray" /f >/dev/null 2>&1 || true
          wineserver -w ) || true
        printf '%s' "$systray" > "$systraystamp"
      fi

      # --- graphics driver --------------------------------------------------------------
      # Default x11: under winewayland Zoom draws the real window plus three blank white ones,
      # because its DuiLib UI uses layered windows for shadows and toasts (RESEARCH §12).
      # A live knob (PROPNIX_GRAPHICS=wayland,x11 to retest) since it interacts with the
      # still-open UI-overflow defect.
      graphics="''${PROPNIX_GRAPHICS:-x11}"
      gfxstamp="$state/.graphics"
      if [ ! -e "$gfxstamp" ] || [ "$(cat "$gfxstamp")" != "$graphics" ]; then
        echo "zoom: graphics driver = $graphics" >&2
        ( unset DISPLAY WAYLAND_DISPLAY
          wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /t REG_SZ \
            /d "$graphics" /f >/dev/null 2>&1 || true
          wineserver -w ) || true
        printf '%s' "$graphics" > "$gfxstamp"
      fi

      # --- wined3d renderer -------------------------------------------------------------
      # In-meeting video does not display, and the log shows wined3d failing to resize the
      # presentation swapchain over and over:
      #     err:d3d:wined3d_swapchain_resize_buffers Something's still holding back buffer 0
      # (209 occurrences in one meeting). Audio is a separate path and works, which is
      # consistent with the fault being in presentation rather than in media transport.
      #
      # Key and accepted values read from dlls/wined3d/wined3d_main.c: HKCU\Software\Wine\
      # Direct3D, value "renderer", one of "vulkan" | "gl" | "gdi"/"no3d". The Vulkan
      # backend has a separate swapchain implementation, so it is worth trying before
      # touching Zoom's own hardware-acceleration settings.
      #
      # Left at wine's default unless asked for, since this is unverified:
      #     PROPNIX_D3D_RENDERER=vulkan   (or gl, or gdi to force software presentation)
      # A knob that only ACTS when set is a trap: the previous value stays in the registry,
      # so the setting silently persists into later runs. Testing `=gdi` once left
      # `err:winediag:wined3d_dll_init Disabling 3D support.` in force for every subsequent
      # launch, which invalidated two later video experiments before it was spotted.
      # So "unset" is a real state that DELETES the value and restores wine's default.
      d3d="''${PROPNIX_D3D_RENDERER:-default}"
      d3dstamp="$state/.d3drenderer"
      if [ ! -e "$d3dstamp" ] || [ "$(cat "$d3dstamp")" != "$d3d" ]; then
        echo "zoom: wined3d renderer = $d3d" >&2
        ( unset DISPLAY WAYLAND_DISPLAY
          if [ "$d3d" = "default" ]; then
            wine reg delete 'HKCU\Software\Wine\Direct3D' /v renderer /f >/dev/null 2>&1 || true
          else
            wine reg add 'HKCU\Software\Wine\Direct3D' /v renderer /t REG_SZ \
              /d "$d3d" /f >/dev/null 2>&1 || true
          fi
          wineserver -w ) || true
        printf '%s' "$d3d" > "$d3dstamp"
      fi

      # --- disable auto-update ----------------------------------------------------------
      # propnix pins the version in the derivation; an app updating itself is never wanted.
      # The real guarantee is architectural (see below): the app runs from the read-only
      # store, so an updater cannot replace its binaries regardless. This policy is
      # best-effort defence-in-depth on top of that — Zoom's documented enterprise GPO,
      # under a policy path present in cmmbiz.dll. Set in HKLM and HKCU; unverified (would
      # need to provoke an update to observe), but harmless and cheap.
      #
      # STORE IMMUTABILITY, stated because it is the actual protection: the app tree is a
      # read-only /nix/store path (dr-xr-xr-x root, kernel-enforced) and the only writable
      # state is the separate wine prefix ($state/prefix). The wrapper runs Zoom.exe from
      # the store, never from a writable overlay of the install tree, so an app cannot
      # overwrite OR shadow its own store-provided binaries. This must hold for every
      # propnix package (PLAN2 §7.2).
      autoupdstamp="$state/.no-autoupdate"
      if [ ! -e "$autoupdstamp" ]; then
        ( unset DISPLAY WAYLAND_DISPLAY
          for root in HKLM HKCU; do
            wine reg add "$root\\Software\\Policies\\Zoom\\Zoom Meetings\\General" \
              /v EnableClientAutoUpdate /t REG_DWORD /d 0 /f >/dev/null 2>&1 || true
            wine reg add "$root\\Software\\Policies\\Zoom\\Zoom Meetings\\General" \
              /v EnableSilentAutoUpdate /t REG_DWORD /d 0 /f >/dev/null 2>&1 || true
          done
          wineserver -w ) || true
        : > "$autoupdstamp"
      fi

      # --- DPI ------------------------------------------------------------------------
      # Wine takes its DPI ONLY from this registry value; win32u/sysparams.c has
      # DWORD_ENTRY(LOGPIXELS, 0, DESKTOP_KEY, "LogPixels") and winex11.drv contains no
      # Xft.dpi handling at all, so nothing auto-detects and the default 96 leaves the UI
      # tiny on a scaled monitor. 96 is 100%; multiply by the monitor scale
      # (e.g. scale 1.6 -> 154, scale 2 -> 192).
      #
      # Runtime-detected rather than baked in, per the portability rule: the same store
      # path has to be right on a 1x desktop and a fractional-scaled laptop. Order is
      # explicit override, then the portable X11 convention, then Windows' default.
      # Xft.dpi is only advisory here — wine ignores it, we translate it.
      dpi="''${PROPNIX_DPI:-}"
      if [ -z "$dpi" ]; then
        dpi=$(xrdb -query 2>/dev/null | sed -n 's/^Xft\.dpi:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
      fi
      dpi="''${dpi:-96}"

      # Applied only when it changes, so a launch costs no extra wine invocation. Keeping
      # it off the prefix-creation path also means PROPNIX_DPI takes effect immediately
      # instead of requiring the prefix to be rebuilt.
      dpistamp="$state/.dpi"
      if [ ! -e "$dpistamp" ] || [ "$(cat "$dpistamp")" != "$dpi" ]; then
        echo "zoom: setting DPI to $dpi (96 = 100%)" >&2
        ( unset DISPLAY WAYLAND_DISPLAY
          wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f \
            >/dev/null 2>&1 || true
          wineserver -w ) || true
        printf '%s' "$dpi" > "$dpistamp"
      fi

      # Zoom keeps its state in %APPDATA%\Zoom inside the writable prefix, so the app tree
      # stays read-only in the store (PLAN2 §7.2). At launch Zoom shows an advisory
      # "unknown publisher" dialog per compat-patched module — accepted as-is; it cannot be
      # cleared without impersonating a public CA or disabling Zoom's own check (RESEARCH §12.2).

      # --- join-by-link convenience ----------------------------------------------------
      # Joining a meeting needs no account, which matters because the sign-in form is the
      # part that does not work (see docs/verified/zoom-arm64.json). On Windows the
      # zoommtg: protocol handler invokes Zoom.exe with --url=%1, so accepting a link
      # directly gives a login-free path straight into a meeting:
      #
      #   zoom 'https://us05web.zoom.us/j/1234567890?pwd=abc'
      #   zoom 'zoommtg://zoom.us/join?action=join&confno=1234567890'
      #
      # Trivial glue, so bash is fine here; anything with real parsing belongs in Rust.
      if [ $# -eq 1 ]; then
        case "$1" in
          zoommtg://*|zoomus://*)
            set -- --url="$1"
            ;;
          https://*zoom.us/j/*|https://*zoom.us/w/*|https://*zoom.us/s/*)
            confno=$(printf '%s' "$1" | sed -n 's|.*/[jws]/\([0-9][0-9]*\).*|\1|p')
            mpwd=$(printf '%s' "$1" | sed -n 's|.*[?&]pwd=\([^&]*\).*|\1|p')
            if [ -n "$confno" ]; then
              u="zoommtg://zoom.us/join?action=join&confno=$confno"
              [ -n "$mpwd" ] && u="$u&pwd=$mpwd"
              echo "zoom: joining meeting $confno without signing in" >&2
              set -- --url="$u"
            fi
            ;;
        esac
      fi

      cd ${unpacked}
      exec wine ./Zoom.exe "$@"
    '';
  };
in
zoom

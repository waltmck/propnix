# emulators/fex-linux — FEX-Emu as a LINUX aarch64 binary that JITs x86_64 and i386 *Linux* ELFs.
# Output: bin/FEX, bin/FEXInterpreter, bin/FEXServer. This is what the THIN `fex` backend runs
# (lib/backends/fex); it is a different build and a different target from emulators/fex, which
# cross-compiles FEX and box64 to *Windows* PE DLLs for wine to load.
#
# WHY IT IS A FORK. Upstream FEX >= 2508 hard-requires a 4 KiB kernel page. This host is Asahi at 16 KiB,
# and Fedora Asahi carries no fix, so stock FEX does not start at all — its bundled jemalloc refuses with
# "Unsupported system page size" before any guest runs. ./patches re-derives every boundary that was using
# the 4 KiB constant as the HOST page from `sysconf(_SC_PAGESIZE)` instead. The guest page stays 4 KiB,
# which is correct: FEX_PAGE_SIZE is the x86 guest's page size and only the host-side uses were wrong.
# One binary is therefore page-size portable across 4/16/32/64 KiB hosts, because the single remaining
# compile-time constant (jemalloc's LG_PAGE) is set to 64 KiB and jemalloc only requires compiled >=
# runtime.
#
# WHAT IT IS FOR, and why it exists now when PLAN2 rejected it. PLAN2 dropped this route as "strictly
# dominated: box64 covers x86_64-Linux guests and wine+FEX covers the JIT-heavy Windows case", leaving it
# as research. That holds until a title needs a **32-bit x86 Linux** guest, which box64 cannot emulate
# (it is x86_64-only) and box86 cannot serve on 16 KiB pages. pkgs/games/civilization-5 is the first such
# title and has no Windows alternative at all — its Windows executable is CEG-stripped and cannot run —
# so i386-linux stops being redundant and becomes the only route.
#
# STATUS, measured on this host with hand-assembled static test guests (one PT_LOAD, no libc, write +
# exit(42), each validated under qemu first):
#   x86_64 guests   5/5 correct
#   i386 guests     correct, and patches/0002 is what made them RELIABLE — before it they passed only
#                   ~2/5 of the time, because the 32-bit-guest allocator picked MAP_FIXED addresses at
#                   4 KiB granularity and three of every four are unmappable on a 16 KiB host.
# Guest Mono/JIT remains a known wall (FEX's self-modifying-code tracking cannot give per-4K permissions
# on a 16K host); that is what keeps the thin FEX backend broken for Unity/Mono titles. It does not affect
# a native C++ guest, which is what this was added for.
#
# Expressed as `pkgs.fex.overrideAttrs` over the exact version nixpkgs pins, rather than vendoring the
# tree: nixpkgs' build machinery (cmake flags, the x86_32/x86_64 guest thunk toolchains, FEXServer) is
# reused unchanged, and the fork stays a reviewable set of patches. The version assert below is the
# tripwire — these patches are cut against one source, so a nixpkgs bump must be looked at rather than
# silently producing a half-patched emulator.
{
  lib,
  fex,
  python3,
  # Cross-built guest glibcs, used ONLY by the install check: their own `getconf` is a real dynamically
  # linked guest of each width, and its PT_INTERP is an absolute store path, so it resolves under
  # FEX_ROOTFS=/ inside the sandbox with no rootfs to assemble.
  pkgsCross,
}:
let
  # Only ./patches keys the patch application (same treatment as emulators/gbe-fork and wine-hangover):
  # editing a patch rebuilds, editing this file's prose does not.
  patchesDir = builtins.path {
    path = ./patches;
    name = "fex-linux-patches";
  };

  # The source these patches were cut against.
  expectedVersion = "2605";
in
lib.throwIf (fex.version or "" != expectedVersion) ''
  emulators/fex-linux: nixpkgs' fex is version ${fex.version or "<unknown>"}, but ./patches is cut
  against ${expectedVersion}. Re-cut them against the new source (and re-run the i386/x86_64 static-guest
  check) rather than loosening this assert — a partially-applied large-host-page patch produces an
  emulator that starts and then faults unpredictably, which is expensive to diagnose.
''
  (
    fex.overrideAttrs (old: {
      pname = "fex-linux";

      # Applied with -p1 in patchPhase, before nixpkgs' own postPatch thunk-path substitutions (disjoint
      # lines, so ordering is safe).
      postPatch = ''
        shopt -s nullglob
        for p in ${patchesDir}/*.patch; do
          echo "applying $(basename "$p")"
          patch -p1 < "$p"
        done
        shopt -u nullglob
      ''
      + (old.postPatch or "");

      doInstallCheck = true;
      # A FEX that cannot execute a guest is the failure mode this package exists to prevent, and it is
      # invisible until a game is launched. Assert it here on all four guest classes — both widths, static
      # and dynamic. i386 is the one that has regressed twice, x86_64 is the control that localises a
      # failure to the 32-bit paths, and the DYNAMIC pair is what patches/0003 exists for: every 32-bit
      # wall so far has been in code a static guest never reaches.
      installCheckPhase = ''
        runHook preInstallCheck
        export FEXTEST=$(mktemp -d)
        python3 ${./tests/mk_hello.py} i386   "$FEXTEST/h32"
        python3 ${./tests/mk_hello.py} x86_64 "$FEXTEST/h64"
        chmod +x "$FEXTEST"/h32 "$FEXTEST"/h64

        # Dynamic guests: each glibc's own getconf, which makes the guest's dynamic linker map a real
        # library set. Their PT_INTERP is an absolute store path, so FEX_ROOTFS=/ resolves it inside the
        # sandbox without building a rootfs.
        for spec in "${pkgsCross.gnu32.glibc.bin}/bin/getconf 32" "${pkgsCross.gnu64.glibc.bin}/bin/getconf 64"; do
          set -- $spec
          guest=$1; want=$2
          [ -x "$guest" ] || { echo "  dynamic $want-bit: SKIP (absent)"; continue; }
          set +e
          got=$(FEX_ROOTFS=/ "$out/bin/FEXInterpreter" "$guest" LONG_BIT 2>&1); rc=$?
          set -e
          echo "  dynamic $want-bit -> exit $rc: $got"
          if [ "$rc" != 0 ] || [ "$got" != "$want" ]; then
            echo "fex-linux: dynamic $want-bit guest failed (exit $rc, output '$got', wanted '$want')" >&2
            exit 1
          fi
        done

        for g in h64 h32; do
          # Each guest exits 42 and prints a line; a plain 0 could arrive by accident.
          # NB: not `out=$(...)` — that would shadow $out and point FEXInterpreter at nothing.
          set +e
          guestout=$("$out/bin/FEXInterpreter" "$FEXTEST/$g" 2>&1); rc=$?
          set -e
          echo "  $g -> exit $rc: $guestout"
          if [ "$rc" != 42 ]; then
            echo "fex-linux: $g guest did not run (exit $rc, wanted 42)" >&2
            exit 1
          fi
        done
        runHook postInstallCheck
      '';

      nativeInstallCheckInputs = (old.nativeInstallCheckInputs or [ ]) ++ [ python3 ];

      passthru = (old.passthru or { }) // {
        # Dependents can assert on the fork rather than hoping they were handed the patched build.
        portableHostPage = true;
        upstreamVersion = expectedVersion;
      };

      meta = (old.meta or { }) // {
        description = "FEX-Emu ${expectedVersion} for Linux x86_64/i386 guests on large-host-page aarch64 (propnix fork)";
      };
    })
  )

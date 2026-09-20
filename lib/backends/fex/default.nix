# backends/fex — the FEX-Emu backend REGISTRY ENTRY (the box64 sibling for Linux content). FEX runs an
# x86 Linux ELF — i386 OR x86_64 — on aarch64 by JITting the guest and honouring the guest's OWN x86
# libraries (no native-library bridging as box64 does), so the whole guest stack is resolved from the
# package set matching the PAYLOAD's ABI and it REUSES the game's `box64.*` library declarations as a pure
# guest union — no options module of its own.
#
# WHICH WIDTH is `cfg.emulatedPlatform`, not the host: i386-linux resolves the guest stack from
# pkgsGuest32 and x86_64-linux from pkgsX86, and each width has its own ELF loader path and its own set of
# FEX thunk libraries. resolveStrategy sends i386-linux here BY DEFAULT (box64 emulates x86_64 only, and
# box86 is dead on 16K pages — lib/strategy.nix); an x86_64-linux payload goes to box64 unless a game asks
# for FEX with `.apply { backend = "fex"; }`.
#
# Three extra needs vs box64:
#  (1) the declared executables' ELF interpreter must point at a guest ld.so that exists under FEX_ROOTFS —
#      GOG/Steam ELFs hard-code /lib64/ld-linux-x86-64.so.2 or /lib/ld-linux.so.2, neither of which exists
#      on a NixOS host — so they are patched in a tiny overlay unioned above the game trees. It has to be a
#      PATCHED COPY AT THE GAME PATH rather than invoking ld.so with the game as an argument: FEX rewrites
#      /proc/self/exe to the program it was GIVEN (FileManagement.cpp), and a game that locates its assets
#      relative to its own binary (Civ V does) then finds nothing.
#  (2) FEX_ROOTFS must be set (unset hangs — RESEARCH §2), pinned to the host root, under which the
#      absolute store-path libraries resolve as guest files. A real rootfs is NOT usable here: FEX
#      re-resolves an absolute symlink target INSIDE the rootfs, so `$ROOT/lib/libc.so.6 →
#      /nix/store/…` becomes `$ROOT/nix/store/…` and fails. Root `/` + explicit library paths, therefore.
#  (3) the GUEST GL stack is FEX's own thunk, not a guest-side Mesa (see `thunks` below).
{
  lib,
  runCommand,
  pkgsX86,
  pkgsGuest32,
  mangohud,
  mkPatchedExes,
  mkThinBuild,
  # nixpkgs FEX-Emu (bin/FEXInterpreter); aarch64-only scope attr, null on x86_64 (FEX emulates x86 ON
  # ARM64 — there is no x86_64-host build, which is what `brokenSystems` below reports).
  fexInterpreter ? null,
}:
{
  modules = [ ]; # reuses box64.* (declared by the box64 entry, which is always imported)

  build =
    {
      cfg,
      enabledDlc,
      executables,
    }:
    let
      inherit (cfg.box64) bridgingLibs guestLibs;
      # The guest ABI, from the PAYLOAD's platform. Everything width-dependent hangs off this one bool.
      is32 = cfg.emulatedPlatform == "i386-linux";
      guestPkgs = if is32 then pkgsGuest32 else pkgsX86;
      # FEX installs a guest thunk per width: GuestThunks_32/ (i386) and GuestThunks/ (x86_64).
      guestThunkDir = if is32 then "GuestThunks_32" else "GuestThunks";
      # Game trees in MOUNT PRIORITY order — DLC first, matching mk-thin-build's list. Used for BOTH the
      # patched exe and the guest library path: taking either from `head cfg.payloads` would silently
      # invert the DLC-first union for a store that ships its expansion as a complete build carrying its
      # own engine binary (Factorio's Space Age).
      gameTrees = enabledDlc ++ cfg.payloads;
      # steam-emu's shim needs no entry here — it is built from source (emulators/gbe-fork) and carries a
      # RUNPATH to every dependency, glibc and libstdc++ included. Mirrors the box64 entry.
      #
      # Both lists are resolved from the SAME guest set, unlike box64's split: FEX bridges nothing, so
      # there is no native side for `bridgingLibs` to name. A game whose only backend is FEX (any i386
      # title) can therefore declare its whole library set under `guestLibs`; one that also runs under
      # box64 keeps the split meaningful and this union still gets it right.
      guestSet = p: (bridgingLibs p) ++ (guestLibs p);
      # ── THE GL THUNK ──────────────────────────────────────────────────────────────────────────────────
      # FEX's answer to graphics is a THUNK, not a guest-side driver: the guest links a tiny
      # `libGL-guest.so` whose calls are marshalled out to the HOST's native GL
      # (lib/fex-emu/HostThunks*/libGL-host.so), so the ARM GPU driver runs host-side at full speed and no
      # x86 Mesa is emulated. The guest thunk ships under its FEX name, so it is staged here under the
      # SONAME a game's loader actually asks for.
      #
      # For a 32-bit guest this is not an optimisation but the only route: there is no i686 Mesa in the
      # guest set (a cross-built Mesa would be an enormous closure), and an i386 guest cannot load the
      # host's aarch64 `libGL.so.1` either.
      #
      # GL + EGL only. FEX builds libwayland-client and libVDSO guest thunks too, but VDSO is FEX's own
      # (loaded internally, never by soname) and wayland-client is left out until a game needs it: staging
      # it would put a Wayland path in front of toolkits that currently reach X11 through libX11 — which
      # FEX does NOT thunk, and which is why an X11 game needs the real guest libX11 in `guestLibs`.
      #
      # `null` when the scope has no FEXInterpreter (x86_64) — like `emulator` below, so that an explicit
      # `.apply { backend = "fex"; }` on a host without FEX is a meta.broken BUILD refusal and not an
      # evaluation failure (lib/strategy.nix's header states that rule; the CI matrix forces every pinned
      # pair on both systems and would report an eval error as a red leg).
      thunks =
        if fexInterpreter == null then
          null
        else
          runCommand "fex-thunks-${if is32 then "i386" else "x86_64"}" { } ''
            mkdir -p $out/lib
            ln -s ${fexInterpreter}/share/fex-emu/${guestThunkDir}/libGL-guest.so $out/lib/libGL.so.1
            ln -s ${fexInterpreter}/share/fex-emu/${guestThunkDir}/libEGL-guest.so $out/lib/libEGL.so.1
          '';
      # Patch the declared executables' ELF interpreter → the guest glibc loader's store path, in a tiny
      # overlay unioned ABOVE the read-only game trees (the store tree can't be patched in place). The
      # bundled .so's need no patch (FEX loads them via LD_LIBRARY_PATH); only an executable carries a
      # PT_INTERP. The copies are made +x, so the generic exec-bit mode-fix is DISABLED (`executables = [ ]`
      # below) — this patched, executable overlay is the highest-priority entry and wins at those paths.
      # Shared with the native face (builders/patched-exes.nix), which needs exactly the same thing with a
      # different loader; `cfg.exe` is included explicitly, and every other declared executable now gets
      # patched too rather than being silently left 0444 by the dropped mode-fix.
      patchedExes = mkPatchedExes {
        name = "fex-${cfg.appid}";
        trees = gameTrees;
        executables = [ cfg.exe ] ++ executables;
        # ld-linux.so.2 for i386, ld-linux-x86-64.so.2 for x86_64 — taken from the guest set's own cc
        # rather than spelled out, so it cannot disagree with the libraries beside it.
        interpreter = guestPkgs.stdenv.cc.bintools.dynamicLinker;
      };
    in
    mkThinBuild {
      inherit cfg enabledDlc executables;
      block = {
        backend = "fex";
        emulator = if fexInterpreter != null then "${fexInterpreter}/bin/FEXInterpreter" else null;
        # Guest libraries, in resolution order: the game trees first in mount-priority order (their
        # bundled .so's — UnityPlayer.so, a shipped OpenAL — win over the system copies, and a DLC's copy
        # wins over the base's just as it does in the union), then FEX's thunks, then the declared guest
        # set. The thunks outrank the guest set deliberately: where both can answer a soname (an x86_64
        # guest listing mesa), the thunk is the one that runs the GPU driver natively.
        # FEX_ROOTFS=/ makes these absolute store paths resolve as guest files on the host.
        ldLibraryPath = lib.concatStringsSep ":" (
          (map (t: "${t}") gameTrees)
          ++ lib.optional (thunks != null) "${thunks}/lib"
          ++ [ (lib.makeLibraryPath (guestSet guestPkgs)) ]
        );
        # FEX_ROOTFS must be set (unset hangs). The game's unified `env` merges OVER it.
        env = {
          FEX_ROOTFS = "/";
        }
        # x87 PRECISION — the app-wide `x87ReducedPrecision` knob in FEX's spelling (that option carries
        # the measurement and the trade). Set on BOTH widths: an i386 guest is where it was measured and
        # where it pays (the i386 ABI computes FP in the x87 stack — Civ V's menu went 59.8% → 24.0% of a
        # core), while an x86_64 guest passes FP in SSE and reaches x87 only for `long double`, so there
        # it is near-free in both directions. Stated for both anyway: one knob means one behaviour to
        # reason about, and a game that needs 80-bit x87 turns it off in one place for every backend.
        // {
          FEX_X87REDUCEDPRECISION = if cfg.x87ReducedPrecision then "1" else "0";
        }
        # `guestPreload` in the guest loader's spelling: FEX runs the REAL guest ld.so, which honours
        # LD_PRELOAD (FEXInterpreter's own aarch64 host link can't load an x86 .so, so the host ld.so
        # reports the ELF-class mismatch and skips it — a warning, not a failure). This is how steam-emu's
        # shim gets in on a FEX build.
        // lib.optionalAttrs (cfg.box64.guestPreload != [ ]) {
          LD_PRELOAD = lib.concatStringsSep ":" cfg.box64.guestPreload;
        }
        // cfg.env;
        mangohud = "${mangohud}";
        # The patched-exe overlay is stacked ABOVE every game tree; no metacopy mode-fix.
        extraLowers = [ "${patchedExes}" ];
        executables = [ ];
        # THE ONE REFUSAL THAT IS THIS BACKEND'S OWN: FEX emulates x86 ON ARM64 and has no x86_64-host
        # build, so on x86_64 there is no emulator to run. Reachable there only by an explicit
        # `.apply { backend = "fex"; }` — resolveStrategy never produces it (x86 Linux content runs
        # natively on that host).
        #
        # NOTHING ENGINE-SPECIFIC BELONGS HERE. Whether FEX can carry a given title is a property of that
        # title's ENGINE, not of the host or the guest width: emulators/fex-linux runs Civ V's native C++
        # engine in-game, while a Mono/JIT engine additionally depends on FEX's self-modifying-code
        # tracking, which is 4 KiB-granular against a 16 KiB host page. So a title that hits such a wall
        # records it in ITS OWN module, conditioned on the backend — pkgs/games/hollow-knight is the
        # worked example (D4: empirical failures are per-title data, not a backend-wide type).
        brokenSystems = [ "x86_64-linux" ];
        brokenReason = "FEX is an x86-on-ARM64 emulator: there is no x86_64-host FEXInterpreter, so the FEX backend has no emulator on x86_64-linux. x86 Linux content runs natively on an x86_64 host (backend \"native\"), which is what resolveStrategy picks there.";
      };
    };
}

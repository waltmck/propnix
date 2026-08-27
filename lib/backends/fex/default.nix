# backends/fex — the FEX-Emu backend REGISTRY ENTRY (the box64 sibling for Linux content). FEX runs an
# x86_64 Linux ELF on aarch64 by JITting the guest and honouring the guest's OWN x86_64 libraries (no
# native-library bridging as box64 does), so the whole guest stack is x86_64 (resolved from pkgsX86) and it
# REUSES the game's `box64.*` library declarations as a pure guest union — no options module of its own.
# Two extra needs vs box64: (1) the main executable's ELF interpreter must point at an x86_64 ld.so that
# exists under FEX_ROOTFS — GOG/Steam ELFs hard-code /lib64/ld-linux-x86-64.so.2, absent on the aarch64
# host — so the declared executables are patched (in a tiny overlay unioned above the game trees);
# (2) FEX_ROOTFS must be set (unset hangs — RESEARCH §2), pinned to the host root, under which the absolute
# x86_64 store-path libraries resolve as guest files.
#
# STATUS — RESEARCH / meta.broken: the THIN FEX path reaches Unity + guest Mono init and then crashes with
# a guest SIGSEGV on a 16K-page host — the Mono JIT relies on FEX's self-modifying-code tracking, which is
# non-functional on 16K (4K-granular mprotect vs a 16K host page), and on sub-host-page mmap emulation.
# Fundamental 16K walls, not tunable; box64 is the WORKING aarch64 thin backend. Carried so a 4K host or a
# future FEX SMC fix flips it on unchanged (`.apply { backend = "fex"; }`), and as the documented wall.
{
  lib,
  pkgsX86,
  mangohud,
  mkPatchedExes,
  mkThinBuild,
  # nixpkgs FEX-Emu (bin/FEXInterpreter); aarch64-only scope attr, null on x86_64 (FEX-thin is aarch64-only).
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
      # Game trees in MOUNT PRIORITY order — DLC first, matching mk-thin-build's list. Used for BOTH the
      # patched exe and the guest library path: taking either from `head cfg.payloads` would silently
      # invert the DLC-first union for a store that ships its expansion as a complete build carrying its
      # own engine binary (Factorio's Space Age).
      gameTrees = enabledDlc ++ cfg.payloads;
      # steam-emu's shim needs no entry here — it is built from source (emulators/gbe-fork) and carries a
      # RUNPATH to every dependency, glibc and libstdc++ included. Mirrors the box64 entry.
      guestSet = p: (bridgingLibs p) ++ (guestLibs p);
      # Patch the declared executables' ELF interpreter → the x86_64 glibc loader's store path, in a tiny
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
        interpreter = "${pkgsX86.glibc}/lib/ld-linux-x86-64.so.2";
      };
    in
    mkThinBuild {
      inherit cfg enabledDlc executables;
      block = {
        backend = "fex";
        emulator = if fexInterpreter != null then "${fexInterpreter}/bin/FEXInterpreter" else null;
        # Guest x86_64 libraries: the game trees first in mount-priority order (their bundled .so's —
        # UnityPlayer.so, the Mono runtime — win over the system copies, and a DLC's copy wins over the
        # base's just as it does in the union), then the declared guest set from pkgsX86. FEX_ROOTFS=/
        # makes these absolute store paths resolve as guest files on the host.
        ldLibraryPath = lib.concatStringsSep ":" (
          (map (t: "${t}") gameTrees) ++ [ (lib.makeLibraryPath (guestSet pkgsX86)) ]
        );
        # FEX_ROOTFS must be set (unset hangs). The game's unified `env` merges OVER it.
        env = {
          FEX_ROOTFS = "/";
        }
        # `guestPreload` in the guest loader's spelling: FEX runs the REAL x86_64 ld.so, which honours
        # LD_PRELOAD (FEXInterpreter's own aarch64 host link can't load the x86_64 .so and ld.so skips it
        # with a warning). Untested — this backend is carried meta.broken — but wired so the knob is never
        # silently dropped by a backend switch.
        // lib.optionalAttrs (cfg.box64.guestPreload != [ ]) {
          LD_PRELOAD = lib.concatStringsSep ":" cfg.box64.guestPreload;
        }
        // cfg.env;
        mangohud = "${mangohud}";
        # The patched-exe overlay is stacked ABOVE every game tree; no metacopy mode-fix.
        extraLowers = [ "${patchedExes}" ];
        executables = [ ];
        # The 16K-page walls (see the STATUS header); carried but not shippable here.
        brokenSystems = [
          "aarch64-linux"
          "x86_64-linux"
        ];
        brokenReason = "FEX THIN path crashes at guest Mono/JIT init on 16K-page aarch64 (non-functional SMC tracking + sub-page mmap emulation — fundamental 16K walls); box64 is the working aarch64 thin backend. Carried for a 4K host / future FEX SMC fix.";
      };
    };
}

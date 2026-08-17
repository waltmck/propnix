# backends/fex — the FEX-Emu backend REGISTRY ENTRY (the box64 sibling for Linux content). FEX runs an
# x86_64 Linux ELF on aarch64 by JITting the guest and honouring the guest's OWN x86_64 libraries (no
# native-library bridging as box64 does), so the whole guest stack is x86_64 (resolved from pkgsX86) and it
# REUSES the game's `box64.*` library declarations as a pure guest union — no options module of its own.
# Two extra needs vs box64: (1) the main executable's ELF interpreter must point at an x86_64 ld.so that
# exists under FEX_ROOTFS — GOG/Steam ELFs hard-code /lib64/ld-linux-x86-64.so.2, absent on the aarch64
# host — so JUST the main exe is patched (in a tiny overlay unioned above the read-only payload);
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
  runCommand,
  patchelf,
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
      inherit (cfg) exe;
      inherit (cfg.box64) bridgingLibs guestLibs;
      primaryTree = builtins.head cfg.payloads;
      guestSet = p: (bridgingLibs p) ++ (guestLibs p);
      # Patch ONLY the main exe's ELF interpreter → the x86_64 glibc loader's store path, in a tiny overlay
      # unioned ABOVE the read-only payload (the store tree can't be patched in place). The bundled .so's
      # need no patch (FEX loads them via LD_LIBRARY_PATH); only the executable carries a PT_INTERP. The
      # copy is made +x here, so the generic exec-bit mode-fix is DISABLED (`executables = [ ]` below) —
      # this patched, executable copy is the highest-priority overlay entry and wins at the exe path.
      patchedExe = runCommand "propnix-fex-exe" { nativeBuildInputs = [ patchelf ]; } ''
        dst="$out/${exe}"
        mkdir -p "$(dirname "$dst")"
        cp --no-preserve=mode "${primaryTree}/${exe}" "$dst"
        chmod u+wx "$dst"
        patchelf --set-interpreter "${pkgsX86.glibc}/lib/ld-linux-x86-64.so.2" "$dst"
      '';
    in
    mkThinBuild {
      inherit cfg enabledDlc executables;
      block = {
        backend = "fex";
        emulator = if fexInterpreter != null then "${fexInterpreter}/bin/FEXInterpreter" else null;
        # Guest x86_64 libraries: the exe-bearing tree first (its bundled .so's — UnityPlayer.so, the Mono
        # runtime — win over the system copies), then the declared guest set from pkgsX86. FEX_ROOTFS=/
        # makes these absolute store paths resolve as guest files on the host.
        ldLibraryPath = lib.concatStringsSep ":" (
          [ "${primaryTree}" ] ++ [ (lib.makeLibraryPath (guestSet pkgsX86)) ]
        );
        # FEX_ROOTFS must be set (unset hangs). The game's unified `env` merges OVER it.
        env = {
          FEX_ROOTFS = "/";
        }
        // cfg.env;
        mangohud = "${mangohud}";
        # The patched-exe overlay is stacked ABOVE the payload (before DLC); no metacopy mode-fix.
        extraLowers = [ "${patchedExe}" ];
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

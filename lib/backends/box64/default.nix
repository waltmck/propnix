# backends/box64 — the box64/native backend REGISTRY ENTRY (Linux content). box64 runs an x86_64 Linux ELF
# on aarch64 by dlopen-bridging the NATIVE host libraries it wraps; when the payload's arch IS the host's
# there is no emulator and the ELF runs directly — so this ONE entry serves both the "box64" and "native"
# registry names (the scope aliases native to it with `modules = [ ]` so the shared option module isn't
# declared twice).
#
# WHICH FACE this entry wears is decided by `cfg.backend` — i.e. by resolveStrategy over the PAYLOAD's
# platform and the host, not by the host alone. That distinction is load-bearing now that the platform axis
# carries `aarch64-linux`: an aarch64 host runs an x86_64 payload under box64 (backend "box64") and an
# aarch64 payload directly (backend "native"), and the two need opposite library unions — the guest
# x86_64 set for the first, the plain host set for the second.
#
# The entry: options.nix declares `box64.*` (the library union, reused by FEX); `build` computes the LAUNCH
# BLOCK — emulator/env/ldLibraryPath — and assembles the package via mkThinBuild → mkThinApp. The library
# union is resolved TWICE for an EMULATED payload (native ∪ x86_64 guest) so the two can't drift (D7); a
# native payload resolves one host-arch set.
{
  lib,
  stdenv,
  pkgs,
  pkgsX86,
  knobTypes,
  strategy, # lib/strategy.nix — `runnable`, for the meta.broken contribution below
  mangohud,
  mkThinBuild,
  mkPatchedExes,
  box64 ? null, # aarch64-only scope attr; null on x86_64 (native, no emulator)
}:
{
  modules = [ (import ./options.nix { inherit lib knobTypes; }) ];

  build =
    {
      cfg,
      enabledDlc,
      executables,
    }:
    let
      # The payload runs DIRECTLY (no emulator) exactly when resolveStrategy said so — which is both faces
      # of "arch matches the host": an x86_64 payload on x86_64, and an aarch64 payload on aarch64.
      isNative = cfg.backend == "native";
      inherit (cfg.box64) bridgingLibs guestLibs guestPreload;
      # NB steam-emu's shim contributes NOTHING here. It used to: upstream's prebuilt gbe_fork release
      # static-linked its dependencies and carried no RUNPATH, so glibc and libstdc++ had to be injected
      # into the launch's library path on its behalf. The shim is now built from source in this repo
      # (emulators/gbe-fork), which makes every dependency its own `buildInputs` — curl, protobuf/abseil,
      # mbedtls, opus, portaudio, and via the stdenv's cc-wrapper glibc and gcc-lib too — all recorded in
      # its RUNPATH. It is self-contained; a parallel list here would only be a copy that can go stale.
      libs =
        if isNative then
          (bridgingLibs pkgs) ++ (guestLibs pkgs)
        else
          (bridgingLibs pkgs) ++ (bridgingLibs pkgsX86) ++ (guestLibs pkgsX86);
      # `guestPreload` in the loader's own spelling: box64's guest loader ignores LD_PRELOAD (and prepends
      # the exe's directory to its search list — nothing weaker interposes), so an emulated payload speaks
      # BOX64_LD_PRELOAD; a native one runs under the real ld.so, so plain LD_PRELOAD. The launcher's
      # PROPNIX_BENCH branch prepends MangoHud's shim to a baked LD_PRELOAD rather than clobbering it
      # (thin.rs), so benching keeps the preload live.
      preloadEnv = lib.optionalAttrs (guestPreload != [ ]) {
        ${if isNative then "LD_PRELOAD" else "BOX64_LD_PRELOAD"} =
          lib.concatStringsSep ":" guestPreload;
      };

      # ── the NATIVE path's ELF interpreter ──────────────────────────────────────────────────────────
      # A native run is a bare execve (thin.rs), so the payload's PT_INTERP must resolve ON THE HOST — and a
      # store ELF from GOG/Steam hard-codes a distro path (/lib/ld-linux-aarch64.so.1,
      # /lib64/ld-linux-x86-64.so.2) that a NixOS host does not have unless `programs.nix-ld` happens to be
      # enabled. Depending on that would make the launch work on the packager's machine and fail elsewhere
      # with a bare ENOENT the launcher can only report as "failed to launch <exe>: No such file or
      # directory" — indistinguishable from a missing executable. So patch it (D12's sanctioned single-exe
      # PT_INTERP exception to D8's never-patchelf rule); mkPatchedExes picks each executable's source tree
      # and the exec bit comes free, which is why the generic metacopy skeleton is switched off below.
      #
      # Gated on `isNative` ALONE, not on `executables != [ ]`: the interpreter is a property of the ELF the
      # launcher execve's, and `executables = [ ]` is a legal value of the option (a payload that already
      # ships +x). Reading it here would silently revert to executing the store ELF with its distro loader
      # path — the exact failure this exists to prevent. `cfg.exe` is always included for the same reason.
      #
      # box64 needs none of this: it IS the loader, ignores PT_INTERP entirely, and reads the ELF without
      # the exec bit — so the emulated face keeps the plain metacopy skeleton and the payload's bytes.
      patchedExes = mkPatchedExes {
        name = cfg.appid;
        # Mount priority order — DLC first, matching mk-thin-build's game-tree list.
        trees = enabledDlc ++ cfg.payloads;
        executables = [ cfg.exe ] ++ executables;
        interpreter = stdenv.cc.bintools.dynamicLinker;
      };
    in
    mkThinBuild {
      inherit cfg enabledDlc executables;
      block = {
        inherit (cfg) backend; # "box64" or "native" — resolveStrategy already decided which face this is
        emulator =
          if isNative then
            null
          else
            assert lib.assertMsg (
              box64 != null
            ) "propnix: box64 backend needs box64 on aarch64, but the scope provided none";
            "${box64}/bin/box64";
        ldLibraryPath = lib.makeLibraryPath libs;
        # box64 seal knobs (emulated payloads only): suppress every rcfile so ~/.box64rc can't change
        # behaviour + PREFER_WRAPPED (all-or-nothing). The game's unified `env` merges OVER these (so it
        # can override).
        env =
          (lib.optionalAttrs (!isNative) {
            BOX64_NORCFILES = "1";
            BOX64_PREFER_WRAPPED = "1";
          })
          // preloadEnv
          // cfg.env;
        mangohud = "${mangohud}";
      }
      # The patched-exe overlay + its metacopy-skeleton handoff — native face only (see `patchedExes`).
      // lib.optionalAttrs isNative {
        extraLowers = [ "${patchedExes}" ];
        executables = [ ];
      }
      # `resolveStrategy` is total over the registry, so an UNRUNNABLE pair (aarch64 content on x86_64 —
      # reachable only by an explicit `.apply { emulatedPlatform = … }`, since the resolver's own walk
      # filters it out) arrives here as an ordinary "native" block. Refuse it at BUILD time, not at eval:
      # the package must still EVALUATE, because the CI matrix forces every pinned pair on BOTH systems and
      # a throw would turn "this host can't run it" into a red leg. Same mechanism the FEX entry uses for
      # its 16K-page brokenness.
      // lib.optionalAttrs (!(strategy.runnable cfg.emulatedPlatform stdenv.hostPlatform.system)) {
        brokenSystems = [ stdenv.hostPlatform.system ];
        brokenReason = "emulatedPlatform '${cfg.emulatedPlatform}' cannot run on ${stdenv.hostPlatform.system} — propnix ships no emulator for that content here (box64 emulates x86 only). Pick a platform this host can run, or drop the explicit `.apply { emulatedPlatform = … }` and let the resolver choose.";
      };
    };
}

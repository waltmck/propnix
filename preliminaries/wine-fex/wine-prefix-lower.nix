# wine-prefix-lower.nix — the read-only system tree, provisioned at BUILD TIME into the nix store (§7.2).
# ("lower" is historical — from the earlier overlay design; it is now the symlink source, not an overlay
# lowerdir.)
#
# A fully-initialized, read-only wine "system" prefix: `wineboot -u` output (system32/syswow64, the
# default registry hives, DLL registration) + the FEX emulator DLLs dropped into system32 + the Wow64
# registry keys that point wine at them. `winefex.nix` symlinks THIS store path's contents directly into
# each per-app prefix — the store is read-only, exactly what winefex wants for the immutable system tree,
# and its store-path hash keys a wine/FEX bump (new path → the next launch relinks to it).
#
# Why build-time (vs. provisioning lazily on first launch):
#   * It removes the entire ~22 s first-launch `wineboot` cost measured in RESEARCH §19 — cold launch
#     then collapses to ≈ warm (prefix assembly is a few dozen symlinks, sub-second).
#   * The prefix is a pure function of (wine, FEX DLLs, this logic) and contains ZERO game content, so it
#     is redistributable and cachix-substitutable: users fetch it prebuilt.
#   * `wineboot` here is NATIVE aarch64 work (it creates dirs, writes the registry, registers DLLs — no
#     x86 code runs, so no FEX JIT and no /dev/kvm), so it runs headless in the Nix build sandbox exactly
#     as nixpkgs already runs wine's own test suite.
#
# Username: the prefix is built for a FIXED user (`wineUser`) and winefex.nix pins USER/LOGNAME to the
# same value at runtime, so the store-built profile (drive_c/users/<wineUser>) is found as-is rather than
# re-created for the (differing) real user. A post-wineboot rename makes this robust regardless of what
# name wineboot picks in the sandbox.
#
# Registry split (§7.2): this tree ships system.reg (HKLM) + userdef.reg (HKU\.Default) but deliberately
# does NOT ship user.reg (HKCU). HKLM/.Default are Admin-only/system hives that games never write, so
# winefex symlinks them READ-ONLY from this store path (wine can't write the 0444 store target; its save
# just drops a discarded file that the next launch relinks). HKCU is per-user state that wine rewrites, and
# a symlinked user.reg would be clobbered by wine's save — so it is removed here and wine regenerates a
# fresh WRITABLE user.reg as a REAL file in the per-app prefix on first launch (~+0.1 s — built-in defaults
# + font list, not a wineboot), where it persists.
#
# Determinism: BIT-REPRODUCIBLE — `nix-store --realise --check` passes. `wineboot` otherwise bakes
# non-deterministic state into the output (wall-clock key timestamps, /dev/urandom GUIDs —
# MachineGuid/MachineId/VideoID/ContainerId — and random `dll*.tmp` DLL-install cruft in system32; the Nix
# sandbox normalizes output-file *mtimes* but not clock/urandom reads during the build). The build pins all
# of it at the end (see the two "Reproducibility" steps below): reg-add a fixed MachineGuid + drop the
# PendingFileRenameOperations queue, a value-name-anchored `sed` that fixes the device GUIDs and normalizes
# every `[Key] <filetime>` / `#time=` stamp, and removal of the `dll*.tmp` cruft. Fixed values are correct
# for every user because the hives are served read-only and games read none of them; faketime is avoided
# (freezing the clock hangs wineboot's internal waits).
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs {
    system = "aarch64-linux";
    config.allowUnfree = true;
  },
  wine ? import ./wine-hangover.nix { inherit nixpkgs pkgs; },
  fexdlls ? import ./fex-dlls.nix { inherit nixpkgs pkgs; },
  wineUser ? "propnix",
}:
pkgs.runCommand "wine-prefix-lower"
  {
    nativeBuildInputs = [
      wine
      pkgs.coreutils
      pkgs.gnused # deterministic post-build normalization of the hives' wall-clock key timestamps
    ];
    inherit wineUser;
    passthru = { inherit wineUser; };
    meta.description = "Read-only wine+FEX system tree (symlinked into each prefix), provisioned in the store";
  }
  ''
    export HOME="$TMPDIR/home" && mkdir -p "$HOME"
    export USER="$wineUser" LOGNAME="$wineUser"
    export WINEPREFIX="$TMPDIR/pfx"
    # Match winefex.nix's runtime env so the store prefix is initialized exactly as it will be used.
    export WINEDLLOVERRIDES="mscoree=b;mshtml=;winemenubuilder.exe=d"
    export WINEDEBUG="-all"

    # Initialize the prefix (native aarch64 wine; headless — no DISPLAY in the sandbox).
    wine wineboot -u

    # Drop the FEX emulator DLLs into system32 and register them as the Wow64 backends:
    #   amd64 = x86_64 guests via ARM64EC (FEX);  x86 = i386 guests (FEX).
    cp -f "${fexdlls}/libarm64ecfex.dll" "${fexdlls}/libwow64fex.dll" \
      "$WINEPREFIX/drive_c/windows/system32/"
    wine reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f
    wine reg add 'HKLM\Software\Microsoft\Wow64\x86'   /ve /d libwow64fex.dll   /f

    # Reproducibility (1/2): pin the values wineboot RANDOMIZES, so two builds are byte-identical
    # (nix-store --realise --check). MachineGuid/MachineId are UUIDs seeded from /dev/urandom;
    # PendingFileRenameOperations is a leftover queue of random dll*.tmp temp names from the DLL install
    # (stale — safe to drop). The hives are served READ-ONLY (§7.2), so fixed values are correct for every
    # user — games don't read these.
    wine reg add 'HKLM\Software\Microsoft\Cryptography' /v MachineGuid /t REG_SZ /d 'b0000000-0000-4000-8000-00000000c0de' /f
    wine reg delete 'HKLM\System\CurrentControlSet\Control\Session Manager' /v PendingFileRenameOperations /f 2>/dev/null || true

    # Cleanly shut the session so the registry is flushed to disk. Bound it so a lingering service can
    # never hang the build; the registry writes above flush within ~2 s so the fallback loses nothing.
    timeout 120 wineserver -w || wineserver -k || true

    # Normalize the profile dir to <wineUser> regardless of the name wineboot chose in the sandbox, so
    # the runtime USER=<wineUser> finds it. (Usually already correct; this makes it robust.)
    users="$WINEPREFIX/drive_c/users"
    if [ ! -e "$users/${wineUser}" ]; then
      for d in "$users"/*; do
        case "$(basename "$d")" in Public) : ;; *) mv "$d" "$users/${wineUser}"; break ;; esac
      done
    fi

    # Drop HKCU (user.reg): winefex symlinks the store's hives read-only, and a symlinked user.reg would be
    # clobbered by wine's save — so HKCU is NOT shipped. wine regenerates a fresh, WRITABLE user.reg as a
    # real file in the per-app prefix on first launch, where the user's settings then persist. HKLM
    # (system.reg, incl. the Wow64/FEX keys above) and HKU\.Default (userdef.reg) stay: symlinked read-only.
    rm -f "$WINEPREFIX/user.reg"

    # Freeze the prefix: the special value `disable` in .update-timestamp tells wine to NEVER auto-run
    # wineboot against this prefix at runtime — correct here since the lower is read-only and already
    # fully provisioned; a wine/FEX bump reprovisions via a NEW store path (mounted fresh next launch), never in-place.
    echo disable > "$WINEPREFIX/.update-timestamp"

    # Reproducibility (2/2): wineboot stamps every registry key with the wall clock — the "[Key] <filetime>"
    # header suffix and the "#time=" lines — the remaining build-to-build drift after the pins above.
    # Normalize them to a constant so the shipped hives are byte-identical across builds. Done LAST (no wine
    # runs after this, so nothing re-stamps them); the key LastWrite time is metadata no game reads.
    # Also pin the synthetic device/machine GUIDs wineboot seeds from /dev/urandom during PnP/display
    # enumeration (MachineId, VideoID, ContainerId). These identify sandbox placeholder devices, not real
    # hardware (wine re-enumerates the host's devices at runtime), and no game reads them — so a fixed
    # value per read-only-served hive is correct. Value-name-anchored so only these lines change.
    for _h in system.reg userdef.reg; do
      sed -i -E '
        s/^(\[.*\]) [0-9]+$/\1 0/
        /^#time=/ s/=.*/=0/
        s/("MachineId"=")[^"]*"/\1a0000000-0000-4000-8000-000000000001"/
        s/("VideoID"=")[^"]*"/\1{a0000000-0000-4000-8000-000000000002}"/
        s/("ContainerId"=")[^"]*"/\1{a0000000-0000-4000-8000-000000000003}"/
      ' "$WINEPREFIX/$_h"
    done
    # Remove wineboot's leftover DLL-install temp files (dll*.tmp in system32). Their PendingFileRename
    # queue is deleted above and wineboot never runs at runtime (.update-timestamp=disable), so they are
    # dead cruft that was always unused — and their random names are the last reproducibility drift.
    find "$WINEPREFIX/drive_c/windows/system32" -maxdepth 1 -name 'dll*.tmp' -delete

    # Publish the finished prefix as the store output — its contents are symlinked verbatim into each
    # per-app prefix as the read-only system tree.
    cp -a "$WINEPREFIX" "$out"
  ''

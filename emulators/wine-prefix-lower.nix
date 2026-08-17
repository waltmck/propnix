# wine-prefix-lower.nix — the read-only system tree, provisioned at BUILD TIME into the nix store (§7.2).
# ("lower" is historical — from the earlier overlay design; it is now the symlink source, not an overlay
# lowerdir.)
#
# A fully-initialized, read-only wine "system" prefix: `wineboot -u` output (system32/syswow64, the
# default registry hives, DLL registration) + the FEX emulator DLLs dropped into system32 + the Wow64
# registry keys that point wine at them. The launcher bind-mounts THIS store path's contents (read-only)
# into each per-app prefix view — the store is read-only, exactly what the bind-mounted prefix wants for
# the immutable system tree, and its store-path hash keys a wine/FEX bump (new path → the next launch rebinds).
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
# Username: the prefix is built for the FIXED user `propnix` and the launcher pins USER/LOGNAME to it at
# runtime, so the store-built profile (drive_c/users/propnix) is found as-is rather than re-created for the
# (differing) real user. A post-wineboot rename makes this robust regardless of what name wineboot picks in
# the sandbox. It is a hardcoded constant (not an option) — game tuning hardcodes `drive_c/users/propnix/…`
# in its save mount targets, and `passthru.wineUser` exposes it as the single source of truth.
#
# Registry split (§7.2): this tree ships system.reg (HKLM) + userdef.reg (HKU\.Default) but deliberately
# does NOT ship user.reg (HKCU). HKLM/.Default are Admin-only/system hives that games never write, so the
# launcher symlinks them READ-ONLY from this store path (wine can't write the 0444 store target; its save
# just drops a discarded file that the next launch relinks). HKCU is per-user state that wine rewrites, and
# a symlinked user.reg would be clobbered by wine's save — so it is removed here and wine regenerates a
# fresh WRITABLE user.reg as a REAL file in the per-app prefix on first launch (~+0.1 s — built-in defaults
# + font list, not a wineboot), where it persists. propnix's HKCU DEFAULTS (e.g. the black pre-render
# window background) are NOT baked here; the launcher re-applies them into user.reg on every launch from a
# configurable attrset (wine-defaults.nix `userReg`), so they always win and update without a reset.
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
  lib,
  runCommand,
  coreutils,
  gnused,
  wine,
  fexdlls ? null, # aarch64: the FEX emulator DLLs to install as the WoW64 backends. x86_64: null (native).
}:
let
  wineUser = "propnix"; # FIXED — not an option; game tuning hardcodes drive_c/users/propnix/…
in
runCommand "wine-prefix-lower"
  {
    nativeBuildInputs = [
      wine
      coreutils
      gnused # deterministic post-build normalization of the hives' wall-clock key timestamps
    ];
    inherit wineUser;
    passthru = { inherit wineUser; };
    meta.description = "Read-only wine+FEX system tree (symlinked into each prefix), provisioned in the store";
  }
  ''
    export HOME="$TMPDIR/home" && mkdir -p "$HOME"
    export USER="$wineUser" LOGNAME="$wineUser"
    export WINEPREFIX="$TMPDIR/pfx"
    # Match the launcher's runtime env so the store prefix is initialized exactly as it will be used.
    export WINEDLLOVERRIDES="mscoree=b;mshtml=;winemenubuilder.exe=d"
    export WINEDEBUG="-all"

    # Initialize the prefix (native wine; headless — no DISPLAY in the sandbox).
    wine wineboot -u

    ${lib.optionalString (fexdlls != null) ''
      # aarch64 ONLY: drop the FEX emulator DLLs into system32 and register them as the WoW64 backends:
      #   amd64 = x86_64 guests via ARM64EC (FEX);  x86 = i386 guests (FEX).
      # On an x86_64 host this whole step is skipped — wine's native WoW64 runs i386, and x86_64 is native.
      #
      # PLUS wowbox64.dll (box64's WoW64 i386 backend). CRITICAL for 32-bit (i386) Windows apps: Hangover's
      # wow64.dll loads the x86 CPU emulator by the HARDCODED name "wowbox64.dll" (a UTF-16 literal in
      # wow64.dll — it does NOT read the `Wow64\x86` registry value below), so an i386 guest aborts at
      # startup with `err:wow:load_64bit_module failed to load dll c0000135` (STATUS_DLL_NOT_FOUND) if it is
      # absent. Homeworld Remastered (and its HW1/HW2 Classic exes) are i386, the first 32-bit title in the
      # suite — every prior game is x86_64 (ARM64EC), which never needed this. box64's wowbox64 is Hangover's
      # DEFAULT i386 emulator; FEX's libwow64fex.dll is the alternative (would work renamed to wowbox64.dll).
      cp -f "${toString fexdlls}/libarm64ecfex.dll" "${toString fexdlls}/libwow64fex.dll" \
        "${toString fexdlls}/wowbox64.dll" \
        "$WINEPREFIX/drive_c/windows/system32/"
      wine reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f
      wine reg add 'HKLM\Software\Microsoft\Wow64\x86'   /ve /d wowbox64.dll      /f
    ''}

    # Populate syswow64 with the i386 (32-bit) builtin modules. `wineboot -u` on this WoW64 build copies the
    # 64-bit/ARM64EC builtins into system32 but leaves syswow64 EMPTY (verified: 0 files), so a 32-bit (i386)
    # guest process dies at startup — `wine: could not load kernel32.dll, status c0000135` — because the
    # loader finds no i386 kernel32/user32/… in the prefix. wine ships every i386 module in
    # ${wine}/lib/wine/i386-windows; symlink the WHOLE set into syswow64 (only where wineboot created nothing,
    # so any fake it did write wins). Symlink EVERY module type, not just `*.dll`: the graphics DRIVERS are
    # `.drv` files (winex11.drv / winewayland.drv), and without them a 32-bit GUI process fails to bind a
    # display driver → `err:winediag:nodrv_CreateWindow ... The explorer process failed to start` and the game
    # aborts windowless. (Also brings the i386 .cpl/.exe/.acm/.ocx/.tlb/.drv16 — the full companion set.)
    # Symlinks resolve inside the launcher's private mount ns (the /nix store stays visible) and point at a
    # fixed store path → still bit-reproducible. Needed by every 32-bit title (Homeworld RM is the first); on
    # x86_64 the same i386 tree feeds native WoW64. Symmetric with the 64-bit system32 wineboot populates.
    for _mod in ${wine}/lib/wine/i386-windows/*; do
      case "$_mod" in *.a) continue ;; esac   # .a = build-time import libs, never loaded at runtime
      _t="$WINEPREFIX/drive_c/windows/syswow64/$(basename "$_mod")"
      [ -e "$_t" ] || ln -s "$_mod" "$_t"
    done

    # Register mmdevapi's MMDeviceEnumerator COM class for the 32-bit (Wow6432Node) view. Same 64-bit-only
    # wineboot gap as syswow64/SxS above: `wineboot -u` populates HKLM\Software\Classes\CLSID (the native
    # arm64ec/64-bit view, 2288 entries) but leaves HKLM\Software\Wow6432Node\Classes\CLSID EMPTY (0 entries),
    # so a 32-bit (i386/WoW64) process's CoCreateInstance(MMDeviceEnumerator) returns REGDB_E_CLASSNOTREG and
    # DirectSound/WASAPI find NO audio endpoint → the app runs MUTE. VERIFIED in Don't Starve (32-bit, FMOD):
    # `err:dsound:get_mmdevenum CoCreateInstance failed: 80040154` (REGDB_E_CLASSNOTREG) → `SoundSystem::
    # Initialize failed`. 64-bit titles are unaffected (their CLSID IS registered). Mirror the 64-bit entry
    # into the 32-bit view; InprocServer32 stays C:\windows\system32\mmdevapi.dll — the WoW64 file redirector
    # resolves system32 → syswow64 (the i386 mmdevapi.dll staged just above) for a 32-bit caller. Audio is the
    # COM class every 32-bit title needs; add other 32-bit builtin classes here should a future title need them.
    _clsid='HKLM\Software\Wow6432Node\Classes\CLSID\{BCDE0395-E52F-467C-8E3D-C4579291692E}'
    wine reg add "$_clsid" /ve /d 'MMDeviceEnumerator class' /f
    wine reg add "$_clsid\\InprocServer32" /ve /d 'C:\windows\system32\mmdevapi.dll' /f
    wine reg add "$_clsid\\InprocServer32" /v ThreadingModel /t REG_SZ /d Both /f

    # Generate the x86 (32-bit) WinSxS assembly manifests + dirs from the arm64 ones. Same 64-bit-only gap as
    # syswow64: `wineboot -u` on this ARM64X hybrid emits SxS manifests ONLY for the arm64 arch (verified:
    # winsxs/manifests has arm64_* but no x86_*). A 32-bit (i386) process that requests a side-by-side
    # assembly — e.g. Homeworld's DCWindow.dll pulls in comdlg32/comctl32, whose DllMain calls CreateActCtx
    # for `Microsoft.Windows.Common-Controls` 6.0 — then FAILS with err 14001 (ERROR_SXS_CANT_GEN_ACTCTX)
    # because there is no x86_ manifest matching the process arch, and DCWindow.dll's init dereferences the
    # resulting uninitialised state → EXCEPTION_ACCESS_VIOLATION before the first frame (reproduced on BOTH
    # box64 and FEX i386 backends). Derive each x86_ variant from the arm64_ one: same manifest with
    # processorArchitecture="x86" (+ the x86_-prefixed filename SxS matches by arch), plus an x86_ assembly
    # dir carrying the i386 build of each DLL (from the i386-windows tree). aarch64 only — on x86_64 wineboot
    # emits the x86_/wow64 manifests itself, so the arm64_ glob is empty here and this is a no-op.
    sxs="$WINEPREFIX/drive_c/windows/winsxs"
    if [ -d "$sxs/manifests" ]; then
      for _m in "$sxs/manifests"/arm64_*.manifest; do
        [ -e "$_m" ] || continue
        _x="$sxs/manifests/$(basename "$_m" | sed 's/^arm64_/x86_/')"
        [ -e "$_x" ] || sed 's/processorArchitecture="arm64"/processorArchitecture="x86"/' "$_m" > "$_x"
      done
      for _d in "$sxs"/arm64_*; do
        [ -d "$_d" ] || continue
        _xd="$sxs/$(basename "$_d" | sed 's/^arm64_/x86_/')"
        mkdir -p "$_xd"
        for _f in "$_d"/*; do
          [ -e "$_f" ] || continue
          _fb="$(basename "$_f")"
          if [ -e "${wine}/lib/wine/i386-windows/$_fb" ] && [ ! -e "$_xd/$_fb" ]; then
            ln -s "${wine}/lib/wine/i386-windows/$_fb" "$_xd/$_fb"
          fi
        done
      done
    fi

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

    # KEEP user.reg (HKCU): it is the BASE for each game's declarative user.reg — mkWineReg applies the
    # game's userReg overrides + display driver on top of it, and the launcher mounts the result as the CoW
    # lower of the root overlay (reads fall back to this store base; the app's writes persist to $STATE). So
    # HKCU is no longer regenerated at runtime — it ships here like system.reg/userdef.reg. (It is normalized
    # for reproducibility alongside the other hives, below.)

    # Freeze the prefix: the special value `disable` in .update-timestamp tells wine to NEVER auto-run
    # wineboot against this prefix at runtime — correct here since the lower is read-only and already
    # fully provisioned; a wine/FEX bump reprovisions via a NEW store path (relinked fresh next launch), never in-place.
    echo disable > "$WINEPREFIX/.update-timestamp"

    # Reproducibility (2/2): wineboot stamps every registry key with the wall clock — the "[Key] <filetime>"
    # header suffix and the "#time=" lines — the remaining build-to-build drift after the pins above.
    # Normalize them to a constant so the shipped hives are byte-identical across builds. Done LAST (no wine
    # runs after this, so nothing re-stamps them); the key LastWrite time is metadata no game reads.
    # Also pin the synthetic device/machine GUIDs wineboot seeds from /dev/urandom during PnP/display
    # enumeration (MachineId, VideoID, ContainerId). These identify sandbox placeholder devices, not real
    # hardware (wine re-enumerates the host's devices at runtime), and no game reads them — so a fixed
    # value per read-only-served hive is correct. Value-name-anchored so only these lines change.
    for _h in system.reg userdef.reg user.reg; do
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

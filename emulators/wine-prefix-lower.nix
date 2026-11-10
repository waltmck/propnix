# wine-prefix-lower.nix — the read-only wine system tree every per-app prefix view bind-mounts,
# provisioned at BUILD TIME into the nix store (§7.2). Its subtrees are mounted individually
# (read-only binds, or the lower of an overlay); it is never one overlay lowerdir as a whole.
#
# A fully-initialized, read-only wine "system" prefix: `wineboot -u` output (system32/syswow64, the
# default registry hives, DLL registration) + the FEX emulator DLLs dropped into system32 + the Wow64
# registry keys that point wine at them + the .NET CLR (Wine Mono) at C:\windows\mono\mono-2.0, which is
# what lets a MANAGED (pure .NET) exe start at all. The launcher bind-mounts THIS store path's contents (read-only)
# into each per-app prefix view — the store is read-only, exactly what the bind-mounted prefix wants for
# the immutable system tree, and its store-path hash keys a wine/FEX bump (new path → the next launch rebinds).
#
# Why build-time (vs. provisioning lazily on first launch):
#   * It removes the first-launch `wineboot` cost (RESEARCH §19); a cold launch ≈ a warm one.
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
# Registry split (§7.2): this tree ships system.reg (HKLM), userdef.reg (HKU\.Default) and user.reg
# (HKCU) as the wine-generated bases. HKLM/.Default are system hives games never write: mkWineReg
# layers each game's systemReg/userdefReg overrides on top and the result is bound READ-ONLY.
# user.reg is the game-agnostic HKCU seed: the wine builder's prefix-root row, a persistent MOUNT of
# `$PROPNIX_STATE/wine/prefix`, names it as its `seed`, so it is copied in when absent. A mount, not
# a bind of the file, because wine saves user.reg via user.reg.tmp + rename(2), and rename over a
# bind-mounted file fails EBUSY. propnix's HKCU defaults (lib/backends/wine/defaults.nix `userReg`)
# are applied at every launch by the launcher's three-way merge, never baked here.
#
# Determinism: BIT-REPRODUCIBLE — `nix-store --realise --check` passes. `wineboot` otherwise bakes
# non-deterministic state into the output (wall-clock key timestamps, /dev/urandom GUIDs —
# MachineGuid/MachineId/VideoID/ContainerId — and random `dll*.tmp` DLL-install cruft; the Nix
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
  # The .NET CLR (emulators/wine-mono), symlinked in at C:\windows\mono\mono-2.0 — see the "MANAGED
  # .NET" step below. `null` ships no CLR, the global opt-out (~219 MiB):
  # `prefixLower.override { wineMono = null; }`. Every MANAGED title then dies at process start.
  wineMono ? null,
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
    meta.description = "Read-only wine+FEX system tree (bind-mounted into each prefix), provisioned in the store";
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
      #   amd64 = x86_64 guests via ARM64EC (FEX);  x86 = i386 guests (box64's wowbox64).
      # On an x86_64 host this whole step is skipped — wine's native WoW64 runs i386, and x86_64 is native.
      #
      # PLUS wowbox64.dll (box64's WoW64 i386 backend, Hangover's default i386 emulator). Hangover's
      # wow64.dll loads the i386 emulator by the hard-coded name `wowbox64.dll` (it ignores the
      # `Wow64\x86` value below), so without it every i386 guest fails at startup with c0000135. See
      # docs/research/wine-prefix-lower.md.
      cp -f "${toString fexdlls}/libarm64ecfex.dll" "${toString fexdlls}/libwow64fex.dll" \
        "${toString fexdlls}/wowbox64.dll" \
        "$WINEPREFIX/drive_c/windows/system32/"
      wine reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f
      wine reg add 'HKLM\Software\Microsoft\Wow64\x86'   /ve /d wowbox64.dll      /f
    ''}

    # Populate syswow64 with the i386 (32-bit) builtin modules: `wineboot -u` on this WoW64 build
    # leaves it empty. Link EVERY i386 module type from wine's lib/wine/i386-windows, not just
    # `*.dll` — including the `.drv` display drivers a 32-bit GUI process needs — wherever wineboot
    # wrote nothing (any fake it did write wins). The symlinks resolve inside the launcher's private
    # mount ns (where /nix is visible) and target fixed store paths, so the tree stays
    # bit-reproducible. On x86_64 the same i386 tree feeds native WoW64. Evidence:
    # docs/research/wine-prefix-lower.md.
    for _mod in ${wine}/lib/wine/i386-windows/*; do
      case "$_mod" in *.a) continue ;; esac   # .a = build-time import libs, never loaded at runtime
      _t="$WINEPREFIX/drive_c/windows/syswow64/$(basename "$_mod")"
      [ -e "$_t" ] || ln -s "$_mod" "$_t"
    done

    # Register mmdevapi's MMDeviceEnumerator COM class for the 32-bit (Wow6432Node) view: wineboot
    # registers it only in the 64-bit CLSID view, so 32-bit DirectSound/WASAPI would find no audio
    # endpoint. InprocServer32 stays C:\windows\system32\mmdevapi.dll — the WoW64 file redirector
    # maps system32 → syswow64 (the i386 mmdevapi.dll staged above) for a 32-bit caller. Audio is
    # the COM class every 32-bit title needs; add other 32-bit builtin classes here should a future
    # title need them.
    _clsid='HKLM\Software\Wow6432Node\Classes\CLSID\{BCDE0395-E52F-467C-8E3D-C4579291692E}'
    wine reg add "$_clsid" /ve /d 'MMDeviceEnumerator class' /f
    wine reg add "$_clsid\\InprocServer32" /ve /d 'C:\windows\system32\mmdevapi.dll' /f
    wine reg add "$_clsid\\InprocServer32" /v ThreadingModel /t REG_SZ /d Both /f

    # Generate the x86 (32-bit) WinSxS assembly manifests + dirs from the arm64 ones: on this ARM64X
    # build wineboot emits only `arm64_` SxS manifests, so a 32-bit CreateActCtx (e.g.
    # Common-Controls 6.0) would fail. Each x86_ variant is the arm64_ manifest with
    # processorArchitecture="x86" (and the x86_-prefixed filename SxS matches by arch), plus an x86_
    # assembly dir carrying the i386 build of each DLL. On x86_64 wineboot emits the x86_ manifests
    # itself, the arm64_ glob is empty and this is a no-op.
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

    ${lib.optionalString (wineMono != null) ''
      # ── MANAGED .NET: install the CLR (Wine Mono) at C:\windows\mono\mono-2.0 ────────────────────────
      # A pure MANAGED exe has a CLR header and no machine code for wine's loader to enter; it hands
      # the image to `mscoree.dll`, which must find a runtime to host or the process dies at start.
      # (Unity *Mono* titles carry their own runtime in the payload and are unaffected.)
      #
      # WHERE. `C:\windows\mono\mono-2.0` is mscoree's FIRST probe (`get_mono_path_local`): it needs
      # no registry value and no path inside the wine package, and being first it cannot be
      # shadowed. mscoree derives mono's lib/ and etc/ roots from the path it found, so `$out` of
      # wine-mono must BE the runtime root, symlinked verbatim. The full probe order:
      # docs/research/wine-mono-clr-in-prefix.md.
      #
      # SYMLINK, NOT COPY, and that is load-bearing twice over:
      #   * the store path stays a SEPARATE closure entry, so this tree's own NAR does not grow by 219 MiB
      #     and a mono bump does not re-push the whole prefix;
      #   * propnix-prefetch "never recurses THROUGH a symlink"
      #     (pkgs/propnix-prefetch/src/prefetch.rs), and a symlink whose target is a DIRECTORY is
      #     neither warmed nor descended — so the launcher's start-up walk
      #     (`warm(&[view], &["dll","drv","exe"])`, run for EVERY wine title) does not gain mono's
      #     managed .dll/.exe files, which would otherwise outnumber this tree's own PE modules, for
      #     titles that never load a byte of them.
      # Same reasoning as the syswow64 symlinks above: it resolves inside the launcher's private
      # mount ns, where /nix is visible, and it points at a fixed store path so this build stays
      # bit-reproducible.
      mkdir -p "$WINEPREFIX/drive_c/windows/mono"
      ln -s ${wineMono} "$WINEPREFIX/drive_c/windows/mono/mono-2.0"

      # Prove the drop landed where mscoree looks, HERE rather than at launch: `find_mono_dll()` probes
      # `<path>\bin\libmono-2.0-<arch>.dll` and picks <arch> from the arch mscoree ITSELF was built for —
      # `-x86` for i386, `-x86_64` for x86_64 AND for ARM64EC (wine's own `include/winnt.h:8076`,
      # `#if defined(__x86_64__) && !defined(__arm64ec__)`, establishes that an arm64ec compile defines
      # `__x86_64__`; an x86_64 guest on aarch64 IS arm64ec). Both are the same two files on both hosts.
      for _core in libmono-2.0-x86.dll libmono-2.0-x86_64.dll; do
        [ -f "$WINEPREFIX/drive_c/windows/mono/mono-2.0/bin/$_core" ] \
          || { echo "propnix: CLR drop failed — mono-2.0/bin/$_core is not readable in the prefix"; exit 1; }
      done

      # Installed AFTER `wineboot -u` on purpose: if mscoree's DllRegisterServer (reached by
      # wine.inf's RegisterDlls) found a runtime, it would run winemono-support.msi. That differs by
      # arch (the native arm64 mscoree finds no arm64 libmono, so it would install on x86_64 only),
      # runs x86 PEs under FEX inside the sandbox, and bakes MSI install state into a tree that must
      # stay bit-reproducible. The registry facts it would write are declared below instead,
      # identically on both arches. Details: docs/research/wine-mono-clr-in-prefix.md.

      # The .NET Framework 4.x VERSION-DETECTION keys, transcribed from the Registry table of the support
      # package we are deliberately not running (`msiinfo export winemono-support.msi Registry`; the rows
      # named NDP4*/DotNetFrameworkPolicy40, which are byte-identical between its 32- and 64-bit
      # components). These are what a `.NETFramework,Version=v4.x` target probes to decide the framework is
      # present — Release >= 394254 is the documented ".NET 4.6.1 or later" test, and 533320 clears it.
      # NOT the CLR discovery path: `get_mono_path_local` above needs no registry at all, so nothing here is
      # required to START a managed exe; this is purely so a title that ASKS gets upstream's own answer.
      # Written into BOTH registry views because HKLM\Software is WoW64-redirected — a 32-bit (i386) process
      # reads Wow6432Node, the same 64-bit-only-wineboot gap the mmdevapi CLSID mirror above exists for.
      # Deliberately scoped to v4: the support package also claims v1.1/v2.0/v3.0/v3.5, but no title in the
      # suite targets those, and every value here is a claim we should be able to point at a title for. Add
      # them from the same table if one ever needs the probe to succeed.
      # NOT written: `Software\Microsoft\.NETFramework\InstallRoot`. Upstream points it at a
      # Framework tree only the support package populates; an empty root makes `LoadLibraryShim()`
      # fail outright, whereas unset falls back to the normal search path.
      #
      # ONE `reg import`, not 28 `reg add` round-trips against wineserver.
      #
      # The heredoc below reaches the shell UNINDENTED — Nix strips the common leading indentation of an
      # indented-string block, and 6 spaces is the minimum in this one — which is what both the `.reg`
      # parser (key lines must start at column 0) and the `EOF` terminator need. Should a future edit ever
      # put a line here at a SHALLOWER indent, the stripping shrinks and the terminator stops matching:
      # that is a hard "unexpected EOF" build failure, not a silent misparse.
      cat > "$WINEPREFIX/drive_c/dotnet-ndp.reg" <<'EOF'
      Windows Registry Editor Version 5.00

      [HKEY_LOCAL_MACHINE\Software\Microsoft\.NETFramework\policy\v4.0]
      "30319"="30319-30319"

      [HKEY_LOCAL_MACHINE\Software\Microsoft\NET Framework Setup\NDP\v4\Client]
      "Install"=dword:00000001
      "Release"=dword:00082348
      "Version"="4.7.03190"
      "TargetVersion"="4.0.0"
      "Servicing"=dword:00000000

      [HKEY_LOCAL_MACHINE\Software\Microsoft\NET Framework Setup\NDP\v4\Full]
      "Install"=dword:00000001
      "Release"=dword:00082348
      "Version"="4.7.03190"
      "TargetVersion"="4.0.0"
      "Servicing"=dword:00000000

      [HKEY_LOCAL_MACHINE\Software\Microsoft\NET Framework Setup\NDP\v4\Full\1033]
      "Install"=dword:00000001
      "Release"=dword:00082348
      "Servicing"=dword:00000000

      [HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\.NETFramework\policy\v4.0]
      "30319"="30319-30319"

      [HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4\Client]
      "Install"=dword:00000001
      "Release"=dword:00082348
      "Version"="4.7.03190"
      "TargetVersion"="4.0.0"
      "Servicing"=dword:00000000

      [HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4\Full]
      "Install"=dword:00000001
      "Release"=dword:00082348
      "Version"="4.7.03190"
      "TargetVersion"="4.0.0"
      "Servicing"=dword:00000000

      [HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4\Full\1033]
      "Install"=dword:00000001
      "Release"=dword:00082348
      "Servicing"=dword:00000000
      EOF
      wine reg import 'C:\dotnet-ndp.reg'
      rm -f "$WINEPREFIX/drive_c/dotnet-ndp.reg"
    ''}

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

    # KEEP user.reg (HKCU): it is the game-agnostic HKCU seed, copied into each app's persistent
    # prefix root mount (`$PROPNIX_STATE/wine/prefix`) through that row's `seed`; propnix's HKCU
    # overrides are applied at launch by the three-way merge, never baked. (Normalized for
    # reproducibility alongside the other hives, below.)

    # Freeze the prefix: the special value `disable` in .update-timestamp tells wine to NEVER
    # auto-run wineboot against this prefix at runtime — correct here since the tree is read-only
    # and already fully provisioned; a wine/FEX bump reprovisions via a NEW store path (bind-mounted
    # fresh next launch), never in-place.
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
    # Remove wineboot's leftover DLL-install temp files (dll*.tmp). Their PendingFileRename queue is deleted
    # above and wineboot never runs at runtime (.update-timestamp=disable), so they are dead cruft that was
    # always unused — and their random names are the last reproducibility drift.
    #
    # wineboot leaves them across the whole windows tree (syswow64, resources/themes), so sweep it
    # all. `find` does not follow symlinks, so the mono runtime symlinked in above is a leaf here
    # and never walked.
    find "$WINEPREFIX/drive_c/windows" -name 'dll*.tmp' -delete

    # Publish the finished prefix as the store output — its subtrees are bind-mounted into each
    # per-app prefix view as the read-only system tree.
    cp -a "$WINEPREFIX" "$out"
  ''

# wine-mono.nix — the .NET CLR wine hosts for MANAGED Windows titles, as a store tree ready to be dropped
# into a prefix at `C:\windows\mono\mono-2.0`.
#
# WHY THIS EXISTS. A "managed" (pure .NET) exe carries a CLR header and — for a modern C# build — NO import
# table at all; nothing in it is machine code the wine loader can enter. Windows' loader special-cases such
# an image and hands it to the CLR; wine does the same through `mscoree.dll`, which must find a real runtime
# to host. Ship none and every managed title dies at process start before a single frame. Space Engineers is
# the first such title in the suite (`Bin64/SpaceEngineers.exe`: 2 sections, no imports, CLR v4.0.30319,
# `.config` pinning `.NETFramework,Version=v4.6.1`); KSP/Iron Lung/Hollow Knight are Unity *Mono* builds that
# carry their OWN runtime inside the payload and therefore never needed one from the prefix.
#
# WHICH RUNTIME, AND WHY THE TARBALL. Wine Mono is the runtime wine itself installs — the version is compiled
# INTO wine (`dlls/mscoree/mscoree_private.h: #define WINE_MONO_VERSION "11.2.0"` in the pinned Hangover
# 11.15 tree), so it is not a free choice; it is a property of the wine we build. nixpkgs pins the SAME
# upstream release (`pkgs/applications/emulators/wine/sources.nix`, `unstable.mono` = wine-mono 11.2.0,
# reachable as `pkgs.wineWow64Packages.unstable.src.mono`) but only as the `-x86.msi` ARTIFACT, which cannot
# be unpacked without running an installer inside a prefix; and nixpkgs' `embedInstallers` merely SYMLINKS
# that .msi into `$out/share/wine/mono/`, which is the path wine's appwiz downloader consumes, NOT a runtime
# `mscoree` can load. Upstream ships the same release as `-x86.tar.xz` precisely for "extract it into the
# prefix" — deterministic, no installer, no msiexec in the sandbox — so that is what we pin here (a plain
# `fetchurl` with a pinned hash, the same kind of pin nixpkgs' own entry is).
#
# ONE PACKAGE COVERS BOTH ARCHES. The tarball's `bin/` holds exactly two native cores — `libmono-2.0-x86.dll`
# and `libmono-2.0-x86_64.dll` (verified against the 11.2.0 tarball) — and `dlls/mscoree/metahost.c`'s
# `find_mono_dll()` picks by the arch mscoree ITSELF was built for:
#   `#ifdef __i386__ … -x86.dll  #elif defined(__x86_64__) … -x86_64.dll  #elif defined(__aarch64__) … -arm64.dll`
# On x86_64-linux both mscoree flavours (native + WoW64/i386) hit the two DLLs we ship. On aarch64 the guest
# is emulated, never native ARM: an x86_64 guest runs as ARM64EC, and wine's own headers establish that the
# arm64ec compile defines `__x86_64__` (`include/winnt.h:8076: #if defined(__x86_64__) && !defined(__arm64ec__)`
# — the guard would be pointless otherwise), so the ARM64EC mscoree also asks for `libmono-2.0-x86_64.dll` and
# runs it through FEX; an i386 guest asks for `-x86.dll`. Hangover reaches the same conclusion from the other
# end — its tip commit is literally "appwiz.cpl: Autoinstall x86 mono on ARM64", and `dlls/appwiz.cpl/addons.c`
# in the pinned tree reads `#if defined(__i386__) || defined(__x86_64__) || defined(__aarch64__)` →
# `MONO_ARCH "x86"`. There is no arm64 build of wine-mono 11.2.0 to ship even if we wanted one (the release
# directory carries only `-x86.msi` / `-x86.tar.xz` / `-src` / `-dbgsym` / `-tests`).
{
  lib,
  runCommand,
  fetchurl,
  coreutils,
  gnutar,
  xz,
  wine, # only to CHECK the version against the wine we ship; nothing from it is installed
}:
let
  # MUST equal the wine we build against. See the guard below — it is not advisory.
  version = "11.2.0";
in
runCommand "wine-mono-${version}"
  {
    src = fetchurl {
      url = "https://dl.winehq.org/wine/wine-mono/${version}/wine-mono-${version}-x86.tar.xz";
      hash = "sha256-yfsuKCOs8wsAC4gGF32w9AdReGE23T+Psr54l7FkPQY=";
    };
    nativeBuildInputs = [
      coreutils
      gnutar
      xz
    ];
    passthru = { inherit version; };
    meta = {
      description = "Wine Mono ${version} — the .NET CLR wine hosts for managed Windows executables";
      homepage = "https://gitlab.winehq.org/mono/wine-mono";
      license = lib.licenses.mit; # MIT (Mono) + LGPL21 parts; see the tarball's own LICENSE files
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  }
  ''
    mkdir -p "$out"
    # The tarball unpacks to a single `wine-mono-<version>/` dir holding bin/ etc/ lib/ support/. Strip that
    # component so `$out` IS the runtime root — i.e. exactly what wine expects to find AT
    # `C:\windows\mono\mono-2.0`, so the consumer symlinks `$out` there with no path arithmetic.
    tar -xJf "$src" -C "$out" --strip-components=1

    # ── Guards. Each of these is a silent-breakage mode, so make it a build failure instead. ──

    # 1. The two native cores `find_mono_dll()` looks for (see the header). Without them mscoree finds a
    #    directory but no runtime, falls through every other search path, and ends at the appwiz downloader —
    #    which, offline, means the managed title dies exactly as it does with no mono at all.
    for _core in bin/libmono-2.0-x86.dll bin/libmono-2.0-x86_64.dll; do
      [ -f "$out/$_core" ] || { echo "propnix: wine-mono ${version} is missing $_core"; exit 1; }
    done

    # 2. The Windows-support package. Not installed here (see wine-prefix-lower.nix for why the .NET
    #    registry facts are written declaratively instead), but its ABSENCE would mean the tarball layout
    #    changed under us, which is worth knowing at build time rather than at launch.
    [ -f "$out/support/winemono-support.msi" ] \
      || { echo "propnix: wine-mono ${version} is missing support/winemono-support.msi"; exit 1; }

    # 3. THE VERSION MUST MATCH THE WINE WE SHIP. `mscoree` hardcodes `WINE_MONO_VERSION` and uses it to
    #    reject a support package older than itself (`mscoree_main.c: compare_versions(WINE_MONO_VERSION,
    #    versionstringbuf) <= 0`) and to name the datadir it searches (`metahost.c: L"\\wine-mono-"
    #    WINE_MONO_VERSION`). A wine bump that moves that constant must move this pin too — otherwise the
    #    prefix silently ships a runtime wine no longer considers current. Read it back out of the BUILT
    #    builtin rather than the wine source tree (the source is not a runtime input, and every arch's
    #    mscoree.dll carries the constant as a UTF-16 literal — `metahost.c`'s
    #    `basedir[] = L"\\wine-mono-" WINE_MONO_VERSION`; strip the NULs to match it as ASCII).
    # (Via a temp file, not `tr … | grep -q`: `grep -q` exits at the first hit, `tr` then dies of SIGPIPE,
    # and stdenv's `set -o pipefail` would report the whole pipeline as failed even on a MATCH.)
    _found=""
    for _m in ${wine}/lib/wine/*/mscoree.dll; do
      [ -e "$_m" ] || continue
      tr -d '\000' < "$_m" > "$TMPDIR/mscoree.strings"
      if grep -qa "wine-mono-${version}" "$TMPDIR/mscoree.strings"; then _found=yes; fi
    done
    [ -n "$_found" ] || {
      echo "propnix: none of ${wine}/lib/wine/*/mscoree.dll names wine-mono-${version}."
      echo "         The pinned wine expects a DIFFERENT WINE_MONO_VERSION — bump \`version\` + \`hash\`"
      echo "         in emulators/wine-mono.nix to whatever dlls/mscoree/mscoree_private.h now says."
      exit 1
    }
  ''

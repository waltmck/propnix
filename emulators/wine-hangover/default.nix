# wine-wow64 rebuilt as ARM64X *hybrid* so it can host x86_64 (ARM64EC) Windows processes — from
# HANGOVER'S WINE FORK, built by us.
#
# WHY THE FORK (not nixpkgs wine + cherry-picked patches): Hangover (AndreRH/hangover) is a superproject
# whose `wine` submodule is AndreRH/wine branch `arm64ec` = **upstream wine 11.15 + Hangover's ~10
# ARM64EC/WoW64 commits, as one coherent tree**. That glue (WoW64 thread-suspension via the BT module,
# HODLL emulator-DLL defaults, high-VA host allocations, mono autoinstall) is what makes the ARM64X-hybrid
# core DLLs actually *host* an x86_64 (ARM64EC) process under FEX. It is NOT wine-staging.
#   We previously tried replaying just those ~10 commits onto nixpkgs' wine-staging **11.12**; that broke
#   at compile (`dlls/wow64/process.c` calling `RtlWow64SuspendThread`, whose declaration + ntdll.spec
#   export are part of the upstream **11.15** baseline the commits assume — RESEARCH §22). Rather than
#   hand-reconstruct 11.15 on an 11.12 base, we build the fork's coherent 11.15 tree directly — exactly
#   what Hangover ships and tests.
#
# We reuse nixpkgs `wineWow64Packages.unstable` only for its build machinery (llvm-mingw PE cross-compile,
# WoW64 wiring, the full X/GStreamer/... buildInputs) and override:
#   1. `src` → the pinned AndreRH/wine `arm64ec` commit (has a checked-in ./configure, so no autoreconf).
#   2. `--enable-archs` → ARCH-DEPENDENT (see below).
#   3. `dontStrip` → on aarch64 only (the ARM64X load-config must survive; § below).
#   4. `gstreamerSupport = true` — Media Foundation decode backend (RESEARCH §18): winegstreamer.dll
#      registers the MF byte-stream-handler classes, so HK's cinematic AUDIO decodes (video still absent,
#      a wine 11 MF video-pipeline limitation, not a codec gap). Kept for MF generally.
#   5. `patches += ./patches/0001-wine-thread-stack-guard-headroom.patch` — restore the bottom guard-page overhead
#      (2 * host_page_size) ON TOP of a thread's reserve in `virtual_alloc_thread_stack`, so the USABLE
#      stack matches the requested reserve regardless of host page size. On 16K-page hosts (Asahi) the
#      guard costs 32K vs 8K on 4K, silently shrinking every thread's usable stack by ~24K — which tips
#      tightly-sized Unity/Mono JIT worker threads into a stack overflow under FEX emulation (root-caused
#      via a KSP crash A/B: patched 0/17 vs baseline 3/17). Harmless on 4K hosts (+8K/thread), so it is
#      applied on both arches (keeping the wine identical across them).
# nixpkgs' own `cert-path.patch` (NixOS cacert path) is kept, plus the stack patch above; the fork carries
# all the ARM64EC/WoW64 glue itself.
#
# SAME WINE ON BOTH ARCHES (max compatibility; the only difference is arm64ec-specific):
#   * aarch64-linux host: `--enable-archs=arm64ec,aarch64,x86_64,i386` → ARM64X-hybrid core DLLs that can
#     HOST an x86_64 (ARM64EC) process under FEX. This is the winefex path.
#   * x86_64-linux host: `--enable-archs=x86_64,i386` → a standard WoW64 wine from the SAME source; the
#     Hangover ARM64EC/WoW64 commits are inert (they only add the arm64ec arch), so this is upstream wine
#     11.15 behaviour. x86_64 Windows code runs NATIVELY — no FEX, no ARM64EC. Building the same source
#     (rather than nixpkgs' wine) guarantees identical wine across arches, which is the whole point.
#
# dontStrip rationale (aarch64 only): stripping the ARM64X PE DLLs (ntdll/kernel32/…) drops sections and
# invalidates the load-config's DynamicValueRelocTableSection index, so wine's update_arm64x_mapping()
# never rewrites the header machine ARM64->AMD64 for the EC view → STATUS_NOT_SUPPORTED (0xc00000bb)
# loading ntdll for any x86_64 process. On x86_64 there is no ARM64X load-config, so stripping is standard.
{
  lib,
  stdenv,
  fetchFromGitHub,
  wineWow64Packages,
  # The ARM64EC toolchain, aarch64 only (absent from the scope on x86_64, where nixpkgs uses its
  # pkgsCross mingw gccs instead). See the substitution below for why we override nixpkgs' copy.
  llvmMingw ? null,
}:
let
  isAarch64 = stdenv.hostPlatform.isAarch64;
  # arm64ec is only meaningful (and only needed) when the HOST is ARM64 and must emulate x86_64.
  archs = if isAarch64 then "arm64ec,aarch64,x86_64,i386" else "x86_64,i386";

  # Hangover's wine, pinned. `arm64ec` HEAD as of 2026-08-09 (upstream wine 11.15 + Hangover commits;
  # tip commit "appwiz.cpl: Autoinstall x86 mono on ARM64"). Bump = new rev + re-hash (and re-run the
  # 16K-page HK boot test — some wine+FEX combos stack-overflow on 16K, RESEARCH §22).
  hangoverWineRev = "1c9ef214bd8c6134d971d903e0a33d8c0b745e84";
  hangoverWineSrc = fetchFromGitHub {
    owner = "AndreRH";
    repo = "wine";
    rev = hangoverWineRev;
    sha256 = "1a0icm3m0z14k8fk01k16nd5dsnzmvphi0m6d5n93p1ks83759m8";
  };

  # Every file under ./patches becomes a wine patch — drop a `NNNN-name.patch` in to add one, delete it to
  # remove it; no code change. Files are applied in NUMERIC-PREFIX order (0001-, 0002-, …) via naturalSort,
  # so ordering is controlled by the filename. `builtins.path` pins the dir to a CONTENT-ADDRESSED store path
  # (keyed only by the patches' bytes, not the flake source), so unrelated repo edits never perturb this
  # ~1 h wine build — only touching ./patches does.
  patchesDir = builtins.path {
    path = ./patches;
    name = "wine-hangover-patches";
  };
  extraPatches = map (f: "${patchesDir}/${f}") (
    lib.naturalSort (builtins.attrNames (builtins.readDir patchesDir))
  );
in
(wineWow64Packages.unstable.override { gstreamerSupport = true; }).overrideAttrs (old: {
  pname = "wine-hangover";
  version = "11.15" + lib.optionalString isAarch64 "-arm64ec";
  src = hangoverWineSrc;

  # Set --enable-archs per host arch (nixpkgs' default is aarch64,x86_64,i386).
  configureFlags = map (
    f: if lib.hasPrefix "--enable-archs=" f then "--enable-archs=${archs}" else f
  ) old.configureFlags;

  # Keep nixpkgs' patches (cert-path.patch) + everything under ./patches (currently the thread-stack
  # guard-headroom fix, header §5); the fork supplies all ARM64EC/WoW64 glue itself. (No `import
  # ./wine-patches` — the cherry-pick-onto-11.12 approach is retired.)
  patches = (old.patches or [ ]) ++ extraPatches;

  dontStrip = isAarch64;

  # ONE ARM64EC TOOLCHAIN FOR THE WHOLE TREE. On aarch64 nixpkgs builds wine with its OWN copy of
  # mstorsjo's llvm-mingw — a `let` binding in its packages.nix, reachable neither by `.override`
  # (that only sees wine/default.nix's args) nor by an overlay (it is not a top-level attr). So swap
  # it out here, in nativeBuildInputs. Same upstream tarball either way; ours adds the reindex-ar fix
  # (emulators/llvm-mingw) and a pin we control. Without this the tree compiles wine with one LLVM and
  # DXVK/vkd3d/FEX with another, and a toolchain bump aimed at wine does nothing to wine.
  #
  # The assert is the point: if nixpkgs ever renames or drops that input, this must fail loudly rather
  # than quietly go back to building wine with a toolchain we are not pinning.
  nativeBuildInputs =
    let
      inputs = old.nativeBuildInputs or [ ];
      isTheirs = d: lib.hasPrefix "llvm-mingw" (d.pname or "");
      hits = lib.length (lib.filter isTheirs inputs);
    in
    assert isAarch64 -> hits == 1;
    map (d: if isTheirs d then llvmMingw else d) inputs;
})

# vkd3d-proton-x86_64.nix — vkd3d-proton (D3D12 → Vulkan) for the x86_64-linux host, as x86_64 PE DLLs.
#
# The x86_64 sibling of vkd3d-proton-arm64ec.nix. On x86_64 wine runs the game natively, so vkd3d is just
# the standard x86_64 Windows build. We reuse nixpkgs' `pkgsCross.mingw-msvcrt-x86_64.vkd3d-proton`
# cross build, with two overrides:
#   * stdenv → the WIN32 THREAD MODEL (exactly as nixpkgs' `dxvk` does), so the PE DLLs carry no
#     libwinpthread dependency.
#   * wine → `wine64Packages.minimal` (widl only). vkd3d-proton needs wine's `widl` at build; the DEFAULT
#     `wine` is the full multiarch build, whose 32-bit `wine32 = pkgsi686Linux.callPackage …` throws in the
#     mingw (Windows, non-Linux) host context. A 64-bit-only wine provides `widl` without touching
#     pkgsi686Linux — the same trick vkd3d-proton-arm64ec.nix uses.
# Then flatten `d3d12.dll` + `d3d12core.dll` to `$out/<dll>.dll` — the SAME layout the ARM64EC build
# produces, so the launcher's prefix assembly is identical across arches. (vkd3d reuses DXVK's dxgi.)
#
# NOTE: unbuilt/untested (no x86_64 builder here); correct-by-construction and it evaluates.
{
  runCommand,
  pkgsCross,
  wine64Packages,
}:
let
  # Match nixpkgs' DXVK recipe: GCC's thread library is now a package (or null), not a
  # { model; package; } record. Overlay the cross set so every compiler stage uses win32 threads.
  mingw = pkgsCross.mingw-msvcrt-x86_64.appendOverlays [
    (_final: _prev: { threads = null; })
  ];

  vkd3d64 =
    (mingw.vkd3d-proton.override {
      wine = wine64Packages.minimal; # widl only; 64-bit → avoids the pkgsi686Linux (windows-host) throw
    }).overrideAttrs
      (old: {
        # winpthreads: meson's dependency('threads') puts `-pthread` on the link line, and the win32
        # thread-model toolchain ships no libpthread.a of its own — the link fails with "cannot find
        # -lpthread". nixpkgs' dxvk adds exactly this buildInput for Windows hosts
        # (`++ lib.optionals hostPlatform.isWindows [ windows.pthreads ]`);
        # nixpkgs' vkd3d-proton — never cross-built by Hydra — misses it. The STATIC archive
        # (pthreads.nix: withStatic default) satisfies the `-static` link with no runtime DLL dep.
        buildInputs = (old.buildInputs or [ ]) ++ [ mingw.windows.pthreads ];
        # vkd3d-proton inherits meta.platforms from `wine`; the 64-bit-Linux wine we substituted excludes
        # the x86_64-windows host this PE build targets. Restore it so checkMeta accepts the cross build.
        meta = (old.meta or { }) // {
          platforms = (old.meta.platforms or [ ]) ++ [ "x86_64-windows" ];
        };
      });
in
runCommand "vkd3d-proton-x86_64-${vkd3d64.version or "2"}" {
  meta.description = "vkd3d-proton (D3D12 → Vulkan) x86_64 PE DLLs (mingwW64, win32 threads), flattened for the propnix launcher";
} ''
  mkdir -p "$out"
  for d in d3d12 d3d12core; do
    f="$(find ${vkd3d64} -name "$d.dll" -print -quit)"
    if [ -n "$f" ]; then install -m444 "$f" "$out/$d.dll"; else echo "WARN: $d.dll not built"; fi
  done
''

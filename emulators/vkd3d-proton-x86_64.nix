# vkd3d-proton-x86_64.nix — vkd3d-proton (D3D12 → Vulkan) for the x86_64-linux host, as x86_64 PE DLLs.
#
# The x86_64 sibling of vkd3d-proton-arm64ec.nix. On x86_64 wine runs the game natively, so vkd3d is just
# the standard x86_64 Windows build. We reuse nixpkgs' `pkgsCross.mingwW64.vkd3d-proton` cross build, with
# two overrides:
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
  overrideCC,
  wine64Packages,
}:
let
  # Build mingw with the win32 thread model (no winpthreads runtime dep) — nixpkgs' own dxvk recipe.
  useWin32ThreadModel =
    stdenv:
    overrideCC stdenv (
      stdenv.cc.override (old: {
        cc = old.cc.override {
          threadsCross = {
            model = "win32";
            package = null;
          };
        };
      })
    );

  vkd3d64 =
    (pkgsCross.mingwW64.vkd3d-proton.override {
      stdenv = useWin32ThreadModel pkgsCross.mingwW64.stdenv;
      wine = wine64Packages.minimal; # widl only; 64-bit → avoids the pkgsi686Linux (windows-host) throw
    }).overrideAttrs
      (old: {
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

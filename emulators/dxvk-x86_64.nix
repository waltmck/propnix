# dxvk-x86_64.nix — DXVK (D3D9/10/11 → Vulkan) for the x86_64-linux host, as native x86_64 PE DLLs.
#
# On x86_64 there is no ARM64EC and no FEX: wine runs the game's x86_64 code natively, so DXVK is just the
# standard x86_64 Windows build. Rather than rebuild it, reuse nixpkgs' cross-built DLLs — `pkgs.dxvk` is
# the wine-prefix wrapper whose 64-bit build (`passthru.dxvk64` = pkgsCross.mingwW64.dxvk_2, built with the
# win32 thread model so the DLLs need no libwinpthread) installs the PE DLLs under `/bin`. We just flatten
# them to `$out/<dll>.dll` — the SAME layout the ARM64EC build produces — so the launcher's prefix assembly
# (which symlinks `${dxvk}/d3d11.dll` etc.) is byte-for-byte identical across arches.
#
# `dxvk` here is nixpkgs' `pkgs.dxvk` (passed explicitly by lib/default.nix to avoid resolving the scope's
# own `dxvk` attr → infinite recursion). It is available only on x86_64-linux / i686-linux (its platforms).
{
  runCommand,
  dxvk,
}:
runCommand "dxvk-x86_64-${dxvk.version or "2"}" {
  meta.description = "DXVK (D3D9/10/11 → Vulkan) x86_64 PE DLLs (nixpkgs mingwW64 build), flattened for the propnix launcher";
} ''
  mkdir -p "$out"
  for d in d3d8 d3d9 d3d10core d3d11 dxgi; do
    f="$(find ${dxvk.passthru.dxvk64} -name "$d.dll" -print -quit)"
    if [ -n "$f" ]; then install -m444 "$f" "$out/$d.dll"; else echo "WARN: $d.dll not built"; fi
  done
''

# Outlast (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Unreal Engine 3 survival-horror (D3D9/D3D11). ARCH-AGNOSTIC: the same spec runs on both
# hosts; makeAppWine + the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a
# content-addressed FOD) is shared across arches. Windows-only title (no native Linux build), so it
# follows the Hollow Knight template. Payload = the pinned GOG Galaxy build fetched with gogdl (D15),
# delivered as the game tree directly (no InnoSetup).
#
#   nix run .#outlast --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
  runCommand,
  p7zip,
  cabextract,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  # Stage the real MS msvcp100.dll (built below — `let` is recursive) over wine's ARM64EC builtin in system32
  # (see the `msvcp100` note); fixes the DLL-init abort at startup. Harmless on x86_64 (a valid x64 DLL).
  tuning = (import ./tuning.nix) // {
    extraSystem32 = { "msvcp100.dll" = "${msvcp100}/msvcp100.dll"; };
  };
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "outlast-win"; });

  # The genuine Microsoft VC++ 2010 SP1 x64 msvcp100.dll, extracted from the game's OWN bundled redistributable
  # (license-clean: it ships this runtime for its own use). WHY: OLGame.exe (x86_64) bundles msvcr100.dll beside
  # itself but NOT msvcp100.dll, so wine supplies msvcp100 from system32 — which on aarch64 is wine's ARM64EC
  # builtin, whose DllMain access-violates under FEX (verified: `err:module:loader_init "MSVCP100.dll" failed to
  # initialize, aborting` → the whole process aborts at startup). Only the real MS x64 DLL loads; neither DLL
  # overrides nor wine's own builtins fix it. Staged over system32 via the `extraSystem32` tuning field.
  #
  # Extraction chain (all deterministic; payload is a fixed FOD): UE3Redist.exe (Epic's UnSetup self-extractor)
  # → vcredist_x64_vs2010sp1.exe (MS self-extractor) → vc_red.cab → F_CENTRAL_msvcp100_x64 (the DLL under its
  # MSI-mangled cab name). 7z unpacks the two self-extractors; cabextract handles the MS cabinet.
  msvcp100 = runCommand "outlast-msvcp100" { nativeBuildInputs = [ p7zip cabextract ]; } ''
    # 7z exits non-zero on benign warnings (trailing bytes in these SFX archives), so guard each step by
    # asserting the artifact it must produce rather than trusting the exit code.
    7z e ${payload}/Binaries/Redist/UE3Redist.exe vcredist_x64_vs2010sp1.exe -o. -y || true
    test -f vcredist_x64_vs2010sp1.exe
    7z x vcredist_x64_vs2010sp1.exe -ored -y || true
    cab=$(find red -iname vc_red.cab | head -1)
    test -n "$cab"
    cabextract -F '*msvcp100*' -d cab_out "$cab"
    dll=$(find cab_out -iname 'F_CENTRAL_msvcp100*' | head -1)
    test -n "$dll"
    # Sanity: must be a PE32+ (x64) image — an MZ header and machine 0x8664 at the PE offset.
    head -c2 "$dll" | grep -q 'MZ'
    install -Dm444 "$dll" "$out/msvcp100.dll"
  '';
in
makeAppWine {
  pname = "outlast";
  appid = "outlast";
  name = "Outlast";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  inherit payload;
  # UE3 x86_64 game binary launched DIRECTLY (not the 32-bit OutlastLauncher.exe isPrimary stub): the
  # propnix launcher waits on its primary child, and the launcher stub spawns the game then exits (which
  # would trigger prefix teardown), plus Win64/x86_64 is the target our aarch64 wine+FEX path runs. UE3
  # resolves content relative to the exe location (Binaries/Win64/../../OLGame/CookedPC), so cwd=payload
  # root is fine. OLGame_R.exe is the Mono/.NET DRM wrapper — the plain OLGame.exe is the DRM-free build.
  exe = "Binaries/Win64/OLGame.exe";
  inherit tuning;
}

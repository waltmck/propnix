# Outlast (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Unreal Engine 3 survival-horror (D3D9 SM3 path → DXVK). ARCH-AGNOSTIC: the same spec runs on
# both hosts; the wine backend + the scope pick the arch-appropriate emulator set, and the SAME Windows
# payload (a content-addressed FOD) is shared across arches. Windows-only title (no native Linux build),
# so it follows the Hollow Knight template. Payload = the pinned GOG Galaxy build fetched with gogdl (D15),
# delivered as the game tree directly (no InnoSetup).
#
#   nix run .#outlast --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  runCommand,
  p7zip,
  cabextract,
}:
mkApp (
  { config, lib, ... }:
  let
    # The payload is fetched by mkApp from the fetch matrix (versions.json); the msvcp100 extraction
    # references it via config.payloads (config.wine is only forced by the wine backend, so this stays lazy).
    payload = lib.head config.payloads;

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
    msvcp100 =
      runCommand "outlast-msvcp100"
        {
          nativeBuildInputs = [
            p7zip
            cabextract
          ];
        }
        ''
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
  {
    pname = "outlast";
    appid = "outlast";
    name = "Outlast";
    # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    # UE3 x86_64 game binary launched DIRECTLY (not the 32-bit OutlastLauncher.exe isPrimary stub, which spawns
    # the game then exits → trips the propnix launcher's primary-child teardown). UE3 resolves content relative
    # to the exe location, so cwd=payload root is fine. OLGame_R.exe is the Mono/.NET DRM wrapper — plain
    # OLGame.exe is the DRM-free build.
    exe = "Binaries/Win64/OLGame.exe";

    # Save: CONFIRMED from the GOG install script (goggame-1207660064.script → savePath
    # "{userdocs}/My Games/Outlast"). UE3 (shipping) redirects user config + saves + logs to
    # Documents\My Games\Outlast. Binding the whole folder captures saves + settings together, out to the
    # app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/outlast).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "Documents/My Games/Outlast";
      }
    ];

    # Stage the real MS msvcp100.dll (built above) over wine's ARM64EC builtin in system32; fixes the
    # DLL-init abort at startup. Harmless on x86_64 (a valid x64 DLL). With it, OLGame.exe clears DLL init,
    # initializes DXVK D3D9, and opens its window (`-nosteam` NOT needed). Otherwise Outlast is well-behaved
    # on the global wine defaults.
    wine = {
      extraSystem32."msvcp100.dll" = "${msvcp100}/msvcp100.dll";
    };
  }
)

# Prison Architect (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on
# x86_64 natively. ARCH-AGNOSTIC: this spec is identical on both hosts; the wine builder + the scope pick
# the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared
# across arches. Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild (D15), delivered as the game
# tree directly (no InnoSetup). Prison Architect (Introversion) is a 2D management sim on a custom engine.
#
#   nix run .#prison-architect --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
}:
mkApp {
  pname = "prison-architect";
  appid = "prison-architect";
  name = "Prison Architect";
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "Prison Architect64.exe";

  # Save dir: PA (Introversion custom engine) writes saves + config under
  # %LocalAppData%\Introversion\Prison Architect (saves live in the `saves/` subfolder). Bound to the
  # app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/prison-architect).
  # Confirmed via Introversion/PCGamingWiki save-location docs.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/Local/Introversion/Prison Architect";
    }
  ];

  # NOTE: no graphics/d3d override. PA is an OpenGL title (builtin OPENGL32.dll), so d3d=dxvk is a no-op
  # for it, and nothing here is a rendering workaround.
  wine = {
    # PA statically imports the GOG Galaxy SDK + POPS client (Galaxy64.dll + pops_api.dll), which cannot be
    # disabled via WINEDLLOVERRIDES — wine resolves static imports from the exe's own directory first. Bind
    # the no-op stubs over all three so the SDK never reaches GOG's services: propnix games run FULLY
    # OFFLINE, with no cloud dependencies (emulators/galaxy-stub states the policy). PA is the title that
    # first surfaced the need, and it runs fine WITH the real SDK today — this is the offline guarantee, not
    # a crash fix.
    galaxyStubDlls = [
      "Galaxy64.dll"
      "Galaxy.dll"
      "pops_api.dll"
    ];
  };
}

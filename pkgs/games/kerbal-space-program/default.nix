# Kerbal Space Program (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC
# DXVK, on x86_64 natively. ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope
# pick the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared
# across arches. Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild (D15), delivered as the game tree
# directly (no InnoSetup). KSP is a Unity title.
#
# DISPLAY: KSP's shipped default is a 1280x720 WINDOW, and it does not leave the screen mode to Unity —
# its own settings.cfg owns it, so the `presets.unity.fullscreen` PlayerPref would be overwritten at
# startup even though this build's UnityPlayer does know that pref. `setupScript` below maintains the
# three display keys in settings.cfg instead; see setup.sh for the evidence and for why that file's host
# path falls out of wine-tuning.nix's game-dir overlay.
#
#   nix run .#kerbal-space-program --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64/x86_64
{
  lib,
  mkApp,
  mkSetupScript,
}:
mkApp (
  { config, lib, ... }:
  {
    pname = "kerbal-space-program";
    maintainers = [ "waltmck" ];
    appid = "kerbal-space-program";
    name = "Kerbal Space Program";

    # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
    # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
    # because this game is KSP 1 has no multiplayer; the exe links no socket library at all.
    online = false;
    # GOG-Windows only.
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    # The GOG build ships a 64-bit-only tree: KSP_x64.exe is the goggame.info isPrimary FileTask (there is no
    # 32-bit KSP.exe at the root). Launcher.exe is the separate Private Division launcher, not the game.
    exe = "KSP_x64.exe";

    # Force FULLSCREEN at the compositor's mode by maintaining KSP's own settings.cfg (the game overrides
    # Unity's screen prefs from it, so the `presets.unity.fullscreen` preset cannot do this job here — see
    # setup.sh). No `withIniLib`: settings.cfg is a KSP ConfigNode, not an INI. Top-level, not a wine knob:
    # the hook runs in the OUTER phase before any prefix exists.
    setupScript = mkSetupScript {
      name = "kerbal-space-program-setup";
      script = ./setup.sh;
    };

    # wine-tuning.nix is a FUNCTION of `payload` (KSP's game-dir overlay references the payload store path).
    wine = (import ./wine-tuning.nix) { payload = lib.head config.payloads; };
  }
)

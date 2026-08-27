# IRON NEST: Heavy Turret Simulator (GOG, Windows build) via wine — on aarch64 through FEX + native
# ARM64EC DXVK, on x86_64 natively. ARCH-AGNOSTIC: this spec is identical on both hosts; the wine builder +
# the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD)
# is shared across arches. Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild (D15), delivered as the
# game tree directly (no InnoSetup).
#
# Engine: Unity IL2CPP (GameAssembly.dll + il2cpp_data + UnityPlayer.dll; NOT Mono — no mono-2.0-bdwgc.dll,
# so no managed-assembly overlay issue and no aarch64 FEX/Mono blocker, unlike KSP). Renders via Direct3D
# (a "D3D12" shader-cache dir ships beside the exe → D3D12 is the active graphics API; the globals also list
# D3D11) → DXVK/vkd3d → Vulkan under the default d3d=dxvk. Audio is FMOD (Plugins/x86_64/fmodstudio.dll).
# No GOG Galaxy SDK, POPS, or Steam DLLs are bundled and the exe imports only KERNEL32 + UnityPlayer, so no
# galaxyStubDlls and no extraSystem32 are needed (the modern UCRT/VCRUNTIME140 Unity links against is served
# by wine's ARM64EC builtins — same as Papers, Please, another IL2CPP title). Behaves on the global defaults;
# only the Unity fullscreen pref (the preset) and the save location are game-specific.
#
#   nix run .#iron-nest --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "iron-nest";
  appid = "iron-nest";
  name = "IRON NEST";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
  # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
  # because this game is a single-player turret sim; as the header notes, the exe imports only KERNEL32 +
  # UnityPlayer — no socket library, no store SDK.
  online = false;
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  # goggame-1162687982.info isPrimary FileTask (the real Unity player, not a launcher stub).
  exe = "Iron Nest Heavy Turret Simulator.exe";

  # Save: an IL2CPP Unity title (GameAssembly.dll calls UnityEngine.Application.get_persistentDataPath and
  # serialises with Newtonsoft.Json), so saves + settings land in Unity's persistentDataPath =
  # %USERPROFILE%\AppData\LocalLow\<company>\<product> = AppData\LocalLow\Iron Nest\Iron Nest Heavy Turret
  # Simulator (company/product from _Data/app.info). Bound to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/iron-nest).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/LocalLow/Iron Nest/Iron Nest Heavy Turret Simulator";
    }
  ];

  # The Unity fullscreen PlayerPref (winewayland fractional-scale cursor confinement fix; see the preset).
  wine = presets.unity.fullscreen "Software\\Iron Nest\\Iron Nest Heavy Turret Simulator";
}

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
# A GOG Galaxy SDK IS bundled — `…_Data/Plugins/x86_64/Galaxy64.dll` plus a root `GalaxyConfig.json` — so
# `wine.galaxyStubDlls` IS set below; only POPS and Steam DLLs are absent. (An earlier revision claimed no
# store SDK at all, reasoning from the exe importing just KERNEL32 + UnityPlayer; a Unity plugin is dlopened
# by the runtime and never appears in an import table, so that scan could not have seen it.) No
# extraSystem32 is needed (the modern UCRT/VCRUNTIME140 Unity links against is served
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
  # because this game is a single-player turret sim. The exe itself imports only KERNEL32 + UnityPlayer, but
  # that is not the whole story — a GOG Galaxy plugin ships under _Data/Plugins and is stubbed below.
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

  # The Unity fullscreen PlayerPref (winewayland fractional-scale cursor confinement fix; see the preset),
  # plus the de-Galaxy stub. THE HEADER USED TO SAY NO GOG SDK IS BUNDLED — that was wrong, and checking the
  # payload is what settled it: `Iron Nest Heavy Turret Simulator_Data/Plugins/x86_64/Galaxy64.dll` ships,
  # with `GalaxyConfig.json` at the payload root beside `goggame-1162687982.info`. The exe importing only
  # KERNEL32 + UnityPlayer does not contradict that — a Unity plugin is dlopened by the runtime, never named
  # in the exe's import table, so an import scan can never see it. Stubbed as policy: propnix binds the
  # no-op stub over every bundled Galaxy SDK copy, so the SDK is never engaged rather than engaged-and-
  # failing. The kernel-level guarantee is still `online = false` above.
  wine = lib.mkMerge [
    (presets.unity.fullscreen "Software\\Iron Nest\\Iron Nest Heavy Turret Simulator")
    { galaxyStubDlls = [ "Iron Nest Heavy Turret Simulator_Data/Plugins/x86_64/Galaxy64.dll" ]; }
  ];
}

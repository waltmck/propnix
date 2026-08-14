# IRON NEST: Heavy Turret Simulator (GOG, Windows build) via wine — on aarch64 through FEX + native
# ARM64EC DXVK, on x86_64 natively. ARCH-AGNOSTIC: this spec is identical on both hosts; makeAppWine + the
# scope pick the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is
# shared across arches. Payload = the pinned GOG Galaxy build fetched with gogdl (D15), delivered as the
# game tree directly (no InnoSetup).
#
# Engine: Unity IL2CPP (GameAssembly.dll + il2cpp_data + UnityPlayer.dll; NOT Mono — no mono-2.0-bdwgc.dll,
# so no managed-assembly overlay issue and no aarch64 FEX/Mono blocker, unlike KSP). Renders via Direct3D
# (a "D3D12" shader-cache dir ships beside the exe → D3D12 is the active graphics API; the globals also list
# D3D11) → DXVK/vkd3d → Vulkan under the default d3d=dxvk. Audio is FMOD (Plugins/x86_64/fmodstudio.dll).
# No GOG Galaxy SDK, POPS, or Steam DLLs are bundled and the exe imports only KERNEL32 + UnityPlayer, so no
# galaxyStubDlls and no extraSystem32 are needed (the modern UCRT/VCRUNTIME140 Unity links against is served
# by wine's ARM64EC builtins — same as Papers, Please, another IL2CPP title). Behaves on the global defaults.
#
#   nix run .#iron-nest --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  tuning = import ./tuning.nix;
in
makeAppWine {
  pname = "iron-nest";
  appid = "iron-nest";
  name = "IRON NEST";
  # gogdl takes the NUMERIC productId (not the slug); pins verified reproducible (fetchGogGalaxyBuild hdr).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "iron-nest-win"; });
  # goggame-1162687982.info isPrimary FileTask (the real Unity player, not a launcher stub).
  exe = "Iron Nest Heavy Turret Simulator.exe";
  inherit tuning;
}

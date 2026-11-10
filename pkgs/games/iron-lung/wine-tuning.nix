# Iron Lung — per-title tuning. Layered over the platform wine defaults (lib/backends/wine/defaults.nix),
# so this states only what is SPECIFIC to Iron Lung (David Szymanski). Small Unity submarine-horror title
# (D3D11 → DXVK → Vulkan). A FUNCTION of `payload` (default.nix applies it to the payload store path)
# because the Managed-assemblies seed references the payload's store path directly.
{ payload }:
{
  # Iron Lung_Data/Managed — the .NET managed assemblies of this Unity Mono build, as a per-launch
  # EPHEMERAL, WRITABLE tmpfs SEEDED from the store payload: a source-less `type = "mount"` (→ ns-private
  # tmpfs) plus `seed` (→ copy the real assemblies into it each launch). This player's Mono fails at
  # startup when Managed is served from the read-only `drive_c/game` bind —
  #   "The assembly mscorlib.dll was not found or could not be loaded.
  #    It should have been installed in C:\game\Iron Lung_Data\Managed\mono\4.5\mscorlib.dll"
  # in Player.log, before any graphics init — and loads only real files in a writable directory
  # (docs/research/unity-player-facts.md). Small, RAM-backed, re-seeded every launch; the KSP pattern.
  mounts."drive_c/game/Iron Lung_Data/Managed" = {
    seed = "${payload}/Iron Lung_Data/Managed";
  };

  # De-Galaxy: Iron Lung bundles the GOG Galaxy SDK as a Unity plugin (Iron Lung_Data/Plugins/x86_64/
  # Galaxy64.dll) and GalaxyConfig.json has `stats_on_init: true`, so the engine initializes the SDK at
  # startup and would talk to GOG's services. Bind the no-op stub over it on both hosts (offline policy,
  # emulators/galaxy-stub).
  galaxyStubDlls = [
    "Iron Lung_Data/Plugins/x86_64/Galaxy64.dll"
  ];

  # Steamworks: NO override. The GOG build also bundles real Steamworks (Iron Lung_Data/Plugins/x86_64/
  # steam_api64.dll, steam_appid.txt = 1846170) and calls SteamAPI_Init() at startup. The DLL must load:
  # the game's SteamManager is the stock Steamworks.NET template, whose DllNotFoundException handler calls
  # Application.Quit(), so a disabled DLL ends the game a few frames in with status 0. With the DLL loaded
  # and no Steam client, init fails soft ("[GalaxySteamWrapper] Authentication failed." under the netns)
  # and the game continues.
}

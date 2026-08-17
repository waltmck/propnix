# Iron Lung — per-title tuning. Layered over the platform wine defaults (lib/backends/wine/defaults.nix),
# so this states only what is SPECIFIC to Iron Lung (David Szymanski). Small Unity submarine-horror title
# (D3D11 → DXVK → Vulkan). A FUNCTION of `payload` (default.nix applies it to the payload store path)
# because the Managed-assemblies seed references the payload's store path directly.
{ payload }:
{
  # Iron Lung_Data/Managed — the .NET managed assemblies. Iron Lung is a Unity *Mono* build (MonoBleedingEdge
  # + mono-2.0-bdwgc.dll), NOT IL2CPP. Presented as a per-launch EPHEMERAL, WRITABLE tmpfs SEEDED from the
  # store payload: a source-less `type = "mount"` (→ ns-private tmpfs) plus `seed` (→ copy the real assemblies
  # into it each launch). WHY: Mono's mono_image_open MAP_SHARED-maps each assembly, which the kernel does NOT
  # handle for an overlay LOWER-layer file, and Mono also needs the containing directory WRITABLE — so serving
  # Managed via the read-only `drive_c/game` bind fails at startup with
  #   "The assembly mscorlib.dll was not found or could not be loaded.
  #    It should have been installed in C:\game\Iron Lung_Data\Managed\mono\4.5\mscorlib.dll"
  # (confirmed in this game's Player.log), aborting the process before any graphics init (UnityCrashHandler64
  # spawns). Only the REAL assemblies in a WRITABLE dir load. ~small, RAM-backed, always current (re-seeded
  # from the pinned payload), no persistent state. Same fix as KSP (source-less-tmpfs + seed; propnix-mount).
  mounts."drive_c/game/Iron Lung_Data/Managed" = {
    seed = "${payload}/Iron Lung_Data/Managed";
  };

  # De-Galaxy: Iron Lung bundles the GOG Galaxy SDK as a Unity plugin (Iron Lung_Data/Plugins/x86_64/
  # Galaxy64.dll) and GalaxyConfig.json has `stats_on_init: true`, so the engine initializes the SDK at
  # startup — whose offline RPC init faults wine's builtin rpcrt4 before the first frame on the winefex
  # (aarch64) path. Bind the graceful no-op stub over it (aarch64 only; omitted on x86_64 native wine).
  galaxyStubDlls = [
    "Iron Lung_Data/Plugins/x86_64/Galaxy64.dll"
  ];

  # De-Steam: this GOG build ALSO bundles real Steamworks (Iron Lung_Data/Plugins/x86_64/steam_api64.dll +
  # steam_appid.txt=1846170) and calls SteamAPI_Init() at startup. Under wine+FEX that init DEADLOCKS the
  # main thread (blocks in guest steam_api64 code right after the DLL's PROCESS_ATTACH, making no further
  # wine calls — a low-CPU wait; a Steam worker thread aborts under FEX and never signals init-complete), so
  # the game reaches its first scene but never presents its first frame (a white window forever). Disable the
  # DLL via WINEDLLOVERRIDES ("" = don't load): the game's plugin loader then can't load Steamworks, Steam
  # init fails cleanly, and the game falls back to the (stubbed) Galaxy / offline path and boots to its menu.
  dllOverrides."steam_api64" = {
    value = "";
    reason = "disabled: SteamAPI_Init() deadlocks the main thread under wine+FEX (never presents first frame); this GOG build only needs Steam for stats, so disabling it lets the game boot offline.";
  };
}

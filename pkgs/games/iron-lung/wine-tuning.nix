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
  # startup and would talk to GOG's services. Bind the no-op stub over it so the game stays fully offline
  # (aarch64 only; omitted on x86_64 native wine — see emulators/galaxy-stub for the policy).
  galaxyStubDlls = [
    "Iron Lung_Data/Plugins/x86_64/Galaxy64.dll"
  ];

  # Steamworks note — NO override shipped, but the diagnosis is worth keeping. This GOG build ALSO bundles
  # real Steamworks (Iron Lung_Data/Plugins/x86_64/steam_api64.dll + steam_appid.txt=1846170) and calls
  # SteamAPI_Init() at startup.
  #
  #   * Native wine (x86_64): the DLL MUST load. The game's SteamManager is the stock Steamworks.NET
  #     template, whose DllNotFoundException handler calls Application.Quit() — with the DLL disabled the
  #     game exits CLEANLY (status 0) a few frames after startup, right after Enlighten worker setup, which
  #     presents as an instant silent crash (diagnosed on x86_64: Player.log shows the canonical
  #     "[Steamworks.NET] Could not load [lib]steam_api.dll" + DllNotFoundException at SteamManager.Awake,
  #     then the truncated log of a mid-frame exit). With the real DLL loading and no Steam client,
  #     RestartAppIfNecessary() returns false and init fails SOFT ("[GalaxySteamWrapper] Authentication
  #     failed." under the launcher's no-network namespace) — verified booting and staying up on x86_64.
  #
  #   * wine+FEX (aarch64): SteamAPI_Init() DEADLOCKS the main thread (blocks in guest steam_api64 code
  #     right after the DLL's PROCESS_ATTACH, making no further wine calls — a low-CPU wait; a Steam worker
  #     thread aborts under FEX and never signals init-complete), so the game never presents its first
  #     frame (a white window forever). A WINEDLLOVERRIDES steam_api64="" workaround was tried and DID get
  #     past the deadlock — but the game then dies anyway at first-scene/menu construction with the
  #     worker-thread abort recorded in default.nix's `broken` (likely FEX on a 16K-page kernel, beyond
  #     its design limits), so the override buys nothing and is not carried. If that abort is ever
  #     resolved (FEX 16K-page support, or a 4K kernel) and aarch64 revisited, expect to need a FEX-scoped
  #     disable of this DLL again (and only there — see the native-wine leg above).
}

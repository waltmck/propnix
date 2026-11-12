# Space Engineers (Steam, Windows build) via wine — on aarch64 with a NATIVE ARM64EC Mono runtime
# (the managed game code is JIT-compiled to ARM64; emulators/wine-mono patches/0002), native ARM64EC
# DXVK, and FEX only for the game's own x64 DLLs (Havok, steam_api64, …); on x86_64 natively. Keen
# Software House's VRage 2 engine: a MANAGED .NET Framework game (Sandbox.*/VRage.* assemblies,
# Steamworks.NET, EmptyKeys UI, Roslyn for in-game scripting) driving native D3D11 through SharpDX,
# with Havok and RecastDetour as native DLLs beside it. ARCH-AGNOSTIC: this spec is identical on
# both hosts; mkApp + the scope pick the arch-appropriate emulator set and the SAME Windows payload
# (a content-addressed FOD) is shared across arches.
#
# Steam-only, Windows-only: app 244850 has one content depot pinned here (244851), so the fetch
# matrix has exactly that pair and any other selection is a legible mkApp error. Requires an account
# that owns the title: `propnix cred add steam`.
#
# `Bin64/SpaceEngineers.exe` is a pure managed .NET 4.6.1 exe (no import table): the prefix's Wine
# Mono (emulators/wine-mono) is its CLR (docs/research/wine-mono-clr-in-prefix.md). Run record:
# docs/verified/space-engineers-win.json; the headless rig and its limits (first-run dialogs no
# virtual pointer can dismiss, host load): docs/research/headless-test-harness.md.
#
#   nix run .#space-engineers --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64/x86_64
{
  lib,
  mkApp,
}:
mkApp {
  pname = "space-engineers";
  maintainers = [ "waltmck" ];
  appid = "space-engineers";
  name = "Space Engineers";

  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

  # The only exe in Bin64 (Tools/ holds audio converters); Steam's install script runs it too.
  exe = "Bin64/SpaceEngineers.exe";

  # cwd = Bin64, as Steam launches it: the engine's asset literals are `..\Content\…` from Bin64.
  workingDir = "Bin64";

  # `-skipintro` is the game's own switch. The intro is WMV3/VC-1 over DirectShow, which this wine
  # cannot decode, and the intro screen waits on it forever (menu background videos are also
  # absent). Drop it when wine decodes WMV (docs/research/wine-builtin-gaps.md). Not `-nosplash`:
  # the splash works.
  exeArgs = [ "-skipintro" ];

  # ── aarch64: nothing to configure here ──────────────────────────────────────────────────────────
  # The title's aarch64 blockers were runtime defects, fixed in emulators/wine-mono: patches/0001
  # holds a native-callable instance delegate strongly (the collector could clear it while a native
  # call was still inside the callback), and the runtime is the ARM64EC build (patches/0002), so
  # managed code runs natively and only the game's own x64 DLLs are emulated. No per-game GC tuning
  # (`MONO_GC_PARAMS`) or `MONO_DEBUG` setting belongs here: a workaround would hide the same defect
  # in the next managed title. How the defect was found, what was ruled out and what the tuning did
  # and did not do: docs/research/wine-mono-delegate-lifetime.md.

  # Full-colour icon auto-extracted from SpaceEngineers.exe's PE resources (icon.auto default).

  # The online stack (Steamworks, EOS, mod.io, workshop) needs a genuine Steam session. gbe_fork
  # mints none, and EOS Connect validates a Valve-signed ticket with Epic, so the netns removes
  # nothing that works.
  online = false;

  # Steamworks.NET P/Invokes `Bin64/steam_api64.dll` by name (exe dir first); steam.emu replaces it
  # with the shim. No `dlc.available`: only the base depot is pinned, so the shim owns no DLC.
  steam.emu.libPaths = [ "Bin64/steam_api64.dll" ];

  # VRage keeps its user tree, and its regenerable scratch, under %AppData%\<GameNameSafe> =
  # SpaceEngineers (SpaceEngineers.Game.dll). The depot's empty TempContent/ dirs are not written
  # (docs/research/writable-game-dir.md).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/Roaming/SpaceEngineers";
    }
  ];

  wine = {
    # VRage compiles HLSL at runtime; its GPU-particle compute shaders use
    # AppendStructuredBuffer/ConsumeStructuredBuffer (UAV counters), which wine's vkd3d-shader has no
    # front end for (docs/research/wine-builtin-gaps.md). The depot ships Microsoft's compiler beside
    # the exe; "n,b" keeps the builtin as fallback.
    dllOverrides.d3dcompiler_47 = {
      value = "n,b";
      reason = "native: the depot ships Microsoft's d3dcompiler_47 beside the exe; wine's vkd3d-shader builtin has no AppendStructuredBuffer/ConsumeStructuredBuffer (UAV counters), which the GPU-particle compute shaders need.";
    };
  };

  # No d3d/graphics override: VRage is D3D11 (SharpDX), which the DXVK + winewayland defaults serve.
}

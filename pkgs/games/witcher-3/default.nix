# The Witcher 3: Wild Hunt — Complete Edition (GOG, Windows build) via wine — on aarch64 through
# FEX + native ARM64EC DXVK/vkd3d, on x86_64 natively. CD Projekt Red's REDengine 3, in its 4.0x
# "next-gen" form, which ships TWO complete renderers as two separate binaries (D3D11 and D3D12); we
# run the D3D12 one, so D3D goes game → vkd3d-proton (d3d12) → DXVK's dxgi (presentation) → Vulkan.
# ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope pick the arch-appropriate
# emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across arches.
# Windows-only title (CDPR ships no Linux build), so the payload is the pinned GOG Galaxy build
# fetched by fetchGogGalaxyBuild (D15) — the game tree directly, no InnoSetup.
#
#   nix run .#witcher-3 --extra-sandbox-paths /propnix=/var/lib/propnix
#
# Complete Edition: all 21 DLC (including Hearts of Stone and Blood and Wine) ship in the base build
# under dlc/, so there is no dlc block. `goggame-1495134320.info` says "Game of the Year
# Edition": GOG renamed the SKU without rewriting it (docs/research/multi-store-payloads.md).
#
# Launch a game binary directly: the launcher's renderer setting is only an exe pick
# (launcher-configuration.json), and REDprelauncher installs and runs a 642 MB REDlauncher that
# spawns-and-exits (docs/research/publisher-launcher-bypass.md).
#
# The D3D12 renderer is an owner decision, for ray tracing and HDR. vkd3d-proton is already the
# primary renderer for cyberpunk-2077; this title's D3D12 exe has not been run. The engine keeps
# per-renderer settings (`dx12user.settings` vs `user.settings`), so set video options and HDR in
# the in-game menu on first run. Switching back to D3D11 needs both fields (the engine is
# cwd-sensitive); saves are shared, settings separate:
#
#   witcher-3.apply { exe = "bin/x64/witcher3.exe"; workingDir = "bin/x64"; }
#
# The renderer trade-off and the HDR analysis: docs/research/dxvk-hdr-under-winewayland.md.
{
  lib,
  mkApp,
}:
mkApp {
  pname = "witcher-3";
  maintainers = [ "waltmck" ];
  appid = "witcher-3";
  name = "The Witcher 3: Wild Hunt";

  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

  exe = "bin/x64_dx12/witcher3.exe";
  # The exe's own directory, as the .info play task declares.
  workingDir = "bin/x64_dx12";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE, so the guarantee is enforced
  # by the kernel rather than by trusting the title's bundled SDKs. Single-player title — there is
  # no multiplayer mode in The Witcher 3 at all — and the payload's two network consumers are
  # exactly what should be held to loopback: `RedTelemetryLib.dll` sits beside the exe in both bin
  # dirs (and the exe's RTTI carries a whole `telemetry::parameters` type tree — Hardware, Build,
  # Location, Progress, Debug), and witcher3.exe statically imports WININET.dll and
  # `REDGalaxy64.dll` (CDPR's rebuild of the GOG Galaxy SDK). Nothing here needs the network.
  online = false;

  # DXVK's stand-in for the Windows "HDR on" display toggle: winewayland writes no EDID, so DXVK's
  # dxgi never reports HDR without it. It applies to the D3D12 exe because vkd3d-proton presents
  # through DXVK's dxgi. Safe on an SDR session: the Vulkan surface offers no HDR10 colorspace
  # there, so the swapchain stays sRGB. Untested on this title.
  env.DXVK_HDR = "1";

  # Full-color icon auto-extracted from the exe's PE resources (icon.auto default); both binaries
  # carry the same .rsrc. No symbolic icon vendored yet.

  # Saves: Documents/The Witcher 3 (gamesaves/ plus the settings files), one whole-folder bind. Read
  # off the exe strings, not traced: if saves go missing, trace the real CreateFileW path and
  # correct this row.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Documents/The Witcher 3";
    }
  ];

  # REDGalaxy64.dll (CDPR's own SDK, statically imported) can't take the galaxy stub;
  # `online = false` covers it. Galaxy64.dll in both bin dirs is stubbed as policy: GOG plugins load
  # it by name at runtime, which an import scan can't see (docs/research/galaxy-sdk-offline.md).
  wine.galaxyStubDlls = [
    "bin/x64/Galaxy64.dll"
    "bin/x64_dx12/Galaxy64.dll"
  ];
  # No `extraSystem32`: witcher3.exe links its CRT statically, so nothing needs staging.

  # Open: writes into the read-only game dir (shader cache, crash reporter) are untested. The fix
  # would be no-mans-sky's CoW overlay, but its per-file skeleton is costly at 2546 files
  # (docs/research/writable-game-dir.md).
}

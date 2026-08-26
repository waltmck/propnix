# Baldur's Gate 3 (GOG, Windows build) via wine — on aarch64 through FEX + ARM64EC, on x86_64 natively.
# Larian's Divinity 4.0 engine. ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope pick
# the arch-appropriate emulator set and the SAME Windows payload (a content-addressed FOD) is shared.
#
# Windows-only here for now: GOG ships no Linux build, and the user also owns the title on Steam (a `steam`
# row can be pinned later for comparison — the fetch matrix takes both).
#
#   nix run .#baldurs-gate-3 --extra-sandbox-paths /propnix=/var/lib/propnix
#
# ── WHICH EXECUTABLE, AND WHY NOT THE PRIMARY ONE ──────────────────────────────────────────────────────
# `goggame-1456460669.info` lists three play tasks:
#   isPrimary=true   Launcher/LariLauncher.exe   category=launcher   121 KB
#   isPrimary=false  bin/bg3.exe                 category=game        35 MB   (native Vulkan)
#   isPrimary=false  bin/bg3_dx11.exe            category=game        34 MB   (D3D11)
# We launch `bin/bg3.exe` DIRECTLY, not the isPrimary task. LariLauncher is a .NET single-file WPF app that
# embeds CefSharp — running it would drag in the whole Chromium-under-wine problem for no benefit, since it
# only ever execs one of the two real binaries. Its own manifest shows it passes `--skip-launcher` and
# nothing else the game needs, so launching the game directly loses no setup.
#
# bg3.exe (Vulkan) over bg3_dx11.exe (D3D11) is the fewer-layers choice on this stack: the Vulkan renderer
# goes straight to winevulkan, whereas the D3D11 path adds D3D11 -> DXVK -> Vulkan. If the Vulkan backend
# misbehaves, `.apply { exe = "bin/bg3_dx11.exe"; }` is the one-line fallback.
#
# ── VERIFIED BY PLAYING IT ─────────────────────────────────────────────────────────────────────────────
# Reaches the main menu, starts a new game, plays through the intro and autosaves (engine state machine
# reaches Running/Save). Two ~18-minute sessions exited cleanly with no page faults.
#
# graphics: the tree default (winewayland) is CORRECT here — do not add an x11 override. A/B measured:
# wayland 18 min clean exit / 0 faults / 0 swapchain recreates, x11 17 min clean exit / 0 faults. The
# fullscreen-Vulkan swapchain-recreate NULL-deref that forces x11 for Skyrim SE does not reproduce.
{
  lib,
  mkApp,
}:
mkApp {
  pname = "baldurs-gate-3";
  appid = "baldurs-gate-3";
  name = "Baldur's Gate 3";

  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

  exe = "bin/bg3.exe";

  # The engine writes its log as `gold.<timestamp>.log` into the GAME directory, which is read-only here,
  # so CreateFileW fails with STATUS_ACCESS_DENIED and it runs with NO log sink at all. `--logPath <dir>`
  # (two separate argv entries — the option parser does not accept `=`) redirects it into the already-bound
  # writable state directory. Worth keeping beyond debugging: a user reporting a bug now has a real log,
  # and it is what made every diagnosis on this title possible.
  exeArgs = [
    "--logPath"
    "C:\\users\\propnix\\AppData\\Local\\Larian Studios\\Baldur's Gate 3"
  ];

  # THE fix for this title: run with the working directory set to the executable's own directory.
  # The engine derives its khonsu path roots as `<cwd>/../Data/...` — measured directly out of the game's
  # base-path global at runtime: "C:/game/../Data/Scripts". With propnix's default cwd (the game root)
  # that collapses to `C:\Data\Scripts`, i.e. the DRIVE ROOT, so every script path — and the VFS key
  # built from it — is wrong, and the engine silently fails to resolve `Scripts/**` out of the paks
  # (verified: it reads the pak's whole file list, then issues ZERO reads for any script entry).
  # With cwd = bin, `bin/../Data/Scripts` is correct, which is what a normal install gets.
  workingDir = "bin";

  # Full-colour icon from the game binary's own PE resources.
  icon.auto = true;

  # Larian keeps EVERYTHING under one LOCALAPPDATA directory — settings, the Vulkan pipeline cache, and the
  # actual savegames — so it is split across two binds by KIND rather than persisted wholesale. Both are
  # `saveBinds` rows because that is the mechanism for binding under the wine profile home (the builder joins
  # `dst` onto `drive_c/users/<wineUser>/`, so a game file never has to know the profile name); `src` is just
  # a path, and pointing one at $PROPNIX_STATE is what puts regenerable data in the state dir.
  #
  # VERIFIED by running it: graphicSettings.lsx, vkDeviceConfig.lsx, PlayerProfiles/, the engine logs and
  # pipelineCacheTimestampVk.bin all appear here; savegames land under PlayerProfiles.
  #
  # The SHADER CACHE is the reason for the split. `bin/bg3.exe` strings name
  # `pipelineCacheVk.bin` / `pipelineCacheVk.bin.tmp` / `pipelineCacheTimestampVk.bin` /
  # `abstractPipelineCache.psoCache`, all written into this same directory — so the expensive first-launch
  # pipeline compile lands here. It is CACHE, not save data: it belongs in the state dir, where it is not
  # entangled with savegames (which a user may back up, sync or wipe independently).
  #
  # NOTE the `.tmp` suffix above: the game writes the cache then RENAMEs it into place. That is why the cache
  # must sit inside a bound DIRECTORY and must never be given a per-FILE bind row — rename(2) cannot replace a
  # bind-mounted file (EBUSY), the same trap that shapes how user.reg is handled in the wine builder.
  saveBinds = [
    {
      # Settings + the Vulkan pipeline cache: regenerable, so state rather than saves.
      src = "$PROPNIX_STATE/larian";
      dst = "AppData/Local/Larian Studios/Baldur's Gate 3";
    }
    {
      # The savegames proper, nested inside the row above (propnix-mount lays parents first and builds the
      # missing child mountpoint).
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/Local/Larian Studios/Baldur's Gate 3/PlayerProfiles";
    }
  ];
}

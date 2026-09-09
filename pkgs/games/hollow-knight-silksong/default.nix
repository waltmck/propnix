# Hollow Knight: Silksong (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC
# DXVK, on x86_64 natively. Team Cherry's Unity sequel to Hollow Knight; ARCH-AGNOSTIC like the HK spec:
# mkApp + the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a
# content-addressed FOD) is shared across arches. Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild
# (D15), delivered as the game tree directly (no InnoSetup).
#
# Well-behaved on the global wine defaults (d3d=dxvk, graphics=wayland, DLL hygiene) — the per-title tuning
# is the Unity frame-pacing preset (Silksong persists the SAME `VidVSync`/`VidTFR` PlayerPrefs as Hollow
# Knight — verified: identical `_h<hash>` value names, the hash is a pure function of the pref name — under
# its own HKCU key), so the fragment is passed directly and there is no wine-tuning.nix; the other per-title
# item is the de-GOG mask below, which is offline HYGIENE, not a liveness fix — the game boots without it
# (see `maskFiles`). Nothing here works around the old loading-screen hang: that was the shared wine
# defaults' read-only `dosdevices` bind, fixed in lib/backends/wine/defaults.nix.
#
#   nix run .#hollow-knight-silksong --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64/x86_64-linux
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "hollow-knight-silksong";
  maintainers = [ "waltmck" ];
  appid = "hollow-knight-silksong";
  name = "Hollow Knight: Silksong";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
  # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
  # because this game is single-player like its predecessor; the exe links no socket library at all.
  online = false;
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "Hollow Knight Silksong.exe";
  # Full-color icon auto-extracted from the exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
  icon.symbolic = ./hollow-knight-silksong-symbolic.svg;

  # Save: Unity persistentDataPath (Company/Product from the payload's goggame-*.info: "Team Cherry" /
  # "Hollow Knight Silksong"), bound to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID,
  # default $XDG_DATA_HOME/propnix-saves/hollow-knight-silksong).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/LocalLow/Team Cherry/Hollow Knight Silksong";
    }
  ];

  # ── De-GOG: erase the Galaxy SDK's managed-side entry point so the game never selects the GOG online
  # subsystem. This is an OFFLINE-HYGIENE choice ONLY. It is NOT a fix for the boot hang this block used to
  # blame it for — see "THE HANG, SETTLED" below; the hang was in propnix's own wine mount table and is
  # fixed in lib/backends/wine/defaults.nix, not here.
  #
  # ── HOW THE GAME DECIDES, read off Assembly-CSharp.dll's IL (monodis), not off its string heap:
  #
  #   DesktopPlatform::CreateOnlineSubsystem() collects candidates from four static `IsPackaged()` probes
  #   (GOG / GameCore / Steam / Streaming). Each one is
  #       DesktopPlatform::IncludesPlugin(name)
  #         = File.Exists(Path.Combine(Application.dataPath, "Plugins", name))
  #           || Directory.Exists(same)
  #   and GOG's passes name = Path.Combine("x86_64", "GalaxyCSharpGlue.dll"). So the ONE path that decides
  #   anything is `Hollow Knight Silksong_Data/Plugins/x86_64/GalaxyCSharpGlue.dll` — erasing it makes
  #   `IsPackaged()` false with certainty, which is why a mask (true absence) is the neutralizer here.
  #
  #   With no candidate left — this GOG build ships no other store plugin (Plugins/x86_64 has no
  #   steam_api64.dll and no XGamingRuntimeThunks.dll) — CreateOnlineSubsystem logs
  #   "No online subsystems packaged." and RETURNS with `onlineSubsystem` left null. Absence does NOT fall
  #   back to `DesktopOnlineSubsystem` (there is no such fallback — the field simply stays null).
  #
  # WHAT THE GAME DOES UNMASKED, now that it boots — MEASURED, not inferred (3/3 headless runs on the fixed
  # mount table, maskFiles = [ ], netns unshared). It reaches the title scene every time, and Player.log
  # carries the whole GOG story to a clean end:
  #
  #     GOG signing in...
  #     Selected online subsystem GOGGalaxyOnlineSubsystem
  #     GOG authorization failed: FAILURE_REASON_GALAXY_SERVICE_NOT_AVAILABLE
  #
  # That LAST line is the one this block used to assert is "never logged", and the whole "the SDK retries
  # forever, the IAuthListener never fires, the boot gate never clears" inference rested on its absence. The
  # absence was an artifact: the process died in the mountmgr hang long before this code ran. Under the
  # netns the SDK reports a clean failure and the boot gate clears on its own. So GOG is EXONERATED, and the
  # mask is INERT for booting.
  #
  # KEEPING IT ANYWAY, on the offline guarantee rather than on liveness: `online = false` should mean the
  # store SDK is never engaged, not that it is engaged and fails. Masked, no subsystem is selected and
  # Galaxy64.dll's worker never starts; unmasked, it starts, fails, and logs. Cost of the mask is GOG
  # achievements and GOG cloud saves, neither of which can work under `online = false` anyway. Dropping the
  # two rows is a SAFE change if the whiteout mechanism ever gets in the way (see MECHANISM NOTE) — it costs
  # only that hygiene, not a working boot.
  #
  # `wine.galaxyStubDlls` IS now also set (see the bottom of this spec). It used to be no option at all —
  # it only emitted mount rows when the scope wired `galaxyStub`, which was the winefex (aarch64) path ONLY
  # and inert on x86_64 native wine. That gap was closed on 2026-09-03 (lib/default.nix wires the stub on
  # both arches now), so the two mechanisms are complementary rather than alternatives: the mask removes the
  # C# glue, the stub neutralizes the native SDK underneath it.
  #
  # BOTH copies are masked: the Unity plugin path (the only decision input) and the root-level copy beside
  # the exe (belt and braces — Mono's dlopen would otherwise fall back to the OS loader, which searches the
  # process directory). Galaxy64.dll is left in place; nothing loads it once the glue is gone.
  #
  # MECHANISM NOTE, since a whiteout is the heaviest thing in this spec: `maskFiles` rows are propnix-mount
  # WHITEOUTS, and a whiteout OVERLAYS ITS TARGET'S PARENT DIR IN PLACE (pkgs/propnix-mount/src/lib.rs,
  # `mount_whiteout`), so the root-level row turns `drive_c/game` itself into an overlayfs whose lower is
  # the payload. That is HARMLESS here, tested rather than assumed: a headless A/B of this exact build with
  # and only-without the two whiteout rows produced identical behaviour, and a userns replay of the stack
  # confirms both mounts succeed, both DLL copies are erased, all 152 `Managed/` entries stay visible, and
  # `mscorlib.dll` reads back fine over the overlay lower (MAP_SHARED and MAP_PRIVATE both). Keep the
  # `maskFiles` MECHANISM CONSTRAINT in mind anyway — a game dir that is ALREADY multi-lower (DLC,
  # extraLowers, steam.emu) cannot take a whiteout at all.
  #
  # ── THE HANG, SETTLED (and it was never this game's fault). The reported symptom — sits on the loading
  # screen forever, 113-byte Player.log ending at `Mono config path = …` — was the READ-ONLY `dosdevices`
  # bind that the shared wine defaults used to emit. mountmgr.sys's `add_drive()` retries a symlink into
  # dosdevices forever when the write cannot succeed, holding `device_section` while it spins, so every
  # other thread in the prefix blocks in any mountmgr IOCTL. Unity 6's very first act after Mono init is
  # exactly such an IOCTL (`NtQueryVolumeInformationFile` → `get_mountmgr_fs_info`), which is why the log
  # stops one line early: the next line the player would have printed is
  # `Input System module state changed to: Initialized.` Full mechanism and the strace that caught it are in
  # lib/backends/wine/defaults.nix at the `dosdevices` row.
  #
  # PROOF, back to back on ONE headless sway with the SAME propnix-launcher binary, the two baked configs
  # differing in NOTHING but that row:
  #     dosdevices = { mode = "ro"; type = "mount"; }  → 3/3 hang, last line `Mono config path = …`
  #     dosdevices = { type = "overlay"; skeleton = null; } → 3/3 reach the title scene
  # and on the fixed table 18/18 further runs booted, including 6 invoked exactly as a user does
  # (plain `nix run .#hollow-knight-silksong`, no PROPNIX_DEBUG, no `-logfile -`), each leaving a 3085-byte
  # Player.log and a screenshotted language-select screen. Silksong needs NO per-title workaround for it.
  #
  # Two traps this cost four investigations, worth leaving marked:
  #   * a truncated Player.log is NOT a death point — Unity buffers it and flushes at exit, so it only says
  #     "killed or hung", never where. Use `-logfile -` (needs PROPNIX_DEBUG=1 to forward the child's pipe).
  #   * `PROPNIX_WINEDEBUG='+file'` made the hang VANISH, which reads as a race but is not one: it was a
  #     concurrent edit to the shared mount table landing mid-session. Re-check the baked config
  #     (`nix build .#<app>` → the launcher's `--config` json) before calling anything timing-dependent.
  maskFiles = [
    "Hollow Knight Silksong_Data/Plugins/x86_64/GalaxyCSharpGlue.dll"
    "GalaxyCSharpGlue.dll"
  ];

  # De-Galaxy, the OTHER half. The masks above remove the C# GLUE (what Mono dlopens); these rows bind the
  # no-op stub over the native SDK itself, both shipped copies. Belt and braces on purpose: with the glue
  # masked nothing should reach Galaxy64.dll, but "should" is doing a lot of work in a payload that carries
  # two copies of it, and propnix's policy is that every bundled Galaxy SDK gets the stub rather than being
  # left live behind a mask.
  wine = lib.mkMerge [
    (presets.unity.framePacing "Software\\Team Cherry\\Hollow Knight Silksong")
    {
      galaxyStubDlls = [
        "Hollow Knight Silksong_Data/Plugins/x86_64/Galaxy64.dll"
        "Galaxy64.dll"
      ];
    }
  ];
}

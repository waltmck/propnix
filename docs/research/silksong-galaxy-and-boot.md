# Hollow Knight: Silksong — the Galaxy SDK and the boot path

The findings behind pkgs/games/hollow-knight-silksong: how the game picks its online subsystem, what it
does with the GOG SDK present and no network, and the loading-screen hang that was once blamed on the
SDK. The spec neutralizes Galaxy with `wine.galaxyStubDlls` alone, as Hollow Knight's GOG build does; the
`maskFiles` whiteouts it used to carry are gone because a multi-lower game dir (the ARM64EC Mono runtime
arrives as an extra lower) cannot take a whiteout.

## How the game decides (Assembly-CSharp.dll, read off the IL with monodis)

`DesktopPlatform::CreateOnlineSubsystem()` collects candidates from four static `IsPackaged()` probes
(GOG / GameCore / Steam / Streaming). Each is

    DesktopPlatform::IncludesPlugin(name)
      = File.Exists(Path.Combine(Application.dataPath, "Plugins", name))
        || Directory.Exists(same)

and GOG's passes `Path.Combine("x86_64", "GalaxyCSharpGlue.dll")`. The one path that decides anything
is therefore `Hollow Knight Silksong_Data/Plugins/x86_64/GalaxyCSharpGlue.dll`. With no candidate at all
(this GOG build ships no other store plugin: `Plugins/x86_64` has no steam_api64.dll and no
XGamingRuntimeThunks.dll) the method logs "No online subsystems packaged." and returns with
`onlineSubsystem` null; there is no `DesktopOnlineSubsystem` fallback.

## With the SDK selected and no network

Measured on the fixed mount table (3/3 headless runs, no mask, netns unshared, the real Galaxy64.dll): the
title scene is reached every time and Player.log carries the whole story to a clean end:

    GOG signing in...
    Selected online subsystem GOGGalaxyOnlineSubsystem
    GOG authorization failed: FAILURE_REASON_GALAXY_SERVICE_NOT_AVAILABLE

The SDK reports a clean failure and the boot gate clears on its own. The no-op stub
(emulators/galaxy-stub) answers `Init` and delivers one `OnAuthFailure` from `ProcessData`, so the stubbed
path ends the same way without a Galaxy worker ever starting. The mask the spec used to carry (both copies
of GalaxyCSharpGlue.dll) made `IsPackaged()` false and skipped the subsystem entirely; its only cost was
GOG achievements and cloud saves, which `online = false` rules out anyway.

Whiteout mechanics, for the record: a `maskFiles` row overlays its target's PARENT directory in place
(pkgs/propnix-mount, `mount_whiteout`), so the root-level row turned `drive_c/game` itself into an
overlayfs over the payload. A headless A/B with and without the two rows behaved identically, and a
userns replay confirmed both mounts, both erasures, all 152 `Managed/` entries visible and `mscorlib.dll`
readable over the overlay lower (MAP_SHARED and MAP_PRIVATE). A game dir that is already multi-lower
(DLC, extraLowers, steam.emu) cannot take a whiteout at all.

## The loading-screen hang (not this game's fault)

The symptom — the loading screen forever, a 113-byte Player.log ending at `Mono config path = …` — was
the read-only `dosdevices` bind the shared wine defaults used to emit. mountmgr.sys's `add_drive()`
retries a symlink into dosdevices forever when the write cannot succeed, holding `device_section` while it
spins, so every other thread in the prefix blocks in any mountmgr IOCTL. Unity 6's first act after Mono
init is exactly such an IOCTL (`NtQueryVolumeInformationFile` → `get_mountmgr_fs_info`), which is why the
log stops one line early; the next line would have been `Input System module state changed to:
Initialized.` The mechanism and the strace are in lib/backends/wine/defaults.nix at the `dosdevices` row.

Proof, back to back on one headless sway with the same propnix-launcher binary, the two baked configs
differing in nothing but that row:

    dosdevices = { mode = "ro"; type = "mount"; }        → 3/3 hang, last line `Mono config path = …`
    dosdevices = { type = "overlay"; skeleton = null; }  → 3/3 reach the title scene

On the fixed table 18/18 further runs booted, six of them invoked exactly as a user does (plain
`nix run .#hollow-knight-silksong`), each leaving a 3085-byte Player.log and a screenshotted
language-select screen.

Two traps, each of which cost an investigation:

- A truncated Player.log is not a death point. Unity buffers it and flushes at exit, so it only says
  "killed or hung", never where. Use `-logfile -` (needs PROPNIX_DEBUG=1 to forward the child's pipe).
- `PROPNIX_WINEDEBUG='+file'` made the hang vanish, which reads as a race but was not one: a concurrent
  edit to the shared mount table had landed mid-session. Re-check the baked config (`nix build .#<app>`,
  then the launcher's `--config` JSON) before calling anything timing-dependent.

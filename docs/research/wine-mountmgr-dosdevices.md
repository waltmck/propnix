# The read-only dosdevices hang (wine mountmgr)

When a prefix's `dosdevices` directory cannot be written, wine's mountmgr.sys retries a drive-letter
symlink forever while holding its `device_section` lock, and every mountmgr IOCTL in the prefix then
blocks. Any title that asks for volume information (a .NET `DriveInfo` is enough) hangs before it
draws anything; a Unity title's log stops one line after `Mono config path = …`. The trigger is the
host, not the game: it fires on any machine with a block device that UDisks2 reports and that has no
drive letter in the prefix yet. propnix therefore never binds `dosdevices` read-only; the shared
wine defaults (lib/backends/wine/defaults.nix) mount it as an ephemeral overlay so the symlink
succeeds. This document holds the mechanism, the measurement, how the hang presents on each title it
has hit, a suspected further instance (Rust), and the traps it sets.

## Mechanism

### The spinning writer

`dlls/mountmgr.sys/device.c`'s `add_dos_device()` takes `device_section` and, for an auto-assigned
letter, calls `unixlib.c: add_drive()`, whose tail is

    while (avail != -1) { …scan a..z for a free letter…
                          if (avail != -1) { … if (symlink( device, path ) != -1) goto done;
                                             /* failed, retry the search */ } }

The retry exists for a race (another process claimed the letter between the scan and the symlink),
and it is correct for that case: the next scan sees the letter taken and moves on. On a read-only
`dosdevices` the symlink fails permanently, the scan result is unchanged, and the same letter is
picked forever. `in_use[]` is only set by a scan that finds something, never by a failed create.

### The blocked waiters

ntdll's `get_mountmgr_fs_info()` (`dlls/ntdll/unix/file.c`) opens `\Device\MountPointManager` and
issues `IOCTL_MOUNTMGR_QUERY_UNIX_DRIVE` through `sync_ioctl`; mountmgr serves it in
`query_unix_drive()`, which enters `device_section` first. `NtQueryVolumeInformationFile` reaches
that path, and so does anything built on it: `kernelbase!GetFileInformationByHandle` calls
`NtQueryVolumeInformationFile(FileFsVolumeInformation)` (info class 1) to fill
`dwVolumeSerialNumber`, and a .NET `DriveInfo` or a `GetVolumeInformation` call is enough. Every
such caller waits on a lock the spinning thread never releases.

### Starvation beyond mountmgr

All of wine's kernel drivers in one winedevice.exe are serviced by a single
`IOCTL_WINE_GET_NEXT_DEVICE_REQUEST` loop, so a dispatch routine that never returns starves every
other driver in that host, including nsiproxy. A title can therefore hang in an iphlpapi or socket
call that has nothing to do with drives (see Cyberpunk 2077 below).

### The trigger

The hang is host-dependent and title-independent. It needs a block device UDisks2 reports that has
no letter yet (`/dev/sdd` on the measured host) and a title that asks for volume information.
Unity's first act after Mono init is such a query, which is why every affected Unity title stops at
the same log line.

## Measurement

Measured on x86_64-linux with Space Engineers, read-only `dosdevices` bind:

- a winedevice.exe thread pinned at 99.4% CPU for 2m15s in `add_drive`;
- strace showing, on repeat,

      symlink("/dev/sdd", "…/dosdevices/d::") = -1 EROFS (Read-only file system)

- the game's main thread blocked in
  `NtQueryVolumeInformationFile → get_mountmgr_fs_info → server_wait_for_object`, never reaching its
  renderer;
- wine's own error line naming the section (propnix's default `WINEDEBUG=-all` hides it):

      err:sync:RtlpWaitForCriticalSection …
          "dlls/mountmgr.sys/device.c: device_section" wait timed out

## The row propnix ships

`dosdevices` is an overlay whose lower is the prefix lower's own `dosdevices` (wine's relative
symlinks `c:` → `../drive_c` and `z:` → `/`), with a tmpfs upper and `skeleton = null`. The two
lower entries are never modified; new letters go to the tmpfs upper and are discarded at exit.

It is ephemeral rather than persistent because the letters are a snapshot of the host's block
devices at launch, and caching them would only leave stale links to devices that are gone. Nothing
hermetic is lost: the new entries point at `/dev` nodes and unix mount points that the launch's
private mount namespace does not carry, so they dangle. What matters is that the symlink succeeds
and `add_drive` returns.

## Per title

### Unity titles: the log stops at `Mono config path = …`

Unity's first act after Mono init is a volume-information IOCTL, so on the read-only bind the player
log ends one line after `Mono config path = …`. The truncated log is a symptom of the host, not of
the game. Observed on R.E.P.O. (Unity 2022.3.67f2), Cities: Skylines (Unity 5.6) and Hollow Knight:
Silksong (Unity 6).

Hollow Knight: Silksong shows it most cleanly: the loading screen forever and a 113-byte Player.log
ending at `Mono config path = …`, where the next line would be
`Input System module state changed to: Initialized.` (Unity 6 enters through
`NtQueryVolumeInformationFile` → `get_mountmgr_fs_info`). Back to back on one headless sway, the
same propnix-launcher binary, two baked configs differing in nothing but this row:

    dosdevices = { mode = "ro"; type = "mount"; }       → 3/3 hang, last line `Mono config path = …`
    dosdevices = { type = "overlay"; skeleton = null; } → 3/3 reach the title scene

On the overlay row 18/18 further runs booted, six of them invoked exactly as a user does (plain
`nix run .#hollow-knight-silksong`), each leaving a 3085-byte Player.log and a screenshotted
language-select screen.

R.E.P.O. and Cities: Skylines need no per-title row for this hang once the overlay is in place; both
reach their main menus on x86_64-linux.

### Space Engineers

A managed .NET title. Its main thread hangs in `NtQueryVolumeInformationFile` before drawing
anything; the measurement above is from this title. With the overlay row (plus its own
`d3dcompiler_47` and `-skipintro` rows) it reaches the main menu.

### Cities: Skylines: an absent side-effect file proves nothing

On the read-only bind, `AppData/Roaming/GSE Saves/settings/configs.user.ini` (written by the
gbe_fork shim inside `SteamAPI_Init`) is absent after a run, which reads as "the title stops before
ColossalNative's LoadLibrary + SteamAPI_Init". That reading is sound logic on a false premise. With
`dosdevices` writable the file is written, the game does reach `SteamAPI_Init`, and its real stall
is one modal MessageBox later (the gbe_fork interface-revision mismatch, a separate bug). An absent
side-effect file proves nothing about intent when the process is wedged in the kernel before it gets
there.

### Cyberpunk 2077: nsiproxy starved by mountmgr

Same-day A/B on x86_64-linux (2026-09-03), the `dosdevices` row the only difference:

    dosdevices = ro mount → hang; watchdog fires at 120 s;
                            GameThread parked in ZwDeviceIoControlFile+0x14
    dosdevices = overlay  → renders; 126 of the same ioctls complete; no dump, no watchdog

On the hung boot the engine's watchdog raises
`Assert: : Watchdog timeout! (120 seconds) - …\engineWatchdog.cpp(198)` and writes a ReportQueue
minidump whose thread contexts resolve `GameThread` to
`ntdll.dll+0xece4 → ZwDeviceIoControlFile+0x14`. `PROPNIX_WINEDEBUG=-all,+winsock` names the call:
GameThread's last call on a hung boot is

    sock_ioctl handle 0x1a4, code 0x121000

`0x121000` is `IOCTL_NSIPROXY_WINE_ENUMERATE_ALL`
(`CTL_CODE(FILE_DEVICE_NETWORK, 0x400, METHOD_BUFFERED)`), the third round of a
`GetAdaptersAddresses`-shaped `0x121000`/`0x121008` sequence whose first two rounds complete. It is
an iphlpapi call starved by mountmgr, made through the same `NtDeviceIoControlFile` stub that
`AFD_POLL` uses, which is what makes it look like a socket wait and hence like GOG sign-in.

Ruled out for this hang:

- GOG sign-in. `.apply { maskFiles = [ "bin/x64/GameServicesGOG.dll" ]; }` loads the game with
  neither `GameServicesGOG.dll` nor `Galaxy64.dll` mapped, and it hangs identically: same watchdog,
  same `ZwDeviceIoControlFile+0x14`.
- The exe's SSD probe: `IOCTL_STORAGE_GET_DEVICE_NUMBER` (0x2D1080) and
  `IOCTL_STORAGE_QUERY_PROPERTY` (0x2D1400) over `\\.\PhysicalDrive%d`, about 1 ms each.
- hidraw: root-only 0600 on the measured host, and wine never opens it.

### Rust: a suspected instance

Rust (Unity/IL2CPP) intermittently freezes during `[Bootstrap] Initializing Steam`, with the loading
bar parked at `LOADING MENU PREFABS 99.0%` (the label lags one step) and `Player.log` ending at:

    [Bootstrap] Loading Menu Prefabs done in 5.44s
    [Bootstrap] Initializing Steam                  ← last line; no matching "done in"

The freeze carries this hang's signature. It is not confirmed to be this hang.

**Signature facts.**

- winedbg attached to the frozen process gives the same main-thread stack on two independent hangs:

      ntdll!NtQueryVolumeInformationFile   ← never returns
      kernelbase!GetFileInformationByHandle+0xd5
      steam_api64 +0x778c97 / +0x778984    ← the shim's static C++ runtime: CreateFileW, then query
      steam_api64 +0x1c937                 ← common_helpers::file_exist (std::filesystem)
      steam_api64 +0x50111 … +0xb36ac      ← Steam_Client() → create_localstorage_settings()
      steam_api64!SteamAPI_InitFlat+0x17
      gameassembly …  unityplayer …  rustclient        (Bootstrap+<Start>d__26.MoveNext)

  The return address `+0xd5` in wine's kernelbase.dll sits immediately after
  `call *__imp_NtQueryVolumeInformationFile`, with info class 1 (`FileFsVolumeInformation`) in the
  frame. This is the entry point of the Space Engineers hang.
- A syscall trace of the main thread shows wine opening `\Device\MountPointManager`, issuing
  `IOCTL_MOUNTMGR_QUERY_UNIX_DRIVE`, getting `STATUS_PENDING`, and blocking in `server_select` on
  the 16-byte `read(wait_fd, …, 16)` of a `struct wake_up_reply`, waiting for the completion APC.
  That is exactly the request `get_mountmgr_fs_info()` issues. On a run that passes, the APC arrives
  with `STATUS_NO_SUCH_DEVICE` (0xC000000E, the expected answer for a path inside the prefix) and
  init carries on. On a run that freezes it never arrives.
- The waiting thread accrues zero CPU time (utime/stime unchanged over 10 s of sampling): a blocked
  waiter, as in the Space Engineers measurement, where the CPU goes to winedevice.exe instead.
- It does not reproduce in a plain prefix, which has a writable `dosdevices`. The same wine build,
  the same shim DLL and an equivalent `steam_settings/` outside propnix
  (`wine rundll32 steam_api64.dll,SteamAPI_Init`) return every time and write
  `GSE Saves/settings/configs.user.ini`. A bare prefix with `drive_c/users` as a separate overlay
  mount reproduces nothing either.
- It is intermittent rather than configuration-dependent: on one x86_64 host, default config, three
  of the first four attempts froze and the next eight in a row reached the menu. The mountmgr hang
  depends on host state (whether a letterless block device is present), not on the title.
- Rust's recorded status run is dated 2026-09-03, the same date as the Cyberpunk 2077 `dosdevices`
  A/B; which `dosdevices` row each Rust run (freezing or passing) had baked is not recorded.

**Not yet observed.** The winedevice.exe side: no record of a winedevice.exe thread spinning in
`add_drive`, of the repeating `EROFS` symlink, or of the `device_section` timeout line (hidden by
the default `WINEDEBUG=-all`).

**Observations an explanation has to account for.** Two timing perturbations carry the bootstrap
past the freeze: attaching `strace` to the main thread, and `.apply { online = false; }`, which adds
nothing but `CLONE_NEWNET` (propnix-mount `enter_and_mount`). The freezes fell in a window when
several other wine games were being launched concurrently on the host and the passes came when runs
were serialised, but the load average was ~19-21 on 48 cores throughout, so load is a correlation,
not a cause.

**The A/B that confirms it.** On a host where UDisks2 reports a block device with no letter in the
prefix, run Rust several times on each of two builds whose baked launcher configs differ only in the
`dosdevices` row: the read-only bind (`type = "mount"`, `mode = "ro"`, over the prefix lower's
`dosdevices`) against the shipped overlay. Check the two `--config` JSONs before running
(`wine.mounts` rows merge per field, so an override of this row has to replace the whole row, not
just `type` and `mode`). It is this hang if:

- the read-only arm freezes at `[Bootstrap] Initializing Steam` on every run;
- during that freeze a winedevice.exe thread is near 100% CPU, strace on it shows the repeating
  `symlink(…, "…/dosdevices/…") = -1 EROFS`, and `PROPNIX_WINEDEBUG=-all,err+all` prints the
  `device_section` wait timeout;
- the overlay arm reaches the menu on every run, and its tmpfs upper (read through
  `/proc/<pid>/root`) gains the letter mountmgr adds.

If the overlay arm still freezes, this is not the cause, and the next lever is ntsync: the host
loads the `ntsync` module (nixos/propnix.nix), the hung process holds `/dev/ntsync` and dozens of
`anon_inode:ntsync` handles, and "a wait that is never woken although the waited-for event happened"
is the failure class kernel-backed sync objects introduce. Reproduce the freeze first (several
concurrent wine launches on the host), then re-run with `/dev/ntsync` masked: an `unshare -Umr`
wrapper that bind-mounts `/dev/null` over it before invoking the launcher is enough, since the
launcher's own user namespace inherits the outer mount table. A clean result either way is what a
wine bug report needs.

**Ruled out for the Rust freeze**, each by an isolated run:

- gbe_fork and its settings: the plain-prefix run above returns every time.
- `steam.emu.offline`: `Settings::is_offline()` has exactly three call sites in the pinned gbe_fork,
  all in `dll/steam_user.cpp` and all reachable only after `SteamAPI_Init` returns, and the stack
  shows the freeze inside that call. Every recorded freeze had `offline=0` in effect. Victoria 3
  blocks on the same wine primitive and is cured by that key, but raises its wait from a
  `RtlWakeAddressAll` spin inside the shim; only a PE-level backtrace tells the two apart
  (steam-entitlement.md, "Triage").
- The multi-depot game dir and the read-only game dir: the freeze occurs both with the game dir
  read-only and with it a persistent CoW overlay.
- A missing Steamworks interface: an unimplemented interface throws (a modal and an exit), it does
  not block.
- The network and the sandbox: the three `Curl error 6: Could not resolve host` lines name
  `config.uca.cloud.unity3d.com` and `cdp.cloud.unity3d.com`, which do not resolve on the host
  either, while `api.epicgames.dev` and `github.com` do. They are dead Unity telemetry endpoints.
- EAC: `RustClient.exe` is Facepunch's own EAC-free entry point.

**Disabling the shim is not a workaround.** `.apply { steam.emu.enable = false; }` makes this freeze
impossible, but the genuine `steam_api64.dll` then fails init and the loading screen freezes at the
same 99% with a stack trace above it; Rust has no working no-Steam path (steam-entitlement.md).

## Traps

- **A truncated Unity log is not a death point.** On this hang it is a symptom of the host. A
  headless weston manufactures the same truncated-log signature on titles that work
  (headless-test-harness.md), so boot a known-good control before reading the log at all.
- **An empty save dir or a missing side-effect file bounds nothing** while the process is wedged in
  the kernel (Cities: Skylines, above).
- **A hang that vanishes under tracing may be a changed mount table, not a race.** On Hollow Knight:
  Silksong, `PROPNIX_WINEDEBUG='+file'` made the hang vanish because a concurrent edit to the shared
  mount table had landed mid-session. Re-check the baked config (`nix build .#<app>`, then the
  launcher's `--config` JSON) before calling anything timing-dependent.
- **Judge over several runs.** A single launch proves nothing on an intermittent hang, and any
  change claimed as a fix has to hold across many runs (wine-hang-diagnosis.md).

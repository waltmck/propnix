# Diagnosing a hung wine title

A hung title (no crash, no exit, a splash or loading screen that never moves) is diagnosed by naming
the call each thread is blocked in, and only then asking why. Under propnix that means working from
the cheapest evidence to the most invasive: rule out the rig and the baked config, turn on the one
wine channel that names the last device call per thread (`+winsock`), read the engine's own hang
report if it writes one, attach winedbg for PE-level stacks, and trace syscalls and CPU time to tell
a blocked waiter from a spinning holder. Ablations through `.apply` then falsify theories cheaply.
This document is that recipe and the ways the evidence misleads. Causes diagnosed this way: the
host-dependent mountmgr hang (wine-mountmgr-dosdevices.md) and the Victoria 3 logon deadlock
(steam-entitlement.md).

## Before tracing

- **Check the rig.** Boot a known-good control first; a headless weston fails even the control and
  produces a truncated log that looks like a hang (headless-test-harness.md).
- **Check the baked config.** `nix build .#<app>`, then read the launcher's `--config` JSON, before
  calling anything timing-dependent. On Hollow Knight: Silksong, `PROPNIX_WINEDEBUG='+file'` made a
  hang vanish because a concurrent edit to the shared mount table had landed mid-session.
- **Count runs, not launches.** On an intermittent hang a single launch proves nothing, and a change
  claimed as a fix has to hold across many runs. Rust's intermittent freeze reached its menu eight
  times in a row after freezing three times in four on the same config.
- **Note the load.** Host load changes outcomes (headless-test-harness.md, "Load matters").

## Getting output at all

The launcher's seal pins `WINEDEBUG=-all` and scrubs inherited `WINE*`, so a plain `WINEDEBUG=…`
does nothing. `PROPNIX_WINEDEBUG` is passed through verbatim as `WINEDEBUG` and forwards the child's
piped stdout and stderr to the console; `PROPNIX_DEBUG=1` forwards the pipe without changing
`WINEDEBUG`.

The default `-all` also hides wine's `err:` class, including the line that names a deadlocked
critical section:

    err:sync:RtlpWaitForCriticalSection …
        "dlls/mountmgr.sys/device.c: device_section" wait timed out

`PROPNIX_WINEDEBUG=-all,err+all` brings back the `err:` class alone.

## The order that works

### 1. `+winsock`: the last device call per thread

    PROPNIX_WINEDEBUG=-all,+winsock nix run .#<app> --extra-sandbox-paths /propnix=/var/lib/propnix

Cheap, and it names the last socket or device ioctl each thread issued, with its control code. On a
hung Cyberpunk 2077 boot, GameThread's last call is `sock_ioctl handle 0x1a4, code 0x121000`, which
decodes as `CTL_CODE(FILE_DEVICE_NETWORK, 0x400, METHOD_BUFFERED)` =
`IOCTL_NSIPROXY_WINE_ENUMERATE_ALL`: an iphlpapi call, not a socket wait. It also shows what the
title is reaching for on the network (Cyberpunk 2077's GameThread resolving `galaxy-log.gog.com`).

### 2. `+loaddll`: what actually loaded

    PROPNIX_WINEDEBUG=-all,+loaddll nix run .#<app> …

Builtin versus native per module, when a shipped DLL looks shadowed, and how far startup got when
nothing else is written: on Civilization VI without `steam.emu.steamStub`, an exit (status 53) with
an empty save dir and an empty profile upper comes after the engine has fully loaded and DXVK has
started initialising.

### 3. The engine's own hang report

Engines with a watchdog write a minidump when it fires. Cyberpunk 2077 writes
`%LOCALAPPDATA%\REDEngine\ReportQueue\Cyberpunk2077-<date>-<pid>-<tid>\Cyberpunk2077.dmp`, which
lands on the persistent `drive_c/users` overlay (upper `$PROPNIX_STATE/wine/users`) and survives the
run. Reading one:

- The trailing `-<pid>-<tid>` names the thread that raised the report. On a hang it is the watchdog
  (tid 468, `WatchdogThread`), and the engine's assert text says so:
  `Assert: : Watchdog timeout! (120 seconds) - …\engineWatchdog.cpp(198)`.
- No ExceptionStream: it hung, it did not crash.
- No MemoryListStream means no call stacks, but the ThreadList still carries every thread's CONTEXT.
  Resolve each RIP against the dump's module list plus the export table of wine's own `ntdll.dll`
  (`lib/wine/x86_64-windows/ntdll.dll` in the wine package) and it names the blocked syscall per
  thread: `GameThread → ntdll.dll+0xece4 → ZwDeviceIoControlFile+0x14`.

A RIP parked in a syscall stub names the syscall, not the device: `NtDeviceIoControlFile` serves
`AFD_POLL` and nsiproxy alike. Pair the dump with step 1 to get the control code.

### 4. winedbg: PE-level stacks

    nsenter -t <pid> -m -U --preserve-credentials -- wine winedbg
    attach <win-pid>
    bt all

This enters the launch's mount and user namespaces and gives full Windows stacks, including frames
inside shipped DLLs and shims. It is the only tool that tells apart two hangs with the same syscall
signature: Rust and Victoria 3 both wait in `server_select` on a 16-byte `wake_up_reply`, but Rust's
wait comes from `NtQueryVolumeInformationFile` under `kernelbase!GetFileInformationByHandle` and
Victoria 3's from a `RtlWakeAddressAll` spin inside the Steam shim.

### 5. Syscalls and CPU time: waiter or spinner

- A thread blocked in a wineserver wait ends in `server_select` on the 16-byte
  `read(wait_fd, …, 16)` of a `struct wake_up_reply`. A full syscall trace of that thread names what
  it waits for (Rust: open `\Device\MountPointManager`, `IOCTL_MOUNTMGR_QUERY_UNIX_DRIVE`,
  `STATUS_PENDING`, then the wait).
- Sample each thread's utime/stime. A waiter accrues zero CPU (Rust's main thread: unchanged over a
  10-second sample). A holder that never releases may be spinning: Space Engineers' hang has a
  winedevice.exe thread at 99.4% CPU for 2m15s, and strace on it shows the same failing
  `symlink(…) = -1 EROFS` on repeat. Look at every process in the prefix, not just the game.
- Attaching strace perturbs timing. On Rust it carries the bootstrap past an intermittent freeze, so
  a run that passes under strace says nothing about the race.

### 6. `+debugstr`: low yield, title-dependent

wine routes `OutputDebugStringA/W` to the `debugstr` channel:

    PROPNIX_WINEDEBUG=-all,+debugstr nix run .#<app> …

A release build need not push its log channels there. Measured on Cyberpunk 2077 (whose exe imports
OutputDebugStringA/W and carries `LogChannel`/`LogChannelError`/`LogChannelWarning`): a whole boot
prints four lines (one Streamline `sl.interposer` line skipping its IDXGIFactory proxy, three Intel
XeSS/XeLL lines) plus, on a hung boot, the engine's watchdog assert.

The channel is most useful with a DLL that propnix itself supplies. To see how a title drives a stub
(the Galaxy stub, a Steam shim), build a copy with one logging thunk per export and per vtable slot,
with per-interface identity, and run it under `PROPNIX_WINEDEBUG=-all,+debugstr`.

## Ablations and diagnostic overrides

An override is a function call, which a `.#attr` installable cannot express, so it goes through an
expression:

    S='(builtins.getFlake (toString ./.)).legacyPackages.${builtins.currentSystem}.<app>'
    nix run --impure --expr "$S"'.apply { online = true; }'

The forms worth having:

- `.apply { online = true; }` drops the network namespace. Diagnostic only, never a fix: on Rust,
  `online = false` (which adds nothing but `CLONE_NEWNET`) perturbs timing enough to pass an
  intermittent freeze.
- `.apply { maskFiles = [ "<path>" ]; }` removes a shipped file. It is the cheap falsifier for "this
  DLL causes the hang": masking Cyberpunk 2077's `bin/x64/GameServicesGOG.dll` leaves neither it nor
  `Galaxy64.dll` mapped, and the game hangs identically, so the GOG plugin is not the cause.
  Whiteouts are refused over a multi-lower game dir (DLC, `extraLowers`, `steam.emu`), so run masks
  with no DLC enabled.
- A one-row A/B: two builds whose baked `--config` JSONs differ in exactly one row, run back to back
  on the same rig. The `dosdevices` row is proven this way (wine-mountmgr-dosdevices.md).
- An ablation that deletes the code path deletes the symptom with it. Check what replaces it: Rust
  without its Steam shim cannot freeze in the shim, and freezes at the same loading screen for a
  different reason.

## Reading the evidence

- **An absent side-effect file bounds nothing.** Cities: Skylines' missing `configs.user.ini` reads
  as "stopped before `SteamAPI_Init`" while the process is actually wedged in the kernel before
  reaching it. Civilization VI's SteamStub exit (status 53, no window, save dir and profile upper
  empty) comes after the engine has fully loaded, because the wrapper's ownership check runs inside
  the process's own startup and exits before the engine opens a file. Reach for a loader or relay
  trace before reading anything into an empty directory.
- **An absent log line is not a cause.** Cyberpunk 2077's hang reads like a GOG sign-in stall from
  its log; the mask ablation and `+winsock` put it in mountmgr.
- **A truncated log is not a death point.** Unity's log buffering differs between players
  (headless-test-harness.md); name the blocked call instead.
- **A hang that vanishes under tracing** is either a timing perturbation (strace on Rust) or a
  changed config (the Silksong mount table). Rule out the second by re-reading the baked config.

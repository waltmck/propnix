# Headless test harness for wine titles

A wine title can be launched, rendered and screenshotted with no display attached, which is how most
per-title run verdicts are produced. The rig is a wlroots compositor (sway) with
`WLR_BACKENDS=headless` on the real GPU, a known-good control title booted first, and `grim` for the
evidence. Headless weston is not a valid rig: it breaks wine's display-driver bring-up and
manufactures a truncated-log symptom on titles that work everywhere else. The rig has no usable
input devices, so it verifies a title up to its first modal dialog and no further, and host load
changes outcomes. This document holds the setup, the control, the rig's limits, and how to read the
game's output while reproducing.

## sway, not weston

Under `weston --backend=headless`, with either renderer (with or without `--renderer=gl`), the
known-good control `iron-lung` fails: the game process never loads `winewayland.drv` and dies on

    err:winediag:nodrv_CreateWindow … The explorer process failed to start

leaving a 100-byte `Player.log`. That is the same "two Mono lines and die" signature as a real hang
(for example the read-only dosdevices hang, wine-mountmgr-dosdevices.md), so a weston run cannot
tell a real bug from the compositor, and weston writes almost nothing either way. Recorded on the
Civilization VI, Rust, Cities: Skylines and R.E.P.O. harnesses with iron-lung as the control, and on
Cyberpunk 2077's with a known-good title.

Headless sway (`WLR_BACKENDS=headless`) passes the same control on the real GPU (an AMD Radeon RX
7900 XTX on the x86_64-linux host) and is the rig behind the headless verdicts for Space Engineers,
Cities: Skylines, Civilization VI and Rust.

## Setup

    R=/tmp/pnx-rust; mkdir -p $R; chmod 700 $R     # SHORT path: sun_path is 108 bytes
    export XDG_RUNTIME_DIR=$R
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 nix run nixpkgs#sway -- -c /dev/null &
    export WAYLAND_DISPLAY=wayland-1
    PROPNIX_DEBUG=1 nix run .#iron-lung            # control: must render
    PROPNIX_DEBUG=1 nix run .#<app>
    nix run nixpkgs#grim -- shot.png               # the evidence

`swaymsg create_output` adds a headless output; the Space Engineers verdict uses it. Add
`--extra-sandbox-paths /propnix=/var/lib/propnix` to the `nix run` of a title whose payload still
has to be fetched.

## The control: iron-lung

`nix run .#iron-lung` is the control to boot first, every time. It is a tiny GOG Unity title (D3D11
→ DXVK → Vulkan) that the owner plays, on the same wine stack; it renders on every valid rig and
fails on weston. A failing control means the rig is wrong, not the title.

## What counts as rendered

- A `grim` capture of the compositor output showing the title's own UI (Space Engineers: a fully
  rendered 1920x1080 VRage GUI frame).
- Successive captures that differ, so the frame is a live render and not a stuck first frame
  (Cities: Skylines' animated main menu).
- The process still alive when the timeout kills it: `nix run` returning 137 under a timeout, or
  exit 137 from `timeout -s KILL`, never a crash.
- The engine's own log agreeing with the pixels (a main-menu screen's `LoadContent`, a renderer line
  naming the real GPU).

## Input: what the rig cannot do

A headless sway seat reports `capabilities: 0, devices: []`. A transient `wlr_virtual_pointer` is
enough for a title to show hover state: Space Engineers highlights its OK button and shows the
"Proceed" tooltip. No synthetic button press or keystroke activates a control, so Space Engineers'
first-run `MyGuiScreenGDPR` and `MyGuiScreenWelcomeScreen`, which sit on top of the loaded main
menu, stay up. The same rig drives the control's menu, so this is a property of the rig, not of a
title, and a real session has real devices.

`wtype` cannot reach winewayland either: its `zwp_virtual_keyboard` input does not arrive, and
Cyberpunk 2077's title screen ignores space and Return from it while the game keeps animating.

Consequences:

- A headless verdict ends at the first modal or first-run dialog: Space Engineers' GDPR/Welcome
  stack, Rust's "TUTORIAL / Crashed Pilot" dialog, Civilization VI's title card with its live
  `Continue` button.
- Anything past that, and any in-game toggle (Cyberpunk 2077's HDR mode), needs a human at the
  keyboard on a real session. Cyberpunk 2077's render verdict comes from the real Hyprland session.
- A title that waits for window focus cannot be judged unattended at all. Shadow of Mordor stays
  black on its loading spinner while unfocused and exits 0 after about ten minutes; focused, it
  reaches the game. Low CPU with a growing DXVK shader log is that wait, not a hang.

## Load matters

Host load changes outcomes. One Space Engineers launch under a load average of ~20 (many concurrent
wine prefixes) died during cold start; the identical build at load ~3 reached the menu. Rust's
intermittent freeze fell in a window of concurrent wine launches, though load stayed at ~19-21 on 48
cores throughout and is a correlation there, not a cause. R.E.P.O. rendered on a busy machine (load
~7.6, five other wineservers alive), so load does not fail every title.

Rules: run verification launches serialised, note the load average and the number of live
wineservers with each run, and re-run before reading a single failure as a regression.

## Seeing the game's output

The launcher's seal pins `WINEDEBUG=-all` and scrubs inherited `WINE*` variables, so setting
`WINEDEBUG` directly does nothing. Two knobs replace it:

    PROPNIX_DEBUG=1 nix run .#<app> --extra-sandbox-paths /propnix=/var/lib/propnix
    PROPNIX_WINEDEBUG=+loaddll,+seh nix run .#<app> --extra-sandbox-paths /propnix=/var/lib/propnix

`PROPNIX_DEBUG=1` forwards the child's piped stdout and stderr to the console (otherwise the
launcher drains the pipe silently). `PROPNIX_WINEDEBUG` is passed through verbatim as `WINEDEBUG`
and also forwards the pipe. wine-hang-diagnosis.md has the channels worth enabling.

## Unity logs: `-logfile -` and Player.log

Rust and R.E.P.O. write `Player.log` under the profile's `AppData/LocalLow` tree, which their save
binds cover, so it lands at `$PROPNIX_SAVE_DIR/<appid>/Player.log`. Unity 5.6 (Cities: Skylines)
defaults to `Cities_Data/output_log.txt` inside the read-only game dir and writes no log unless
redirected with `-logfile <path>`. `-logfile -` sends the log to stdout instead, which reaches the
console under `PROPNIX_DEBUG=1` (`nix run .#<app> -- -logfile -`; arguments after `--` go to the
game). The two titles that exercised both record opposite buffering:

- Rust (Unity, IL2CPP): stdout goes through a pipe and is block-buffered, so the `-logfile -` tail
  lags the process by kilobytes, while `Player.log` is flushed.
- Hollow Knight: Silksong (Unity 6, player 6000.0.50f1): `Player.log` is buffered and flushed at
  exit, so a truncated `Player.log` only says "killed or hung", never where; `-logfile -` with
  `PROPNIX_DEBUG=1` is the view that keeps up.

Use `-logfile -` with `PROPNIX_DEBUG=1` as the live view and read `Player.log` as the post-mortem
after the process exits. On a hung process neither is authoritative about where it stopped: name the
blocked call with a wine-level trace or a debugger (wine-hang-diagnosis.md).

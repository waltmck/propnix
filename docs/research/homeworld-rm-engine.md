# The Homeworld Remastered engine

`HomeworldRM.exe` is Gearbox's 2015 remaster engine for Homeworld 1 and 2, derived from the
Homeworld 2 engine, shipped in the GOG Homeworld Remastered Collection and run under wine (WoW64
through box64's `wowbox64.dll` on aarch64, native WoW64 on x86_64). This doc records what the engine
does that the package has to match: how it finds its data, where its resolution comes from, how it
reads command-line options from a file, and why it runs under winex11. Addresses are virtual
addresses in the pinned GOG build of `HomeworldRM.exe`.

## The binary

- PE32 i386, as are the HW1/HW2 Classic exes and the `HWRStart.exe` chooser.
- The renderer is OpenGL (a static `OPENGL32.dll` import), so it draws through wine's builtin
  opengl32 to host GL. The i386-windows default `d3d = wined3d` applies: DXVK is ARM64EC-only and
  unusable by a 32-bit process, and `d3d = dxvk`'s native-only overrides (`d3d11=n;dxgi=n;…`) would
  send any incidental 32-bit d3d `LoadLibrary` to a native DLL that exists only in system32, not
  syswow64.
- The launch target is `HomeworldRM/Bin/Release/HomeworldRM.exe`, not the `isPrimary`
  `HWRStart.exe`, which spawns the picked game and exits.
- It statically imports the 32-bit GOG Galaxy SDK (`Galaxy.dll`, beside the exe). The no-op stub
  cannot stand in for it on i386, and the real SDK takes its own offline path behind the kernel
  netns (docs/research/galaxy-sdk-offline.md).

## The data path comes from the cwd

The engine resolves its data root from the working directory. Measured 2026-09-03 on x86_64-linux:

- From cwd = `C:\game` it writes `HwRM.log` with ` Error starting up Data path. ` and exits without
  a window.
- From cwd = `HomeworldRM\Bin\Release` it maps its "Homeworld Remastered" window within ~12 s and
  stays up.

GOG's `goggame-2114871440.info` agrees: the hidden "Homeworld Remastered" play task carries
`"workingDir": "HomeworldRM/Bin/Release"`. The engine's own log corroborates the cwd-relative
layout: it reports its `.big` misses as `..\..\DATAUPDATES\…`, relative to `Bin\Release`.

The engine also needs write access to its install folder. With a read-only game bind it aborts at
startup with a message box, "Unable to run Homeworld2, Administrative access to this folder is
required." (GOG's `goggame.info` flags `HWRStart.exe` `RUNASADMIN`.) The package therefore mounts
`drive_c/game` as a persistent copy-on-write overlay over the payload.

## Resolution: the profile, overwritten by the command line

The engine never asks the display how big it is. Its resolution comes from the player profile, whose
fallback is a hardcoded 1920x1080, pushed as the default to the profile getter at VA 0x41503a /
0x415051. Measured on a 3840x2160 output with no options file, `HwRM.log` reports

    Switching to a 1920x1080 32bit mode
    Display: (0, 0, 1920, 1080)
    CmdLine:

that is, a quarter-area window and an empty command line.

The video-settings resolver at VA 0x415032 reads `screenResolutionW`, `screenResolutionH` and
`screenFullscreen` from the profile first and then lets the command line overwrite them. Options
supplied on every launch therefore self-correct across a resolution or monitor change and also work
on a fresh prefix with no profile. The relevant switches, with their spellings and semantics from
the exe's own code:

- `w` / `h`: `cmdline_get_int("w", &v)` / `cmdline_get_int("h", &v)` at 0x4150f3 / 0x41511e. Clamped
  to a floor of 1024x768 unless `-forceResolution` is also given. propnix does not pass
  `forceResolution`: the clamp only bites below 1024x768, and on a display that small the engine's
  own minimum is a safer answer than a window it may not be able to render.
- `fullscreen`: `cmdline_has("fullscreen")` at 0x4150ca forces fullscreen on; `windowed`, at
  0x4150dd, is the opposite switch. The profile default is already fullscreen, but a profile that
  has been set windowed would otherwise give a correctly sized window instead.

This is why the setup script writes `w`, `h` and `fullscreen` on every launch, from the compositor's
primary-output mode (`PROPNIX_WIDTH`, `PROPNIX_HEIGHT`, physical pixels). When the launcher cannot
read the display the script leaves the file alone: a stale resolution, or the empty file the mount
row created, is better than a half-written one.

## `commandLine.txt`: options from a file

Before parsing argv, the option-map bootstrap at VA 0x7a9b6f seeds `params = ../commandLine.txt`,
and the engine then opens that literal relative path with `fopen(…, "rt")` at VA 0x7a9822 and parses
it with the same parser argv gets. The file is the engine's supported way to supply command-line
options that are not on the command line, which is what a live display size needs: `exeArgs` is
baked at build time and passed to the child verbatim, with no `$VAR` expansion.

### Format (parser at 0x7a9822)

- One option per line; a leading `-` or `+` is optional and stripped.
- `#` in the first column starts a comment.
- Names match case-insensitively.
- A line is `name = value`, `name value`, or a bare flag.
- LF line endings are fine: the reader is `fscanf(" %511[^\n]")`.

The generated file:

    # Generated by propnix on every launch from the compositor's primary output. Edits are lost.
    fullscreen
    w = <PROPNIX_WIDTH>
    h = <PROPNIX_HEIGHT>

### Where the file goes

A relative `fopen` resolves against the cwd, and the cwd is `HomeworldRM/Bin/Release`, so the file
the engine opens is `HomeworldRM/Bin/commandLine.txt`. The target is coupled to `workingDir` and
moves with it. The mount row:

    mounts."drive_c/game/HomeworldRM/Bin/commandLine.txt" = {
      type = "file";
      source = "$PROPNIX_STATE/commandLine.txt";
      mode = "ro";
      createIfNotExist = true;
    };

- `type = "file"`: the source is a single regular file, and `createIfNotExist` touches it rather
  than creating a directory (a directory there would make the engine's `fopen` fail obscurely).
- The launcher resolves the mount table, creating the source, before it runs the setup script, so
  the script always writes into an existing file.
- `mode = "ro"`: the file is generated state and the game only reads it.
- The file does not exist in the payload. The game-dir overlay stubs every declared child as a
  mountpoint, so the row needs nothing more.

## winewayland crashes the explorer host: `graphics = "x11"`

Under winewayland the 64-bit `explorer.exe` (the desktop and window-driver host, running under FEX
on aarch64) crashes during window creation for this 32-bit game:

    err:seh:NtRaiseException Exception frame is not in stack limits => unable to dispatch exception
    err:winediag:nodrv_CreateWindow ... The explorer process failed to start

The first line comes from explorer's winewayland thread; the game then aborts with no window.
Routing through winex11.drv (Xwayland) avoids the winewayland window path entirely, and the window
comes up. Skyrim Special Edition also pins `graphics = "x11"`, for an unrelated winewayland failure
(fractional-scale resizes drive a DXVK swapchain-recreation loop that NULL-derefs winevulkan;
docs/research/winewayland-fractional-scaling.md).

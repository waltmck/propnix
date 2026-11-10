# Homeworld Remastered Collection — per-title tuning over the wine backend's platform-aware defaults
# (lib/backends/wine/defaults.nix). HomeworldRM.exe is i386 and renders through a static OPENGL32
# import, so the i386 default d3d = wined3d applies unchanged (see default.nix).
#
# A FUNCTION of `payload` (default.nix applies it) because the writable game-dir overlay references the
# payload's store path directly (same pattern as KSP).
{ payload }:
{
  # Graphics driver: x11 (XWayland), NOT the default winewayland. With winewayland the 64-bit explorer.exe
  # (the desktop/window-driver host, run under FEX) crashes during winewayland window creation for this
  # 32-bit game — `err:seh:NtRaiseException Exception frame is not in stack limits => unable to dispatch
  # exception` in its winewayland thread → `err:winediag:nodrv_CreateWindow ... The explorer process failed
  # to start` → the game aborts with no window. Routing through winex11.drv (XWayland) avoids the
  # winewayland init/window path entirely and lets the window come up. (Skyrim SE also pins x11,
  # for an unrelated winewayland failure.)
  graphics = {
    value = "x11";
    reason = "winewayland window creation crashes the FEX-hosted 64-bit explorer.exe (SEH cannot be dispatched — Exception frame not in stack limits) → nodrv_CreateWindow, game aborts windowless; winex11/XWayland brings the window up.";
  };

  # No `galaxyStubDlls`: defaults.nix refuses it on i386; offline is `online = false` (default.nix).

  # The HWRM engine requires WRITE access to its own install folder — with a read-only game bind it aborts at
  # startup with a message box: "Unable to run Homeworld2, Administrative access to this folder is required."
  # (The GOG goggame.info even flags HWRStart.exe RUNASADMIN.) Override the default read-only `drive_c/game`
  # bind with a PERSISTENT CoW overlay (same as KSP): reads fall through to the store payload (no copy, shared
  # page cache), every write the engine makes to its dir persists to app state.
  mounts."drive_c/game" = {
    type = "overlay";
    lower = "${payload}";
    upper = "$PROPNIX_STATE/gamedir";
    createIfNotExist = true;
  };

  # The engine's own command-line-options FILE, generated per launch by setup.sh (see there for the
  # switches and why they cannot be `exeArgs`); this row is the only thing that knows WHERE the
  # engine looks for it. HomeworldRM.exe fopens the relative path `../commandLine.txt`, which
  # resolves against the cwd that default.nix pins to `HomeworldRM/Bin/Release`: the target is
  # HomeworldRM/Bin/commandLine.txt and moves with `workingDir`.
  #
  # `type = "file"`: `createIfNotExist` touches a regular file (a directory here would make the
  # engine's fopen fail obscurely), during mount-table resolution, which the launcher runs BEFORE
  # the setup script, so setup.sh always writes into an existing file. `mode = "ro"`: generated
  # state the game only reads. The file is not in the payload; the game-dir overlay above stubs
  # every declared child as a mountpoint. Addresses: docs/research/homeworld-rm-engine.md.
  mounts."drive_c/game/HomeworldRM/Bin/commandLine.txt" = {
    type = "file";
    source = "$PROPNIX_STATE/commandLine.txt";
    mode = "ro";
    createIfNotExist = true;
  };
}

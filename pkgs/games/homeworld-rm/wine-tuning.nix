# Homeworld Remastered Collection — per-title tuning. Layered over the wine backend's platform-aware
# defaults (lib/backends/wine/defaults.nix), so this states only what is SPECIFIC to Homeworld RM. Gearbox's
# 2015 remaster of Homeworld 1 & 2 (space RTS). NOTE: HomeworldRM.exe is a 32-bit (i386) binary that
# STATICALLY imports OPENGL32.dll (its renderer is OpenGL, not a static D3D11 import) — see default.nix for
# the arch note. The i386-windows platform default d3d = wined3d is doubly right here: the game renders
# through wine's builtin opengl32 → host GL anyway, and d3d=dxvk's global `d3d11=n;dxgi=n;…` ("native only")
# WINEDLLOVERRIDES would make any incidental 32-bit d3d LoadLibrary try to load a native DLL that only
# exists in system32 (not syswow64) and fail — wined3d keeps the override map clean.
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
  # winewayland init/window path entirely and lets the window come up. (Same graphics=x11 escape hatch
  # Skyrim SE / NMS use for their own winewayland failures.)
  graphics = {
    value = "x11";
    reason = "winewayland window creation crashes the FEX-hosted 64-bit explorer.exe (SEH cannot be dispatched — Exception frame not in stack limits) → nodrv_CreateWindow, game aborts windowless; winex11/XWayland brings the window up.";
  };

  # NO `wine.galaxyStubDlls` — deliberately, and it is a finding rather than an omission. HomeworldRM.exe
  # STATICALLY imports Galaxy.dll (the 32-bit GOG Galaxy SDK bundled beside the exe in
  # HomeworldRM/Bin/Release), pulling in exactly the four GalaxyFactory statics CreateInstance /
  # GetInstance / ResetInstance / GetErrorManager (dumped from the PE import table), so the row looks
  # obviously right — and it is NOT. The stub's uniform zero-argument vtable is only ABI-valid where the
  # CALLER cleans the stack; this is a 32-bit title, where the SDK's interfaces are __thiscall and the
  # CALLEE pops. Bound here it crashed the game before it ever drew: `IGalaxy::Init(clientID,
  # clientSecret, 0)` returned without popping its 12 bytes, so the caller's `ret` jumped to the clientID
  # string and the game's own handler reported "Access Violation … at 0023:008e6060". The full
  # disassembly + crash-log evidence is on the `galaxyMounts` derivation in
  # lib/backends/wine/defaults.nix, which now REFUSES this knob on i386 rather than emitting the row.
  # The offline guarantee is `online = false` in default.nix — kernel-enforced, so it does not depend on a
  # stub being a faithful no-op.

  # The HWRM engine requires WRITE access to its own install folder — with a read-only game bind it aborts at
  # startup with a message box: "Unable to run Homeworld2, Administrative access to this folder is required."
  # (The GOG goggame.info even flags HWRStart.exe RUNASADMIN.) Override the default read-only `drive_c/game`
  # bind with a PERSISTENT CoW overlay (same as KSP): reads fall through to the store payload (no copy, shared
  # page cache), every write the engine makes to its dir persists to app state. The galaxy-stub bind above
  # (a child of drive_c/game) layers on top of this overlay unchanged.
  mounts."drive_c/game" = {
    type = "overlay";
    lower = "${payload}";
    upper = "$PROPNIX_STATE/gamedir";
    createIfNotExist = true;
  };

  # The engine's own command-line-options FILE, generated per launch by setup.sh (see there for the switches
  # and why they cannot be `exeArgs`). This row is the only thing that knows WHERE the engine looks for it.
  #
  # THE PATH IS DERIVED, NOT GUESSED, and it is coupled to `workingDir`: HomeworldRM.exe opens the literal
  # relative path `../commandLine.txt` with `fopen(…, "rt")` (VA 0x7a9822, reached from the option-map
  # bootstrap at 0x7a9b6f which seeds `params = ../commandLine.txt` before argv is parsed). A relative fopen
  # resolves against the CWD, and default.nix pins cwd to `HomeworldRM/Bin/Release` — hence
  # HomeworldRM/Bin/commandLine.txt. (Corroborated by the same log the data-path finding came from: the engine
  # reports its .big misses as `..\..\DATAUPDATES\…`, i.e. cwd-relative from Bin\Release.) If `workingDir`
  # ever moves, this target moves with it.
  #
  # `type = "file"` because the source is a single regular file (`createIfNotExist` TOUCHES it rather than
  # mkdir'ing it — a directory here would make the engine's fopen fail obscurely), and the source is created
  # during mount-table resolution, which the launcher runs BEFORE the setup script, so setup.sh always writes
  # into an existing file. `mode = "ro"`: the file is generated state, and the game only ever reads it.
  # The file does NOT exist in the payload; the game-dir overlay above stubs EVERY declared child as a
  # mountpoint (propnix-mount: "For an OVERLAY, stub EVERY child"), so it does not have to.
  mounts."drive_c/game/HomeworldRM/Bin/commandLine.txt" = {
    type = "file";
    source = "$PROPNIX_STATE/commandLine.txt";
    mode = "ro";
    createIfNotExist = true;
  };
}

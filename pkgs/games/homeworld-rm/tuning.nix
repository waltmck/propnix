# Homeworld Remastered Collection — per-title tuning. Layered over lib/wine-defaults.nix
# (sealing.mergeTuning), so this states only what is SPECIFIC to Homeworld RM. Gearbox's 2015 remaster
# of Homeworld 1 & 2 (space RTS). NOTE: HomeworldRM.exe is a 32-bit (i386) binary that STATICALLY imports
# OPENGL32.dll (its renderer is OpenGL, not a static D3D11 import) — see default.nix for the arch note.
#
# A FUNCTION of `payload` (makeAppWine calls it) because the writable game-dir overlay references the
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

  # d3d = wined3d (NOT the default native DXVK). Two reasons, both consequences of the 32-bit binary:
  #   1. propnix's DXVK/vkd3d are native ARM64EC (64-bit) PEs, mounted only into system32 and usable only by
  #      x86_64/ARM64EC processes. A 32-bit (i386) process loads its D3D DLLs from syswow64, where no native
  #      DXVK exists — so DXVK simply cannot serve this game.
  #   2. With d3d=dxvk the launcher forces WINEDLLOVERRIDES `d3d11=n;dxgi=n;…` ("native only") GLOBALLY. For
  #      the 32-bit process that means "load a native d3d11 that isn't there" → the D3D device creation fails.
  # HomeworldRM.exe renders through its statically-linked OPENGL32 path anyway (wine's builtin opengl32 → host
  # GL via the winewayland/x11 driver), so DXVK is moot; wined3d keeps the DLL-override map clean and lets any
  # incidental d3d LoadLibrary fall back to wine's builtin 32-bit wined3d.
  d3d = {
    value = "wined3d";
    reason = "HomeworldRM.exe is 32-bit (i386) and renders via its static OPENGL32 import; native ARM64EC DXVK cannot be loaded by a 32-bit process (it lives in system32, not syswow64), and d3d=dxvk's global `d3d11=n` override would break any d3d LoadLibrary. wined3d keeps the override map clean.";
  };

  # HomeworldRM.exe STATICALLY imports Galaxy.dll (the 32-bit GOG Galaxy SDK, bundled beside the exe in
  # HomeworldRM/Bin/Release), pulling in the GalaxyFactory statics (CreateInstance/GetInstance/ResetInstance/
  # GetErrorManager — verified in the PE import table). The SDK's offline RPC init faults wine's builtin
  # rpcrt4 before the first frame (same class as Prison Architect), so bind the graceful no-op stub over it
  # (aarch64). galaxy-stub builds a 32-bit Galaxy.dll matching the game's arch; a no-op on x86_64 native wine.
  galaxyStubDlls = [ "HomeworldRM/Bin/Release/Galaxy.dll" ];

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
}

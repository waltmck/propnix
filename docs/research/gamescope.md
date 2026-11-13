# gamescope as the game's compositor

Every game runs nested in gamescope's Wayland backend (`emulators/gamescope`,
`pkgs/propnix-launcher/src/gamescope.rs`). This document collects what that backend does and does
not do, as read from the 3.16.25/3.17.0 source and measured on an Asahi M2 under Hyprland 0.57
(eDP-1 2560x1664 at scale 1.6, with a compositor patch that keeps the notch out of fullscreen).

## Render-only GPUs (patch 0001)

Stock gamescope refuses to start nested on Asahi:

    vulkan: physical device has no primary node

AGX is a render-only DRM device; the display controller is a separate one, so
`VkPhysicalDeviceDrmPropertiesEXT.hasPrimary` is false. The check rejects any backend that does not
present through a Vulkan swapchain, which includes the Wayland and headless backends, and gamescope
then falls back to SDL, which fails too (`Failed to create backend`). The primary node's dev_t is
read only by the DRM backend (`vulkan_primary_dev_id`, `DRMBackend.cpp`), so the patch gates the
requirement on the session-based backend. Upstream HEAD carries the same check.

## Window identity (patch 0002)

The host toplevel's app_id is hard-coded `"gamescope"` (set at creation and again when the
toplevel is restored after a NULL-buffer unmap — the restore is new in 3.17.0). Its title follows
the focused X window's `_NET_WM_NAME`/`WM_NAME`, plus `" (grabbed)"` under `-g`. `WM_CLASS` is
never used. Icons are forwarded through `xdg_toplevel_icon_v1` from `_NET_WM_ICON`, which Hyprland
does not advertise; app_id → desktop entry is the portable route.

## When the host window exists

The toplevel object is created before the child is spawned, but it gets its first buffer only when
gamescope has a focused nested window with a completed commit. It is unmapped again (NULL buffer)
whenever there is no focus window. So the host sees nothing until the game draws, and a game that
swaps one window for another briefly has no host window.

gamescope publishes the window it shows as `GAMESCOPE_FOCUSED_WINDOW` (CARDINAL) on its nested X
server's root, in every mode (not only Steam mode). That is the launcher's window signal.

## Focusing the window (patch 0004)

Upstream gamescope's Wayland backend binds no xdg-activation, so the only way for anything else to
focus its window is compositor-specific window management (wlr-foreign-toplevel, KDE's
plasma-window-management with its desktop-file grant), and GNOME offers a foreign client none. The
patch binds `xdg_activation_v1` and takes requests through a root property on its X server,
`GAMESCOPE_XDG_ACTIVATION_TOKEN` (read and deleted in one `XGetWindowProperty`, so the PropertyDelete
it causes finds nothing): a non-empty value is a token to activate with; an empty one makes gamescope
request a token itself, stamped with the serial of its last input event.

What a token earns is compositor policy. Hyprland 0.57 (`src/protocols/XDGActivation.cpp`,
`CWindow::activate`): token creation requires a valid input serial from the requesting client (a
short-lived process with no input gets an empty `done`); activation always sets the urgent hint and
focuses only with `misc:focus_on_activate` or a `focus_on_activate` window rule (default off). Hyprland's
`exec` sets no `XDG_ACTIVATION_TOKEN`. GNOME and KDE focus with a token from a desktop launch (the entry
needs `StartupNotify=true`) and treat a self-requested one without a fresh user action as an attention
request.

## Sizes

- The OUTPUT (gamescope's window) follows every `xdg_toplevel.configure`, in physical pixels
  (`wp_fractional_scale_v1` + `wp_viewporter`). On the notch-patched compositor, fullscreen
  configures 1600x1005 logical → 2560x1608.
- The NESTED X screen the game sees is fixed at launch: `-w/-h`, else `-W/-H`, else 1280x720
  (`main.cpp`). It never follows a configure.
- At runtime the only resize is the root property `GAMESCOPE_XWAYLAND_MODE_CONTROL` =
  `[server, w, h, allowSuperRes]` (Steam's mechanism), clamped to the current output unless
  `allowSuperRes`. Verified: setting 2560x1608 resized the nested screen live. It can only act after
  the game is already running, and games that read their modes once at startup do not follow.
- A size smaller than the nested screen is letterboxed: the AUTO scaler fits the focused window to
  the output with no upscale cap (`g_flMaxWindowScale` defaults to FLT_MAX).
- The `-F` upscalers (FSR 1, NIS, SGSR) are portable Vulkan shaders run in gamescope's composite pass,
  and only while upscaling on both axes (`needsScaling`, `steamcompmgr.cpp`): at 1:1 there is no pass,
  and a downscale is the host's bilinear (`linear`/`fsr`/`nis`/`sgsr`) or gamescope's composite
  (`nearest`/`pixel`). Measured on Honeykrisp, a 640x400 vkcube upscaled to 2560x1608: all three run;
  FSR's edges are the cleanest, SGSR shows more stair-stepping on diagonals, `linear` is soft. Hence
  `fsr` as the launcher default.

The notch-excluded fullscreen size cannot be learned before launch. An UNMAPPED xdg_toplevel that
requests fullscreen gets the tiled size in its initial configure on Hyprland (800x502 measured), no
fullscreen state and no preferred scale; the fullscreen size arrives only once a window is mapped.
Hence the contract: `PROPNIX_WIDTH/HEIGHT` (default: the output's mode) size gamescope, and a user
on such a compositor sets `PROPNIX_HEIGHT` to the fullscreen area.

## Wayland clients inside gamescope

`--expose-wayland` makes gamescope serve a Wayland display to the game (and point `WAYLAND_DISPLAY` at
it), but its server is minimal: no `wl_subcompositor`, and only a nested client's main surface is
composited. winewayland requires the subcompositor and draws through subsurfaces; under
`PROPNIX_WINE_GRAPHICS=wayland` Hollow Knight logged `waylanddrv:wayland_process_init Wayland compositor
doesn't support wl_subcompositor`, then `nodrv_CreateWindow` and exit 1. The wine path therefore accepts
`graphics = "x11"` only. An SDL game set to `wayland` still gets `--expose-wayland`; whether SDL's Wayland
backend runs on that server is untested.

## Child environment and lifecycle

- gamescope UNSETS `WAYLAND_DISPLAY` (sets it only with `--expose-wayland`), sets `DISPLAY=:N`,
  `XDG_SESSION_TYPE=x11`, `ENABLE_GAMESCOPE_WSI=1`, unsets `SDL_VIDEODRIVER`, and overwrites
  `DXVK_HDR` with the host output's HDR state. With `WAYLAND_DISPLAY` unset, libwayland falls back
  to `wayland-0`, so a Wayland client inside could reach the host on a session whose socket has that
  name; the launcher sets winex11 and SDL x11 explicitly. A dummy `WAYLAND_DISPLAY` would disable the
  WSI layer (it requires the variable unset or equal to `GAMESCOPE_WAYLAND_DISPLAY`).
- Every fd except 0/1/2 is closed for the child.
- The child runs under `gamescopereaper`, a SUBREAPER that, when the primary child exits, SIGTERMs
  every remaining descendant and waits for all of them. Measured: after a window close, a wine helper
  (`winedevice.exe`, ntsync-stuck in its own process group) survived `wineserver -k`, the reaper waited
  on it, and gamescope never exited. Before gamescope that helper leaked to `systemd --user`; now it
  blocks, so the launcher SIGKILLs gamescope's descendant tree once the inner has reported its exit and
  gamescope has not followed within 5 s.
- gamescope's exit code is always 0 (the child's status is discarded); the inner launcher reports its
  code through the shared output pipe.
- Host `xdg_toplevel.close` → `raise(SIGTERM)` → shutdown → SIGTERM to the whole tree via /proc;
  no SIGKILL escalation.

## The user namespace and /tmp/.X11-unix

Inside the launcher's user namespace only our uid is mapped, so root-owned `/tmp/.X11-unix` reads as
owned by `nobody`, and the vendored wlroots refuses it:

    xwayland/sockets.c: /tmp/.X11-unix not owned by root or us

(repeated for every display number, then no Xwayland). The launcher binds a 0700 directory it owns
over `/tmp/.X11-unix` in the game's namespace. The lock files stay in the shared `/tmp`, so display
numbers remain unique across instances and the host's own Xwayland.

## Overlay, HDR, input

- `--mangoapp` works nested: mangoapp is found on gamescope's `PATH`, reads gamescope's SysV message
  queue, and draws as an overlay layer over any client. Measured on wine+DXVK and box64+GL Hollow
  Knight: CPU, fps and frametime render (GPU stats blank on Asahi, as with MangoHud everywhere there).
- HDR: the host side needs `wp_color_manager_v1` with PARAMETRIC, SET_PRIMARIES,
  SET_MASTERING_DISPLAY_PRIMARIES, EXTENDED_TARGET_VOLUME, SET_LUMINANCES, WINDOWS_SCRGB, PQ and the
  sRGB + BT2020 primaries (or `frog_color_management_v1`). Hyprland 0.57 advertises all of them. Only
  X11 Vulkan clients get HDR, through the WSI layer (`VkLayer_FROG_gamescope_wsi`), which exposes
  HDR10 / scRGB swapchain formats when gamescope reports HDR output; native Wayland clients inside
  gamescope get no color management. The layer force-enables `VK_EXT_swapchain_maintenance1` in
  every device (Honeykrisp has it). Not yet measured on an HDR output.
- Touchpad scrolling (patch 0003): upstream takes scroll motion only from `axis_value120`, which
  compositors send for wheels, and drops non-wheel frames; its `wl_pointer.axis` handler is empty, so a
  touchpad (finger source, continuous `axis` + `axis_stop` only) did not scroll at all (Civ V). The patch
  forwards finger/continuous motion to the nested seat with its source and no discrete value; Xwayland
  converts it to smooth-scroll valuators + button 4/5 as it does on the host. Verified on Civ V.
- Remaining input gaps in the Wayland backend: clipboard is game → host only; the nested keymap comes
  from `XKB_DEFAULT_*`, not the host's keymap. Relative mouse mode engages automatically when the game
  hides and confines the cursor.
- 3.16.x logged `Compositor released us but we were not acquired. Oh no.` continuously under Hyprland
  (the static black buffer's release); 3.17.0 no longer does.

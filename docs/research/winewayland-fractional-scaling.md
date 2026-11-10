# winewayland on a fractionally scaled output

propnix's default wine display driver is winewayland (`graphics = "wayland"`): native fractional
scaling, a single native window, no Xwayland. On a fractionally scaled output it hands windows a
LOGICAL size while the compositor shows them at physical size, and several titles trip over that gap
in different ways: a fullscreen request placed off-screen, a windowed Unity game whose in-game
cursor cannot reach most of the window, a DPI stamp that shrinks the render, and a
swapchain-recreation loop. The measurements below come from a 2560x1664 panel at scale 1.60 (logical
1600x1040) under Hyprland. Each fix is per title: a `graphics = "x11"` override (winex11 on
Xwayland), a Unity fullscreen PlayerPref, or keeping a variable away from the game.

## Fullscreen placed off-screen (Papers, Please)

Papers, Please (1.4.x GOG, a Unity IL2CPP title) starts fullscreen only with both the Unity
fullscreen pref and the x11 driver. Measured on a fresh profile (no `settings.sav`, so the game
falls back to its own defaults, which is what a new user gets):

| configuration | window size | position | fullscreen | result |
|---------------|-------------|----------|------------|--------|
| pref only, winewayland | 2560x1665 | -480,-295 | 0 | oversized, off-screen |
| pref only, x11 | 1600x1040 | 0,0 | 2 | correct |
| pref = Windowed (3), x11 | 1600x1005 | 0,35 | 1 | the pref decides the mode |

The pref decides the mode: Unity's FullScreenWindow (1) against Windowed (3) changes the result
under x11, so it is not an inert knob. `-screen-fullscreen 1` as an exe argument does not work: the
geometry is byte-for-byte the same as with no argument, because the game applies its own setting
afterwards.

The display driver decides whether that mode is honoured. Under winewayland the game asks for a
borderless window the size of the PHYSICAL desktop (2560x1664), and fractional scaling places it as
a 2560x1665 LOGICAL window on a 1600x1040 screen, hanging off the top-left corner. Under Xwayland
the same request lands as a true fullscreen window.

The display mode cannot be seeded from a setup script: `settings.sav` is a 316-byte encrypted blob
(hex-encoded, no single-byte XOR, almost no printable structure). It holds the display mode
(deleting it resets the game to its windowed default). The pref plus `graphics = "x11"` reach a
correct fullscreen without a file format.

## Windowed Unity: the in-game cursor is confined to ~1/scale

A windowed Unity app on fractional-scale winewayland confines its engine-drawn (in-game) cursor to
the upper-left ~1/scale of the window (0.625 at scale 1.60), while wine's hardware cursor roams the
whole window. winewayland reports the client area at the logical size while the compositor displays
it at physical size, so Unity's backbuffer and `Screen` are logical and its cursor maps across only
that sub-rectangle. A DPI-aware manifest (Papers, Please is `PerMonitorV2`) does not prevent it in
windowed mode. Fullscreen fixes it: Unity's render target becomes the whole output, so input maps
across the entire screen.

The fix is the persisted Unity PlayerPref, not a `-screen-fullscreen` exe argument. The argument is
applied at startup and the game's own persisted setting then overrides it back to windowed (a
fullscreen window flashes and drops); setting the pref leaves nothing to revert to. Unity stores
PlayerPrefs in `HKCU\Software\<companyName>\<productName>` with a per-key hash suffix. The value
written is

    "Screenmanager Fullscreen mode_h3630240806" = REG_DWORD 1

where 1 is the `FullScreenMode` enum's FullScreenWindow (borderless fullscreen). No resolution keys
are set, so Unity uses the native desktop resolution and the row stays host-agnostic.

The pref name differs by player version, so it has to be checked per title:

- Papers, Please (`Software\3909\PapersPlease`) and R.E.P.O. (`Software\semiwork\REPO`, Unity
  2022.3): `Screenmanager Fullscreen mode` is a live pref name in the player (R.E.P.O.'s
  `UnityPlayer.dll` lists it beside `Screenmanager Resolution {Width,Height}` and
  `Screenmanager Resolution Use Native`), so the hashed value above is the one the engine reads. The
  key comes from the `app.info` company/product pair.
- Cities: Skylines (Unity 5.6.7f1): the only Screenmanager keys the player knows are
  `Screenmanager Is Fullscreen mode`, `Screenmanager Resolution {Width,Height}` and
  `Screenmanager Stereo 3D`. The differently named (and so differently hashed) pref means the value
  above would create a registry entry the game never reads; a fix there is a hand-written `userReg`
  row under the Unity 5 name.
- Kerbal Space Program: its own `settings.cfg` owns the screen mode and overrides Unity's screen
  prefs at startup, so the pref is overwritten even though the player knows it. Its setup script
  maintains the display keys in `settings.cfg` instead.

## LogPixels shrinks the render (Skyrim Special Edition)

`PROPNIX_DPI` makes the launcher stamp `HKCU\…\LogPixels`. On the 160 % display, `LogPixels=154`
makes wine DPI-scale the render to the LOGICAL size: Skyrim SE's swapchain comes up at 1596x1037
instead of the physical 2560x1664, and the game exits by itself about 10 s in. With `PROPNIX_DPI`
unset on a clean prefix the swapchain is 2560x1664 and the game runs.

How the launcher handles the variable:

- `PROPNIX_DPI` is env-only and opt-in. A positive value becomes the `LogPixels` stamp through the
  `LogPixels = $PROPNIX_DPI` userReg entry; 0, non-numeric or unset writes no stamp, and the HKCU
  three-way merge prunes a stamp it wrote on an earlier launch. The launcher never derives a DPI
  from the compositor.
- Skyrim SE declares `brokenVariables = [ "PROPNIX_DPI" ]`, so the launcher unsets it before
  anything else (fact population, settings, the seal), even when the user exports it globally.
- `PROPNIX_FPS` is not listed. It is safe for this title because the setup script keeps the engine's
  vsync in agreement with DXVK (`iPresentInterval=0` when a cap is requested, `1` otherwise);
  rendering is verified with `PROPNIX_FPS=60`.

## Swapchain-recreation loop (Skyrim Special Edition)

Skyrim SE runs with `graphics = "x11"`: under winewayland, fractional-scale surface resizes drive a
DXVK swapchain-recreation loop that NULL-derefs inside winevulkan's `vkCreateSwapchainKHR`. The
fault is title-specific. Baldur's Gate 3 was A/B-measured on `bg3.exe` (fullscreen Vulkan):
winewayland ran 18 min to a clean exit with 0 faults and 0 swapchain recreates, x11 ran 17 min to a
clean exit with 0 faults. Papers, Please's off-screen fullscreen is a different symptom of the same
class of winewayland fractional-scale fault.

## Native Linux Unity players (thin path)

The same logical-size ceiling hits native Linux Unity players on Wayland, through SDL rather than
wine. Unity vendors a pre-2.26 SDL fork inside `UnityPlayer.so`: `SDL_DYNAMIC_API` is compiled out
(a modern SDL cannot be swapped in) and it has no Wayland mode emulation, so a Wayland window only
ever sees the output's LOGICAL size. On a 4K monitor scaled 1.5x that caps the in-game resolution
list at 2560x1440 (Player.log: `Display 0: 2560x1440`) and the compositor upscales the result. Under
Xwayland the game sees whatever the compositor exposes there: the physical mode when so configured
(Hyprland `xwayland:force_zero_scaling`), and never less than the Wayland backend's logical cap.
Hollow Knight's Linux build therefore pins `SDL_VIDEODRIVER=x11` on every thin backend (on box64 it
is also needed because SDL's Wayland backend trips box64's dynarec). The setting is inert on the
wine backend, which has no SDL.

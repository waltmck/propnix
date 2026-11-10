# DXVK_HDR under winewayland

A Windows title under propnix sees an HDR display only when `DXVK_HDR=1` is in its environment. The
variable is read by DXVK's `dxgi.dll`, which is installed whenever `wine.d3d = "dxvk"` (the default
for every 64-bit Windows platform on both arches), and it is DXVK's stand-in for the Windows "HDR
on" display toggle. Without it DXVK never reports HDR under winewayland, because wine writes no EDID
into the registry there. vkd3d-proton has no dxgi of its own and presents through DXVK's, so the
same variable is the D3D12 knob. On an SDR session the real Vulkan surface offers no HDR10
colorspace, so the swapchain stays sRGB. This document collects the mechanism, the registry detail,
the per-DLL evidence, the open question on the D3D12 path, and what each HDR-enabled title shows.

## The variable and where it is read

DXVK's `dxgi.dll` carries the strings `DXVK_HDR`, `dxgi.enableHDR`, `DxgiFactory::GlobalHDRState`,
`VK_COLOR_SPACE_HDR10_ST2084_EXT` and `vkSetHdrMetadataEXT`. With the variable set, DXGI reports an
HDR10 display (`IDXGIOutput6::GetDesc1`), and an engine that gates its HDR option on that report
offers HDR.

On the wine backend with `d3d = "dxvk"`, propnix-launcher binds `d3d9`/`d3d10`/`d3d11` + `dxgi` from
DXVK and `d3d12`/`d3d12core` from vkd3d-proton into the prefix. A Vulkan-native title (No Man's Sky)
gets DXVK's dxgi too, and still asks DXGI whether the display is HDR-capable.

A title opts in with `env.DXVK_HDR = "1"`. The row is baked into the config's `seal.setEnv`; the
launcher's environment scrub removes only `WINE*`/`FEX_*`/`BOX64_*`/`LD_*`, so the variable reaches
the process. It is not a tree-wide default: careless titles trust the DXGI report alone (UE4 DX11
games crash on it, which is what DXVK's own `isHDRDisallowed` guard exists for), so each title opts
in knowingly.

## Why DXVK never detects HDR under winewayland

The prefix's monitor key

    HKLM\System\ControlSet001\Enum\DISPLAY\Default_Monitor\0000&0000\Device Parameters

holds `"BAD_EDID"=hex:`, empty. That is wine's marker for "the display driver gave me no EDID", and
it is structural under Wayland: no protocol exposes EDID to clients. DXVK wants a value named `EDID`
and parses HDR capability out of it with a statically linked libdisplay-info (`di_edid_cta_*`,
`di_cta_data_block_get_hdr_static_metadata` and `di_cta_data_block_get_colorimetry` are all in
`dxgi.dll`). Every run therefore logs these two `err:` lines, which are benign:

    readMonitorEdidFromKey: Failed to get EDID reg key size
    DXGI: Failed to parse display metadata + colorimetry info, using blank.

### Seeding the host EDID does not help

Seeding the host's real EDID into that key, as a `wine.systemReg` row (type `REG_BINARY`) for value
`EDID` under

    System\CurrentControlSet\Enum\DISPLAY\Default_Monitor\0000&0000\Device Parameters

leaves DXVK logging the same failure. The value lands correctly (it is visible as
`"EDID"=hex:00,ff,ff,…` beside `BAD_EDID` in the baked `<appid>-system.reg`), but wine's win32u
re-enumerates the display devices at runtime and DXVK reaches them through SetupAPI
(`GUID_DEVCLASS_MONITOR` → `SetupDiOpenDevRegKey` `DIREG_DEV`), not through the baked instance. A
baked hive cannot win that race, and `system.reg` is a read-only bind, so nothing can rewrite it at
runtime.

## D3D12: vkd3d-proton presents through DXVK's dxgi

vkd3d-proton ships only `d3d12.dll` + `d3d12core.dll`. It has no dxgi and exports
`IDXGIVkSwapChainFactory`, handing presentation to DXVK's `dxgi.dll`, which is the DLL that reads
`DXVK_HDR`. `strings` on the shipped binaries (2026-09-03) shows the split:

- `dxgi.dll` (DXVK 2.7.1): `DXVK_HDR`, `dxgi.enableHDR`, `dxvk::s_globalHDRState`,
  `DxgiVkFactory::{Get,Set}GlobalHDRState`, `DxgiFactory::GlobalHDRState`,
  `DxgiSwapChain::UpdateGlobalHDRState`, `DxgiSwapChain::SetColorSpace1`,
  `DxgiSwapChainDispatcher::SetColorSpace1` (the pass-through wrapper for a swapchain DXVK does not
  own), and the `IDXGIVkSwapChainFactory` UUID.
- `d3d12core.dll` (vkd3d 2.14.1): zero hits for `DXVK_HDR`/`enableHDR`. It is the other side:
  `IID_IDXGIVkSwapChainFactory`, `impl_from_IDXGIVkSwapChainFactory`,
  `dxgi_vk_swap_chain_{SetColorSpace,CheckColorSpaceSupport,supports_color_space,SetHDRMetaData}`,
  `VK_EXT_hdr_metadata`, `vkSetHdrMetadataEXT`, `Unhandled color space %#x. Falling back to sRGB.`

vkd3d never reads the variable. DXVK's dxgi holds the HDR policy, vkd3d holds the Vulkan swapchain
the colorspace is set on, and `SetColorSpace1` crosses from the first to the second over
`IDXGIVkSwapChainFactory`.

### Open: who initiates SetColorSpace1 on the vkd3d path

DXVK's HDR state is explicitly global (`s_globalHDRState`, `UpdateGlobalHDRState`, and a distinct
`DXGI: Unsupported HDR metadata type (global): ` message). That is consistent with DXVK pushing
HDR10 onto a new swapchain by itself, and equally consistent with `DXVK_HDR` only making
`IDXGIOutput6::GetDesc1` report an HDR display, leaving the game to opt in through its own HDR
setting. Nothing in the default logs distinguishes the two: vkd3d logs no colorspace at info level,
and DXVK's `Presenter: Actual swapchain properties` block never appears on this path because vkd3d
owns the swapchain.

To settle it, run with `VKD3D_DEBUG=trace` and grep for `dxgi_vk_swap_chain_SetColorSpace`: whether
it is called, and with what, is the whole answer. The output is voluminous; filter as it is
produced.

An in-game HDR toggle cannot be driven headlessly: `wtype`'s `zwp_virtual_keyboard` input does not
reach winewayland (a title screen ignores space/Return while the game keeps animating), so a
menu-driven check needs a human at the keyboard.

## SDR sessions

On an SDR output the real Vulkan surface offers no HDR10 colorspace, so the swapchain degrades to
sRGB rather than having PQ rendered into it. Engines that gate on `CheckColorSpaceSupport` follow
the real surface (sRGB-only unless the compositor output is in HDR mode) and stay SDR. HDR10 surface
formats on Linux need mesa ≥ 25.1 (Wayland WSI color management) and a compositor output in HDR
mode; winevulkan passes the surface formats through.

## Per title

### Cyberpunk 2077 (D3D12 only, vkd3d-proton)

`Cyberpunk2077.exe` loads D3D12 dynamically, so its only renderer is vkd3d-proton presenting through
DXVK's dxgi. Measured on x86_64 on 2026-09-03, on a Hyprland session driving an Odyssey G80SD in HDR
(`hyprctl monitors` reports `currentFormat XRGB2101010`, `colorManagementPreset hdredid`):

- The presentation path `DXVK_HDR` targets is the live one. The rendering run logs

      vkd3d-proton:dxgi_vk_swap_chain_init: Creating swapchain (3840 x 2160), BufferCount = 3
      dxgi_vk_swap_chain_recreate_swapchain_in_present_task: Got 4 swapchain images

  i.e. vkd3d's `IDXGIVkSwapChainFactory` swapchain driving DXVK's dxgi.
- The variable reaches the process (it is in `seal.setEnv`), and DXVK logs the expected benign
  `DXGI: Failed to parse display metadata + colorimetry info, using blank.`

The game has its own HDR Mode row (Settings → Video), persisted in `UserSettings.json` in its Saved
Games folder and off by default. Whether `DXVK_HDR` alone produces HDR output is the open question
above.

### Baldur's Gate 3 (D3D11 exe chosen for HDR)

The GOG build has two game binaries, `bin/bg3.exe` (native Vulkan) and `bin/bg3_dx11.exe` (D3D11),
and HDR decides between them:

- `bg3.exe` does HDR: it reads HDR10 colorspaces straight off the Vulkan surface (mesa ≥ 25.1
  Wayland WSI color management plus a compositor output in HDR mode; winevulkan passes surface
  formats through). It engages HDR only in its exclusive-fullscreen display mode, and that mode
  loses a state fight between winewayland and the compositor. The mode-set transition bounces the
  toplevel out of fullscreen (it settles as a floating window), and a compositor-initiated
  fullscreen resizes the window from outside, which knocks the engine back out of its fullscreen
  mode and turns its HDR gate off with it.
- `bg3_dx11.exe` gets HDR through DXVK's DXGI in any display mode, with no exclusive-fullscreen
  requirement and so no state fight to lose.

Verified on x86_64 on 2026-09-01: `bg3_dx11.exe` launches and plays, and with `DXVK_HDR` the
swapchain presents `HDR10_ST2084` on an HDR Wayland session (Hyprland 0.56, mesa 26.1, RADV). The
engine also gates on `CheckColorSpaceSupport`, so an SDR session degrades to SDR; HDR brightness is
calibrated in-game.

The choice inverts the fewer-layers preference (Vulkan → winevulkan has fewer layers than D3D11 →
DXVK → Vulkan). `.apply { exe = "bin/bg3.exe"; }` switches back to the Vulkan renderer.

### The Witcher 3 (two renderers, HDR not the differentiator)

REDengine 3 in its 4.0x "next-gen" form ships two complete renderers as two binaries. Their PE
import tables:

- `bin/x64/witcher3.exe` imports `d3d11.dll`, `dxgi.dll`, `D3DCOMPILER_47.dll`,
  `GFSDK_SSAO_D3D11.win64.dll`.
- `bin/x64_dx12/witcher3.exe` imports neither d3d11 nor d3d12 (it loads D3D12 dynamically; its dir
  ships `D3D12/D3D12Core.dll`, the Agility SDK) and instead pulls `GFSDK_SSAO_D3D12.win64.dll`,
  `dxcompiler.dll` (DXC), `libxess.dll`, `sl.interposer.dll` (NVIDIA Streamline) and
  `GFSDK_Aftermath_Lib.x64.dll`.

Both exes carry the identical display-HDR gate (`GetHDRSupported`, `IsHdrSupported`,
`SetHDRMenuActive`, `OnHDRChangedEvent`, `hdr\hdr_calibration_screen.dds`, the same set in both
string tables), and both present through DXVK's dxgi: D3D11 directly, D3D12 through vkd3d-proton's
`IDXGIVkSwapChainFactory`. So `DXVK_HDR` is the same knob for either binary and HDR does not decide
the renderer, unlike Baldur's Gate 3.

The trade-off between the two:

- D3D11 → DXVK → Vulkan is the chain most wine titles in the tree run, and native ARM64EC DXVK is
  what the `wine.d3d` default was measured on (60 fps against wined3d-Vulkan's ~12).
- The D3D12 exe puts vkd3d-proton in the primary role, as Cyberpunk 2077 does. It hard-imports the
  NVIDIA stack (Streamline interposer, Aftermath) and runs DXC for shader compilation at load. On a
  Mesa target the DLSS/Streamline paths are inert, and under FEX all of it is emulated CPU work on
  the critical path.
- Ray tracing (and DLSS) is D3D12-only.

The package runs the D3D12 exe, `bin/x64_dx12/witcher3.exe` with `workingDir = "bin/x64_dx12"` (an
owner decision of 2026-09-03, for ray tracing and HDR). What is measured: the D3D11 binary renders
and plays, without HDR. Whether that is the engine's own HDR toggle being off in `user.settings`
(the in-game Video menu writes it; a fresh prefix starts from defaults) or something in the
DXVK-dxgi path is unresolved. Not measured: that D3D12 produces HDR, or that it runs at all.

The engine keeps separate graphics settings per renderer (`user.settings` vs `dx12user.settings`,
both read off the exes' strings) and one shared `gamesaves` directory, so each renderer starts from
its own defaults (resolution, quality and the HDR toggle are set in the Video menu on first run) and
switching costs a re-configure, not a savegame. The engine is cwd-sensitive, so going back to D3D11
needs both fields:

    witcher-3.apply { exe = "bin/x64/witcher3.exe"; workingDir = "bin/x64"; }

### No Man's Sky (Vulkan-native)

No Man's Sky renders through winevulkan directly but asks DXGI whether the display is HDR-capable,
and `d3d = "dxvk"` installs DXVK's dxgi even though the renderer is Vulkan. With `DXVK_HDR=1` the
game offers and enables HDR and creates an HDR10 Vulkan swapchain through mesa's Wayland color
management. Verified on x86_64 on a Hyprland HDR session: `DXVK_HDR` alone makes HDR work. On an SDR
session the surface offers no HDR10 colorspace and the game stays SDR.

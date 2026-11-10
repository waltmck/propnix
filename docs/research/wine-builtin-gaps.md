# Wine builtins that titles work around

wine implements a set of Windows DLLs itself, and for those names the default load order is builtin
first: a Microsoft DLL a game ships beside its exe is found and then ignored in favour of wine's own
implementation. Where wine's implementation falls short, the title either asks for the shipped
native DLL with a per-title `wine.dllOverrides` entry or steps around the missing feature. This
document records two such gaps: the HLSL compiler in `d3dcompiler_47`, and WMV3/VC-1 video decoding
through DirectShow.

## d3dcompiler_47: the HLSL front end

Wine's builtin `d3dcompiler_47` is vkd3d-shader's HLSL compiler, written from scratch. Engines that
compile HLSL at runtime through `D3DCompile` can feed it source that Microsoft's compiler accepts
and it rejects. The error codes (`E4001`, `E5000`, `E5002`, …) are vkd3d-shader's, and
`PROPNIX_WINEDEBUG=+loaddll` shows which implementation answered:

    Loaded L"C:\\game\\binaries\\D3DCOMPILER_47.dll" … : builtin

`: builtin` beside the game's own path means wine found the shipped file and loaded its own
implementation over it. This is not a missing-file problem: the fix is to ask for the native DLL,
which the loader finds in the exe's own directory, where both titles below ship Microsoft's
compiler.

| title | `wine.dllOverrides.d3dcompiler_47` | builtin failure |
|-------|------------------------------------|-----------------|
| Space Engineers | `"n,b"` | no `HLSL_VERSION` predefine |
| Victoria 3 | `"n"` | E5000/E5002 on the engine's `ps_5_0` HLSL |

`"n,b"` keeps the builtin as a fallback, so a payload that lacks the file degrades to the builtin's
behaviour instead of failing to start; `"n"` loads native only. Either way the D3D runtime itself
(d3d11/dxgi on DXVK) is a separate axis and needs no change.

### Space Engineers: `HLSL_VERSION`

VRage compiles its shaders at startup through `D3DCompile` (SharpDX.D3DCompiler → `d3dcompiler_47`),
and they `#include "D3DX_DXGIFormatConvert.inl"`, Microsoft's header, which picks its HLSL body or
its C++ body with (`Content/Shaders/D3DX_DXGIFormatConvert.inl:202/224`):

    #if HLSL_VERSION > 0   … HLSL typedefs …   #else   #ifndef __cplusplus
    #error C++ compilation required   #endif   #include <float.h>   #include <xnamath.h>

`HLSL_VERSION` is predefined by the compiler, and vkd3d-shader does not define it. The string
"HLSL_VERSION" appears 0 times in either builtin
(`lib/wine/{i386,x86_64}-windows/d3dcompiler_47.dll`) and once in the depot's own
`Bin64/d3dcompiler_47.dll`. Under the builtin every shader takes the C++ branch and dies on the
`#error` plus two host headers that do not exist.

Measured on x86_64-linux under a headless sway, with the builtin:
`Include not found: C:\game\Content\Shaders\float.h` and the same for `xnamath.h`, then

    D3DX_DXGIFormatConvert.inl:226:1: E4001: Error directive: C++ compilation required
    Failed to compile Primitives/Lines.hlsl @ profile vs_5_0

after which `MyRender11.InitSubsystems` throws `MyRenderException`, the log reads
`CreateDevice failed: Disposing Device`, and VRage retries down to its "Lowest res fallback" 640x480
device and fails there identically. The D3D11 device and the DXVK swapchain are fine throughout; the
failure is purely the shader front end. The depot ships the real compiler next to the exe
(`Bin64/d3dcompiler_47.dll`, 4 173 928 bytes), and `"n,b"` makes the loader take it.

### Victoria 3: E5000/E5002

With the builtin, the engine reaches its renderer and then exits:

    gfx_dx11_shaderstate.cpp:161: Failed getting shader for PixelTexture
    gfx_dx11_master_context.cpp:521: Failed creating shader state

on an `error.log` full of `E5002: Can't implicitly convert from float2 to float3` and
`E5000: Failed to evaluate constant expression`. Clausewitz compiles its `ps_5_0` shaders from HLSL
at runtime through `d3dcompiler_47`, every shader fails, and the renderer gives up. Depot 529342
ships `binaries/d3dcompiler_47.dll`, and the `+loaddll` line above is this title's. With `"n"` the
error log carries zero E5000/E5002 lines and the first run compiles and caches 6840 shaders under
`shadercache/dx11/`.

The entry is scoped to `d3dcompiler_47`: `dxcompiler.dll` and `dxil.dll` (the SM6 path, also shipped
beside the exe) are not names wine implements, so they already load native.

## WMV3/VC-1 video through DirectShow

This wine cannot decode WMV3/VC-1 in an ASF container through DirectShow: the graph cannot connect
the WM ASF Reader to the WMVideo Decoder DMO, and the call fails with 0x80040217
(VFW_E_CANNOT_CONNECT). The fix belongs in the wine layer, a WMV3/VC-1 path for winegstreamer;
titles carry no per-title decoder workaround.

### Space Engineers

`MyGuiScreenIntroVideo` is pushed before the main menu and plays `Content/Videos/*.wmv` through
DirectShow. The run prints

    -2147220985  Can't connect WM ASF Reader and WMVideo Decoder DMO

(-2147220985 = 0x80040217) and the intro screen then never completes. Measured on x86_64-linux under
a headless sway on an RX 7900 XTX: a 300 s run sat on a black 1920x1080 window the whole time while
the engine stayed healthy underneath (`GUI Stats: Update … Draw …` every 30 s, DXVK swapchain up),
waiting on a video that never finishes. With `-skipintro` the same build reaches
`MyGuiScreenMainMenu MyGuiScreenBase.LoadContent` about 35 s in and renders.

`-skipintro` is the game's own switch (a literal in `Sandbox.Game.dll` alongside `-coldstart` and
`-nosplash`), so the title is asked for a supported path, not defeated. It only skips the intro, so
it stays correct for a user who prefers no intro even once wine decodes WMV. `-nosplash` is not
needed: the WinForms splash works.

The animated main-menu backgrounds, `Content/Videos/Background0*.wmv`, hit the same failure and are
simply absent; only the intro is fatal.

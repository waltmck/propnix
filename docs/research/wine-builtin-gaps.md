# Wine builtins that titles work around

wine implements a set of Windows DLLs itself, and for those names the default load order is builtin
first: a Microsoft DLL a game ships beside its exe is found and then ignored in favour of wine's own
implementation. Where wine's implementation falls short, the title either asks for the shipped
native DLL with a per-title `wine.dllOverrides` entry or steps around the missing feature. This
document records two such gaps: the HLSL compiler in `d3dcompiler_47`, which patch 0009 on wine now
closes for one title and narrows for another, and WMV3/VC-1 video decoding through DirectShow.

## d3dcompiler_47: the HLSL front end

Wine's builtin `d3dcompiler_47` is vkd3d-shader's HLSL compiler, written from scratch, and it runs
as native ARM64 code; the Microsoft DLL a depot ships runs under the emulator. Engines that compile
HLSL at runtime through `D3DCompile` can feed it source Microsoft's compiler accepts and it rejects.
The error codes (`E4001`, `E5000`, `E5002`, …) are vkd3d-shader's, and `PROPNIX_WINEDEBUG=+loaddll`
shows which implementation answered:

    Loaded L"C:\\game\\binaries\\D3DCOMPILER_47.dll" … : builtin

`: builtin` beside the game's own path means wine found the shipped file and loaded its own
implementation over it. Where that implementation falls short, the title asks for the native DLL
with `wine.dllOverrides.d3dcompiler_47`; where it serves, the title gets a compiler that is not
emulated. `emulators/wine-hangover/patches/0009-vkd3d-shader-hlsl-front-end-gaps.patch` adds to the
builtin what the two titles below needed; its header lists each change.

| title | `wine.dllOverrides.d3dcompiler_47` | state |
|-------|------------------------------------|-------|
| Victoria 3 | none (builtin) | every cached shader compiles with patch 0009; a cold cache reaches the main menu after about 3 400 compiles, six and a half minutes on the Asahi host |
| Space Engineers | `"n,b"` | needs `AppendStructuredBuffer`/`ConsumeStructuredBuffer`, which vkd3d-shader lacks |

Compile latency is also a frame-time cost, not only a startup one: Clausewitz compiles effect
variants on demand during play (about half of Victoria 3's corpus arrives after the main menu), so a
compiler running under the emulator shows up as hitches whenever new assets come into view, and the
builtin removes them along with the startup wait.

`"n,b"` keeps the builtin as a fallback, so a payload that lacks the file degrades to the builtin's
behaviour instead of failing to start. Either way the D3D runtime itself (d3d11/dxgi on DXVK) is a
separate axis and needs no change. `dxcompiler.dll` and `dxil.dll` (the SM6 path, shipped beside
some exes) are not names wine implements, so they load native without an entry.

### Finding the gaps: the harness and the in-game corpus

`tools/hlslc.c` drives the prefix's `d3dcompiler_47` over real shader sources outside the game
(single file with messages and disassembly, or a TAB-separated job list), so a gap is reproduced in
seconds instead of a game launch. Two facts it depends on:

- A dev-built `wined3d.dll` (the compiler lives there, not in `d3dcompiler_47.dll`) does not load
  from a prefix by being placed or bound there: the loader resolves a wine-builtin-signed image to
  the install tree's copy (`dll_dir` precedes `WINEDLLPATH`, and a builtin image is loaded
  "builtin, then native"). Clearing the `"Wine builtin DLL"` signature in the DOS stub of a copy and
  loading it with `wined3d=n` is the way to run a rebuilt compiler against the stock wine.
- A game's exact compile jobs (source, profile, entry point, macros) are only known at runtime. A
  dump hook on `D3DCompile`/`D3DPreprocess` in the dev tree's vkd3d-utils writes them as an index
  the harness replays; vkd3d's own `VKD3D_SHADER_DUMP_PATH` writes source and log but neither entry
  point nor macros.

Victoria 3's corpus is its own `shadercache/dx11/{ps,vs}_5_0/*.scache` (one self-contained HLSL
text per effect variant, entry `main`): 7 159 files, all compiling with the patch. Space
Engineers' corpus grows one failing shader at a time, because VRage aborts on the first failed
compile; the gaps it exposed, in order, were `HLSL_VERSION`, `isnan()`, `SV_Coverage` as a pixel
input, struct member functions (`Random.hlsli`, four shader files), an `[unroll]` loop bounded by
`big_stone ? 4 : 2`, and then the GPU-particle compute shaders' append/consume buffers.

### The shader that never finished

`gfx/FX/jomini/jomini_unsigned_distancefield.shader`, `PS_init`, with
`JOMINI_UNSIGNED_DISTANCE_FIELD_WRAP_X`: 457 lines that fill a `float4[64]` from texture samples in an
8x8 loop and then read it with a dynamic index in a second 8x8 loop. The engine requests it on the
way to the main menu, and vkd3d-shader without the memoization below never finishes it (killed
after 24 CPU-minutes; upstream carries the identical walk): every `cond ? x : y` it simplifies is
evaluated under both assumptions by a recursive walk over the operand graph, and that graph is a DAG
whose shared subexpressions make the tree walk exponential in depth. Patch 0009 memoizes the walk per evaluation; the same shader then compiles in
one second to 54 KB of bytecode. A `perf record` of the running compile, with the harness's
unstripped `wined3d` symbolized through its COFF symbol table, put 100% of the samples in that one
function, which is how it was found.

### Victoria 3 before the patch

With the stock builtin the engine reached its renderer and exited:

    gfx_dx11_shaderstate.cpp:161: Failed getting shader for PixelTexture
    gfx_dx11_master_context.cpp:521: Failed creating shader state

on an `error.log` of `E5002: Can't implicitly convert from float2 to float3` (six
`Texture2DArray.SampleGrad` calls with float2 gradients in the particle shader) and
`E5000: Failed to evaluate constant expression` (a consequence of the first). The reported line
numbers were off by tens of lines because template-compiled intrinsics advanced the parse location
(upstream has since fixed that; the patch carries the fix).

### Space Engineers before the patch

VRage compiles its shaders at startup through `D3DCompile` (SharpDX.D3DCompiler → `d3dcompiler_47`),
and they `#include "D3DX_DXGIFormatConvert.inl"`, Microsoft's header, which picks its HLSL body or
its C++ body with (`Content/Shaders/D3DX_DXGIFormatConvert.inl:202/224`):

    #if HLSL_VERSION > 0   … HLSL typedefs …   #else   #ifndef __cplusplus
    #error C++ compilation required   #endif   #include <float.h>   #include <xnamath.h>

`HLSL_VERSION` is predefined by Microsoft's compiler; neither the sources nor VRage's macros define
it. Under the stock builtin every shader took the C++ branch and died on the `#error` plus two host
headers that do not exist, `MyRender11.InitSubsystems` threw `MyRenderException`, and VRage retried
down to its 640x480 fallback device. The depot ships the real compiler next to the exe
(`Bin64/d3dcompiler_47.dll`, 4 173 928 bytes), which is what `"n,b"` still selects today.

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

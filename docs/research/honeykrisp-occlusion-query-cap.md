# The Honeykrisp occlusion-query cap

Honeykrisp, Mesa's Vulkan driver for the Apple AGX GPU (Asahi), backs every occlusion query with a
slot in one device-wide hardware table of `AGX_MAX_OCCLUSION_QUERIES` = 32768 entries, reserved
eagerly when a query pool is created. A title that creates larger pools gets
`VK_ERROR_OUT_OF_DEVICE_MEMORY`, and a title that ignores that result renders with its occlusion
culling dead. No Man's Sky is the case on aarch64: it plays, but flickers heavily on stock Mesa. The
defect is in the driver, not in propnix or the emulation stack, and a per-app patched Mesa works
around it. The last section records a second Asahi driver observation (Outlast 2).

## The mechanism (No Man's Sky)

- NMS creates four 65536-entry `VK_QUERY_TYPE_OCCLUSION` pools: 262144 queries.
- `hk_CreateQueryPool` reserves one hardware occlusion slot per query in the pool, from a
  device-wide table of `AGX_MAX_OCCLUSION_QUERIES` = 32768 (mesa `src/asahi/lib/agx_helpers.h`). The
  table size is 32768 because the AGX per-draw "Fragment occlusion query" packet field is 15 bits
  (`src/asahi/genxml/cmdbuf.xml`).
- So every one of those pools fails with `VK_ERROR_OUT_OF_DEVICE_MEMORY` (`hk_query_pool.c:309`).
- NMS does not check the result and goes on using the unwritten handle. The driver NULL-derefs on
  each use; wine catches the unix-side SIGSEGV and returns `STATUS_ACCESS_VIOLATION` from the
  syscall (`trace:seh:handle_syscall_fault`) instead of crashing.
- The game therefore runs, but its occlusion culling is dead, which shows as major flickering.

Measured over one boot-to-gameplay run: 12762 such faults on the stock driver, 0 with the table
raised.

## What it is not

Nothing here is related to the page size, FEX, wine, ARM64EC, DXVK, Streamline or XeSS.

- The cap is a compile-time constant, identical in every Mesa from 24.3 to 26.1 and in Asahi's own
  fork, so a 4 KiB-page muvm guest (same Honeykrisp, same GPU) hits the same wall. muvm is not a
  workaround.
- No other Mesa Vulkan driver has an occlusion-query cap at all. AMD, Intel, NVIDIA and Adreno
  program a full 64-bit result address per query instead of an index into one device-global table,
  so their only limit is memory. NMS on an x86_64 host (RADV) is unaffected.

## The upstream fix shape

Allocate hardware slots lazily, per submission. The 15-bit index is relative to a per-submit
`isp_oclqry_base`, so a pool bigger than the 32768-entry window is representable. Raising the
constant cannot be right in general: NMS alone asks for 262144 queries, eight times what a 15-bit
index addresses.

## Workaround: a patched Mesa for one app

A Mesa built with `AGX_MAX_OCCLUSION_QUERIES` raised to 1048576 covers the request. The slots above
32768 alias in hardware, because the packet field truncates the index; that is memory-safe, since
the write stays inside the table. It is selected per app through `VK_DRIVER_FILES`, so nothing else
on the system changes. As a file saved at the root of a propnix checkout:

    # nms-patched-mesa.nix
    let
      propnix = builtins.getFlake (toString ./.);
      pkgs = propnix.inputs.nixpkgs.legacyPackages.aarch64-linux;
      mesaWideOcclusion = pkgs.mesa.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/asahi/lib/agx_helpers.h \
            --replace-fail "#define AGX_MAX_OCCLUSION_QUERIES (32768)" \
                           "#define AGX_MAX_OCCLUSION_QUERIES (1048576)"
        '';
      });
    in
    propnix.legacyPackages.aarch64-linux.no-mans-sky.apply {
      env.VK_DRIVER_FILES = "${mesaWideOcclusion}/share/vulkan/icd.d/asahi_icd.aarch64.json";
    }

run from that directory with

    nix run --impure --expr 'import ./nms-patched-mesa.nix' \
      --extra-sandbox-paths /propnix=/var/lib/propnix

With a patched Mesa already built, the variable can also be set for a single launch:

    VK_DRIVER_FILES=<patched-mesa>/share/vulkan/icd.d/asahi_icd.aarch64.json nix run .#no-mans-sky

The app-level `mesa` knob takes the same derivation (`.apply { mesa = mesaWideOcclusion; }`) and
forces the whole GL/Vulkan userspace to it, GLX and EGL included, rather than only the Vulkan ICD; a
per-game `env.VK_DRIVER_FILES` still wins over what that knob derives.

## Outlast 2: "Clamping massive framebuffer"

Honeykrisp logs `Clamping massive framebuffer` repeatedly during Outlast 2 (Unreal Engine 3): the
engine requests an oversized shadow or render target, and the driver clamps it to the GPU's maximum
dimension. It does not break rendering: the first-run gamma-calibration screen (a full 3D scene)
renders crisply at 2560x1664. A shadow-resolution tune (for example through `PROPNIX_QUALITY`) could
silence it; none is set.

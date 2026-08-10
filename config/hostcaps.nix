# config/hostcaps.nix — host capability facts the packages assume (PLAN2 §8), a PLACEHOLDER this pass.
#
# The winefex stack is deliberately page-size-agnostic: the Windows FEX/box64 emulator DLLs do NOT compile
# jemalloc_glibc (ENABLE_JEMALLOC_GLIBC_ALLOC=FALSE for MINGW → rpmalloc only; fex-dlls.nix header), so the
# 16K/64K host-page walls that dogged the *Linux* FEX fork (../fex-portable) simply do not apply — memory
# and the loader are wine's `ntdll` at the host page size, and FEX only JITs instruction blocks. So there
# is nothing to probe here yet; these are static facts.
#
# BACKLOG: a Rust `propnix-hostcaps` probe (GPU/Vulkan driver, Wayland vs X, page size) + §8 Mesa/Vulkan
# driver pins for non-NixOS hosts. When it exists, the launcher will consult it and honour a
# `PROPNIX_HOSTCAPS_OVERRIDE` env pointing at a JSON override (for headless/CI or forcing a config).
{
  arch = "aarch64-linux"; # first-pass target; x86_64-linux host is a later emulator-set swap (docs backlog)

  # The stack does not depend on the host page size (see header). True for 4K, 16K, and 64K aarch64 hosts.
  pageSizeAgnostic = true;

  # Assumed present at runtime (the launcher does not hard-check these this pass):
  #   * a Vulkan driver for the GPU (DXVK/vkd3d → Vulkan; Mesa on Asahi/panvk or the vendor ICD elsewhere),
  #   * a Wayland compositor (winewayland is the measured-best driver for HK) with Xwayland available,
  #   * /dev/dri render access for the launching user (native group membership — no sandbox strips it).
  assumes = {
    vulkan = true;
    wayland = true;
    xwayland = true;
  };

  # Runtime override hook (honoured by the future propnix-hostcaps probe, not yet):
  overrideEnv = "PROPNIX_HOSTCAPS_OVERRIDE";
}

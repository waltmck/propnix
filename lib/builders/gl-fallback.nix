# builders/gl-fallback.nix — the baked GL/Vulkan userspace of last resort, shared by both backends'
# dispatch arms (mk-thin-build.nix, backends/wine/default.nix). Nix-built glvnd and vulkan-loader resolve
# their vendor through `/run/opengl-driver` — a NixOS-ism — so on any other distro every GL context and
# Vulkan instance fails (Unity's "Couldn't find matching GLX visual … exiting", one second into Hollow
# Knight on Fedora). Shipping the LIBRARIES alone is not enough: factorio always carried mesa's libs in
# its union and still died ("Could not get EGL display"), because glvnd finds vendors through DISCOVERY
# (ICD JSONs, driver dirs), not by soname-scanning the library path. So each app bakes a mesa plus the
# discovery paths below, and the launcher (glstack.rs) exports them IFF the host provides no stack of its
# own — or unconditionally when the game's `mesa` knob FORCED one, since a per-game driver patch (e.g.
# NMS's asahi occlusion-query bump) must also beat the host's `/run/opengl-driver`.
#
# Baked ALWAYS, on every backend, so one store artifact runs on any distro with nothing but nix and the
# credential store. What each field feeds (the launcher's env spelling in glstack.rs):
#   * libDir        — LD_LIBRARY_PATH tail: the GLX/EGL vendor libraries (libGLX_mesa / libEGL_mesa).
#   * driDir        — LIBGL_DRIVERS_PATH (the DRI megadrivers) and LIBVA_DRIVERS_PATH (mesa keeps its
#                     VA-API video drivers in the same dir on the arches that build them).
#   * gbmDir        — GBM_BACKENDS_PATH (`dri_gbm.so`): winewayland allocates its presentation buffers
#                     through gbm, so a wine title on a foreign distro needs this too, not just GLX/EGL.
#   * eglVendorDir  — __EGL_VENDOR_LIBRARY_DIRS (glvnd's EGL ICD discovery).
#   * vulkanIcdDir  — its *.json become VK_DRIVER_FILES (winevulkan/DXVK/vkd3d and native Vulkan alike).
# Deliberately NOT covered: VDPAU (legacy video-decode; games use bundled decoders, and this mesa does
# not even build it on aarch64) and indirect GLX (dead protocol). nixGL, the reference for this
# treatment, additionally wires both — for media players, which propnix does not ship.
{ mesa }:
# `cfgMesa` is the app's `mesa` knob: null → the scope's nixpkgs mesa, and the launcher treats the stack
# as a FALLBACK; a derivation → that tree, FORCED over whatever the host has. "Mesa" by convention, not
# by contract: any glvnd-layout vendor tree works — the launcher sniffs the GLX vendor name from
# `libGLX_<vendor>.so.0`, which is the proprietary-driver escape hatch (see the `mesa` option's docs).
cfgMesa:
let
  m = if cfgMesa != null then cfgMesa else mesa;
in
{
  forced = cfgMesa != null;
  libDir = "${m}/lib";
  driDir = "${m}/lib/dri";
  gbmDir = "${m}/lib/gbm";
  eglVendorDir = "${m}/share/glvnd/egl_vendor.d";
  vulkanIcdDir = "${m}/share/vulkan/icd.d";
}

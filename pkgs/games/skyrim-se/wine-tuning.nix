# Skyrim Special Edition — per-title tuning. Layered over the base wine tuning
# (lib/backends/wine/defaults.nix) by the module merge, so this states only what is SPECIFIC to
# Skyrim SE. Bethesda Creation Engine (D3D11 → DXVK → Vulkan).
{
  # Graphics driver: x11 (XWayland), NOT the default winewayland — winewayland's fractional-scale
  # resize loop NULL-derefs winevulkan's vkCreateSwapchainKHR; x11 avoids it
  # (docs/research/winewayland-fractional-scaling.md).
  graphics = {
    value = "x11";
    reason = "winewayland fractional-scale surface resizes drive a DXVK swapchain-recreation loop that NULL-derefs winevulkan; x11 (the config the working build used) avoids it.";
  };

  # PROPNIX_DPI's LogPixels stamp makes wine render at the logical size on a fractional display, and
  # the game exits. The launcher unsets a listed variable before anything else, so a globally
  # exported PROPNIX_DPI writes no stamp here, and the HKCU three-way merge prunes one an earlier
  # launch wrote. PROPNIX_FPS is safe: setup.sh keeps iPresentInterval in agreement with the cap.
  brokenVariables = [ "PROPNIX_DPI" ];

  # Saves (`saveBinds`) and the display/quality seeding (`setupScript`) are in default.nix.
}

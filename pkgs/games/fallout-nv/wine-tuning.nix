# Fallout: New Vegas Ultimate Edition — per-title tuning. Layered over the wine backend's platform-aware
# defaults (lib/backends/wine/defaults.nix), so this states only what is SPECIFIC to New Vegas.
# Obsidian/Bethesda 2010 title on the Gamebryo/NetImmerse engine, Direct3D 9. The main binary FalloutNV.exe
# is 32-bit (i386) — so on aarch64 it runs under wine WoW64 + box64's wowbox64.dll (the i386 CPU emulator),
# NOT the ARM64EC/x86_64 path the rest of the suite uses. D3D9 goes through the i386-windows platform
# default d3d = wined3d (an i386 PE builtin under box64), which translates D3D9 → OpenGL on the host GPU
# (verified: GL 4.3 context on the Apple M2 / Asahi Mesa). RENDERS on aarch64 with the fix below + the
# setupScript (default.nix).
{
  # wined3d PCI-ID spoof — REQUIRED to reach D3D9 device creation on Asahi. On the Asahi/Mesa GL backend
  # wined3d cannot map GL_VENDOR="Mesa"/GL_RENDERER="Apple M2" to a known PCI vendor (query_gpu_description →
  # VendorId 0xffff), and FalloutNV's Gamebryo renderer REFUSES to create a device on an unidentified adapter
  # (DIRECTLY verified: with a valid FalloutPrefs.ini but WITHOUT this override the game does not bounce to the
  # launcher yet still never calls CreateDevice; WITH it, CreateDevice succeeds and the intro renders). wined3d
  # honors these HKCU\Software\Wine\Direct3D overrides via wined3d_get_user_override_gpu_description (NO wine
  # patch needed), so present the adapter as an NVIDIA GeForce GTX 660 (vendor 0x10DE, device 0x11C0, 2048MB) —
  # a card wined3d knows and FNV accepts. Applied at runtime via the HKCU three-way merge.
  userReg = {
    "Software\\Wine\\Direct3D"."VideoPciVendorID" = {
      value = "4318"; # 0x10DE = NVIDIA
      type = "REG_DWORD";
      reason = "wined3d reports VendorId 0xffff for the unrecognized Asahi/Mesa GL renderer; FNV refuses CreateDevice on an unidentified adapter. Spoof NVIDIA (0x10DE).";
    };
    "Software\\Wine\\Direct3D"."VideoPciDeviceID" = {
      value = "4544"; # 0x11C0 = GeForce GTX 660
      type = "REG_DWORD";
      reason = "Pair with the spoofed NVIDIA vendor so wined3d resolves a concrete known card (GeForce GTX 660) that FNV accepts.";
    };
    "Software\\Wine\\Direct3D"."VideoMemorySize" = {
      value = "2048";
      reason = "Report 2GB VRAM (matches the spoofed GTX 660) so FNV's video-memory check passes.";
    };
  };
}

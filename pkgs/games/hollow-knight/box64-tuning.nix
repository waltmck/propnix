# Hollow Knight — box64 emulator tuning (the `config.box64` value; the Linux build run under box64 on aarch64,
# natively on x86_64). Imported as `box64 = import ./box64-tuning.nix` in default.nix — the box64 sibling of
# `wine = import ./wine-tuning.nix`. Only ever FORCED by the thin backend, so a Windows/wine build ignores it.
# The verified HK-Linux library triage from the box64 PoC.
#
# `bridgingLibs` = sonames box64 WRAPS (native aarch64 for the bridge AND x86_64 for the guest); `guestLibs` =
# guest-only x86_64.
{
  bridgingLibs =
    p: with p; [
      libgcc
      libx11
      libxext
      libxcursor
      libxinerama
      libxrandr
      libxscrnsaver
      libxi
      libxxf86vm
      libGL
      libglvnd
      vulkan-loader
      libxkbcommon
      wayland
      SDL2
      systemd
      libudev0-shim
      pipewire
      libpulseaudio
      alsa-lib
    ];
  guestLibs =
    p: with p; [
      glibc
      stdenv.cc.cc.lib
      zlib
      cairo
      pango
      glib
      dbus.lib
    ];
}

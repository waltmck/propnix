# Factorio — thin-backend library triage (the `config.box64` value). Only ever FORCED by a thin backend, so
# the wine/Windows combos ignore it.
#
# Factorio static-links nearly everything: its own ELF declares only `libresolv / libsteam_api / libm / libc`
# as NEEDED (with `RUNPATH $ORIGIN` for the Steam lib). Every display, input and audio library is dlopened by
# SONAME at runtime — the bundled-SDL2 pattern — so none of them appears in `readelf -d` and all of them must
# instead be reachable through the launch's LD_LIBRARY_PATH. The list below is exactly the set of SONAMEs the
# binary carries as dlopen targets (`strings bin/arm64/factorio`), mapped to nixpkgs.
#
# `bridgingLibs` = sonames box64 WRAPS, so they are resolved TWICE on aarch64 (native aarch64 for the bridge,
# x86_64 for the guest); `guestLibs` = guest-only. On the NATIVE face (aarch64 payload on aarch64, x86_64 on
# x86_64) there is no guest/host split at all and both lists resolve from the host `pkgs` — which is what
# makes one triage serve all three thin combinations.
{
  bridgingLibs =
    p: with p; [
      # GL / Vulkan / EGL — the renderer.
      libGL
      libglvnd
      vulkan-loader
      libdrm
      mesa
      # X11. Wider than the binary's own dlopen list because this is also the fallback path under box64
      # (see `SDL_VIDEODRIVER` in default.nix), and SDL's x11 backend probes for the whole family — the
      # set verified on hollow-knight, which trips the same box64 wall.
      libx11
      libxext
      libxcursor
      libxrandr
      libxi
      libxfixes
      libxinerama
      libxscrnsaver
      libxxf86vm
      # Wayland (+ libdecor for client-side decorations). Used on the NATIVE face; under box64 SDL is
      # pinned to x11, so these ride along unused rather than being dropped — the same triage serves both.
      wayland
      libxkbcommon
      libdecor
      # Audio: PulseAudio first, ALSA as the fallback path.
      libpulseaudio
      alsa-lib
      # Input device enumeration (SDL's udev backend) + the desktop bus.
      systemd
      libudev0-shim
      dbus.lib
    ];
  guestLibs =
    p: with p; [
      glibc
      stdenv.cc.cc.lib
    ];
}

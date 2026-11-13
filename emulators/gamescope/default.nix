# gamescope — the nested compositor every game runs inside (propnix-launcher spawns the game's inner phase as
# gamescope's child; see pkgs/propnix-launcher/src/gamescope.rs). Its Wayland backend makes gamescope ONE
# Wayland client of the host compositor whatever the game speaks: the game draws to gamescope's own Xwayland
# (winex11 / SDL x11), gamescope scales the result to its window and presents it.
#
# nixpkgs' derivation is reused for the build (its meson flags, the shaders-path / gamescopereaper patches,
# the system-library and stb patches) with three changes:
#   * the newest upstream release instead of the nixpkgs pin;
#   * `enableWsi`: the Vulkan WSI layer (VkLayer_FROG_gamescope_wsi) is built into the SAME output, so one
#     store path carries `bin/gamescope` and `share/vulkan/implicit_layer.d`. The launcher puts that `share`
#     on the game's XDG_DATA_DIRS; the layer is what hands a nested X11 Vulkan swapchain (DXVK, vkd3d,
#     winevulkan) to gamescope directly, HDR colorspaces included;
#   * ./patches, applied after nixpkgs' own in NUMERIC-PREFIX order — drop a `NNNN-name.patch` in to add one:
#       0001  the Wayland backend on a render-only GPU (Asahi): only the DRM backend needs a primary node;
#       0002  `--app-id` / `--title` for the host toplevel, so the window maps to the game's desktop entry;
#       0003  touchpad (finger / continuous) scrolling, which the Wayland backend otherwise drops;
#       0004  focusing its own window through xdg-activation, on request from a client of its X server;
#       0005  `--no-hotkeys`: the nested backends' Super+key shortcuts off, so the game gets every key;
#       0006  an upstream startup race (the Wayland input thread started before the members it reads).
#
# Native on both arches (built by the cachix `tools` job; ci/cache-audit.sh keeps that true).
{
  lib,
  gamescope,
  fetchFromGitHub,
}:
let
  # Content-addressed so only the patches' bytes feed the build.
  patchesDir = builtins.path {
    path = ./patches;
    name = "gamescope-patches";
  };
in
(gamescope.override { enableWsi = true; }).overrideAttrs (old: rec {
  version = "3.17.0";
  src = fetchFromGitHub {
    owner = "ValveSoftware";
    repo = "gamescope";
    tag = version;
    fetchSubmodules = true;
    hash = "sha256-7+KC69Ps86IkICMJdtg2x9b0A6SwE7ITKP0yibZ2bx8=";
  };
  patches =
    old.patches
    ++ map (f: "${patchesDir}/${f}") (lib.naturalSort (builtins.attrNames (builtins.readDir patchesDir)));
})

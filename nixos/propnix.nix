# NixOS module for propnix host wiring. Enabling it does the two things a host needs to BUILD and RUN
# propnix games that the games themselves can't do from inside a derivation:
#   1. binds the credential directory into the Nix build sandbox at the fixed guest path `/propnix`, so
#      credentialed FODs (e.g. the GOG payload fetch) can read `/propnix/credentials.toml`;
#   2. loads the `ntsync` kernel module (in-kernel Windows sync primitives) that wine uses for fast,
#      correct synchronization.
#
# The launcher assembles each wine prefix inside an unprivileged user+mount namespace; those are enabled by
# default on NixOS, so this module adds nothing for them (the launcher errors clearly if they're disabled).
#
# Exposed as the flake's `nixosModules.propnix` (and `.default`). It adds no game packages — reference those
# directly, e.g. `inputs.propnix.packages.${system}.hollow-knight`.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.propnix;
in
{
  options.services.propnix = {
    enable = lib.mkEnableOption "propnix host support (GOG credential sandbox path + ntsync)";

    credentialsPath = lib.mkOption {
      # A plain string (a host path/id), deliberately NOT `types.path`: a `types.path` would copy the
      # credential dir into the world-readable store. The value is only ever used as a sandbox bind target.
      type = lib.types.str;
      default = "/var/tmp/propnix";
      example = "/var/lib/propnix";
      description = ''
        Host directory holding the propnix credential config (`credentials.toml`, which in turn names the
        GOG token dir). When {option}`services.propnix.enable` is set, this is bound into the Nix build
        sandbox as `/propnix` via {option}`nix.settings.extra-sandbox-paths`, so credentialed fetches can
        read it. Make it `nixbld`-readable. Never copied into the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Expose the credential dir inside the build sandbox at the fixed guest path propnix fetchers expect.
    nix.settings.extra-sandbox-paths = [ "/propnix=${cfg.credentialsPath}" ];

    # wine's ntsync backend needs the /dev/ntsync char device the kernel module provides.
    boot.kernelModules = [ "ntsync" ];
  };
}

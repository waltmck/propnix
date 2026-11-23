# Maintained source pins and packaging exceptions. sources.nix adds automatically locked streams from
# games' versions.json files and fills defaults from policy.nix. Patch families may serve many streams.
{
  "2022.3" = {
    branch = "unity-2022.3-mbe";
    targets = [ "aarch64ec-windows" ];
    mono = {
      rev = "b8eb56fab45dd52845fabba7b7ddc9a80b2b0498";
      hash = "sha256-QRpU0Wck/OEdWQuOeDdzxPeC69Y5LGMzGnI/4coJ+Gs=";
    };
    bdwgc = {
      rev = "8167f758c8e8d9c4a276971629d0ca98e20759f3";
      hash = "sha256-WxjDLmjeAMzn7EHlN13ENlffN8+sSJ7vPoW9jHtNJhg=";
    };
  };
  "6000.0" = {
    branch = "unity-6000.0-mbe";
    patchFamily = "6000";
    extraPatchFamilies = [ "6000.0" ];
    targets = [
      "aarch64-windows"
      "aarch64ec-windows"
    ];
    mono = {
      rev = "e3f5e86f047452d5ae757c195490df0059418621";
      hash = "sha256-94Ku7xkvm0nobDRQD777K8+gy8dF+e+ifVZh1sJydEs=";
    };
    bdwgc = {
      rev = "1113fefc4ba0e895767ac780d84e9e456fd624db";
      hash = "sha256-pCEPVT7rpWsWcNnpeSblgiwW9ClL+UIXWdC4HJ9psnQ=";
    };
  };
  "6000.3" = {
    branch = "unity-6000.3-mbe";
    patchFamily = "6000";
    targets = [
      "aarch64-windows"
      "aarch64ec-windows"
    ];
    mono = {
      rev = "c4940ce59f26bb06fc4863ca55c877f1eb0a515a";
      hash = "sha256-Gv0ztFwhZoB3YmcI8loHJyfHindceL0pUkUgQV3q1Mg=";
    };
    bdwgc = {
      rev = "adbb5d9f63daa742274e67a9c95db3c91d39b1f3";
      hash = "sha256-pa0qukeIQRV3mtn47pY4tMYoChMUwoqIZ0aY94Kq7cQ=";
    };
  };
}

# Synthetic future stream: prove pure package generation from a source lock without relying on an
# upstream release or downloading its source. Build checks exercise the real supported streams in CI.
{ lib, scope }:
let
  source = { inherit (scope.unityMonoPins."6000.3") mono bdwgc; };
  document = {
    fetchInfo.steam."x86_64-windows" = [
      {
        unityVersion = "6000.99.1f1";
        unityScripting = "mono";
      }
    ];
    unityMonoSources."6000.99" = source;
  };
  registry = documents: import ../../emulators/unity-mono/sources.nix { inherit documents; };
  pins = registry { test = document; };
  automatic = scope.overrideScope (_: _: { unityMonoPins = pins; });
  changed = document // {
    unityMonoSources."6000.99" = source // {
      mono = source.mono // {
        rev = "0000000000000000000000000000000000000000";
      };
    };
  };
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  removed = registry {
    test = document // {
      fetchInfo = { };
    };
  };
  il2cpp = registry {
    test = document // {
      fetchInfo.steam."x86_64-windows" = [
        {
          unityVersion = "6000.99.1f1";
          unityScripting = "il2cpp";
        }
      ];
    };
  };
in
pins."6000.99".patchFamily == "6000"
&& pins."6000.99".branch == "unity-6000.99-mbe"
&&
  pins."6000.99".targets == [
    "aarch64-windows"
    "aarch64ec-windows"
  ]
&&
  registry {
    a = document;
    b = document;
  } == pins
&& !(removed ? "6000.99")
&& !(il2cpp ? "6000.99")
&& rejects (registry {
  a = document;
  b = changed;
})
&& rejects (registry {
  test = document // {
    unityMonoSources."6000.99" = { };
  };
})
&& (
  automatic.unityMono == null
  || (
    (automatic.unityMono.forVersion "6000.99.1f1").drvPath
    == automatic.unityMono.streams."6000.99".drvPath
    && (automatic.winPkgs.aarch64-windows.unityMono.forVersion "6000.99.1f1").stream == "6000.99"
  )
)

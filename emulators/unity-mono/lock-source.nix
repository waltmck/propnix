# Only the pin command evaluates this with --impure. Ordinary flake evaluation imports sources.nix,
# which reads committed data and never fetches a moving branch. Package construction stays in Nix.
{
  version,
  sources ? import ./sources.nix { },
}:
let
  parts = builtins.match "([0-9]+)\\.([0-9]+)(\\..*)?" version;
  stream =
    if parts == null then
      throw "propnix: invalid Unity version ${version}"
    else
      "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}";
  fetch =
    repo: args:
    let
      tree = builtins.fetchTree (
        {
          type = "github";
          owner = "Unity-Technologies";
          inherit repo;
        }
        // args
      );
    in
    {
      rev = tree.rev;
      hash = tree.narHash;
    };
  submodule =
    repo: rev: path: expected:
    let
      entry = builtins.fromJSON (
        builtins.readFile (
          builtins.fetchurl "https://api.github.com/repos/Unity-Technologies/${repo}/contents/${path}?ref=${rev}"
        )
      );
    in
    if
      (entry.type or "") == "submodule"
      && builtins.elem (entry.submodule_git_url or "") [
        "https://github.com/Unity-Technologies/${expected}.git"
        "https://github.com/Unity-Technologies/${expected}"
        "../${expected}.git"
      ]
    then
      entry.sha
    else
      throw "propnix: Unity Mono ${stream}: unexpected ${path} submodule; manual packaging is required";
  mono = fetch "mono" { ref = "unity-${stream}-mbe"; };
  bdwgc = fetch "bdwgc" { rev = submodule "mono" mono.rev "external/bdwgc" "bdwgc"; };
  libatomicOps = fetch "libatomic_ops" {
    rev = submodule "bdwgc" bdwgc.rev "libatomic_ops" "libatomic_ops";
  };
in
{
  inherit stream;
  maintained = (import ./pins.nix) ? ${stream};
  source =
    sources.${stream} or ((import ./policy.nix stream) // { inherit mono bdwgc libatomicOps; });
}

# Pure source registry. Pinning records new streams in the same versions.json transaction as the game;
# removing its last consumer removes that stream automatically. pins.nix holds maintained overrides.
{
  gamesDir ? ../../pkgs/games,
  documents ? builtins.listToAttrs (
    builtins.concatMap (
      name:
      let
        file = gamesDir + "/${name}/versions.json";
      in
      if (builtins.readDir gamesDir).${name} == "directory" && builtins.pathExists file then
        [
          {
            inherit name;
            value = builtins.fromJSON (builtins.readFile file);
          }
        ]
      else
        [ ]
    ) (builtins.attrNames (builtins.readDir gamesDir))
  ),
}:
let
  defaults = stream: pin: (import ./policy.nix stream) // pin;
  normalize =
    stream: pin:
    let
      sourceOK =
        s:
        builtins.isAttrs s
        && builtins.isString (s.rev or null)
        && builtins.isString (s.hash or null)
        && builtins.match "[0-9a-f]{40}" (s.rev or "") != null
        && builtins.match "sha256-[A-Za-z0-9+/]{43}=" (s.hash or "") != null;
      valid =
        builtins.match "[0-9]+\\.[0-9]+" stream != null
        && builtins.isAttrs pin
        && sourceOK (pin.mono or { })
        && sourceOK (pin.bdwgc or { })
        && (!(pin ? libatomicOps) || sourceOK pin.libatomicOps);
    in
    if valid then
      defaults stream pin
    else
      throw "propnix: invalid Unity Mono ${stream} source lock; re-pin the game or package this stream manually in emulators/unity-mono";
  maintained = builtins.mapAttrs normalize (import ./pins.nix);
  addGame =
    registry: name:
    let
      doc = documents.${name};
      rows = builtins.concatLists (
        builtins.map (
          platforms:
          let
            rows = platforms."x86_64-windows" or null;
          in
          if rows == null then [ ] else rows
        ) (builtins.attrValues (doc.fetchInfo or { }))
      );
      streamOf =
        version:
        let
          parts = builtins.match "([0-9]+)\\.([0-9]+)(\\..*)?" version;
        in
        if parts == null then
          throw "propnix (${name}): invalid Unity version ${version}"
        else
          "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}";
      needed = builtins.map (r: streamOf r.unityVersion) (
        builtins.filter (r: r ? unityVersion && (r.unityScripting or null) != "il2cpp") rows
      );
      addStream =
        acc: stream:
        let
          pin = normalize stream doc.unityMonoSources.${stream};
        in
        if !(builtins.elem stream needed) then
          acc
        else if acc ? ${stream} && acc.${stream} != pin then
          throw "propnix: conflicting Unity Mono ${stream} source locks in ${name}/versions.json; use one source revision per stream or update emulators/unity-mono/pins.nix"
        else
          acc // { ${stream} = pin; };
    in
    builtins.foldl' addStream registry (builtins.attrNames (doc.unityMonoSources or { }));
in
builtins.foldl' addGame maintained (builtins.attrNames documents)

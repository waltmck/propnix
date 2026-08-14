# Don't Starve (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Klei's custom C++/Lua engine (renders via OpenGL/D3D). ARCH-AGNOSTIC: the same spec runs on
# both hosts; makeAppWine + the scope pick the arch-appropriate emulator set, and the SAME Windows payload
# (a content-addressed FOD) is shared across arches. Payload = the pinned GOG Galaxy build fetched with
# gogdl (D15), delivered as the game tree directly (no InnoSetup).
#
#   nix run .#dont-starve --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  makeAppWine,
  fetchGogGalaxyBuild,
}:
let
  pins = (lib.importJSON ./versions.json).backends.gog-galaxy-windows;
  tuning = import ./tuning.nix;
in
makeAppWine {
  pname = "dont-starve";
  appid = "dont-starve";
  name = "Don't Starve";
  # gogdl takes the NUMERIC productId (not the slug).
  payload = fetchGogGalaxyBuild (pins.components.base // { pname = "dont-starve-win"; });
  # The goggame-1207659210.info isPrimary FileTask: bin/dontstarve.exe (workingDir "bin"). This IS the real
  # game binary (not a launcher stub). It is a 32-bit i386 PE — this build ships NO 64-bit binary (only bin/,
  # no bin64/), so it runs via wine WoW64 + FEX's i386 backend (libwow64fex.dll) on aarch64. The launcher's
  # cwd is C:\game, so `bin/dontstarve.exe` resolves to C:\game\bin\dontstarve.exe and finds ..\data + data.
  exe = "bin/dontstarve.exe";
  # Klei's engine resolves its data root from the CWD (not the exe path) and expects cwd = the exe's own
  # dir, finding assets at ..\data — the goggame-1207659210.info workingDir "bin". Without this the launcher's
  # default cwd (C:\game payload root) makes it look for ..\data = C:\data and it dies at startup with
  # `ERROR: Missing Shader 'shaders/font.ksh'` + a reader.h buffer assert (DIRECTLY verified). cwd = C:\game\bin
  # finds C:\game\data.
  workingDir = "bin";
  inherit tuning;
}

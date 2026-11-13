# builders/gamescope-scaling.nix — the app-options `gamescope` record → its launcher-config fields, checked
# against what gamescope accepts (`-F` / `-S`), so a typo fails at eval, not as a game that never starts.
# A null field is baked as null: the launcher then applies its own default (gamescope.rs).
{ lib }:
scaling:
let
  checked =
    name: allowed: value:
    if value == null then null else assert lib.assertOneOf name value allowed; value;
in
{
  gamescopeFilter = checked "gamescope.filter" [
    "linear"
    "nearest"
    "fsr"
    "nis"
    "pixel"
    "sgsr"
  ] (scaling.filter or null);
  gamescopeScaler = checked "gamescope.scaler" [
    "auto"
    "integer"
    "fit"
    "fill"
    "stretch"
  ] (scaling.scaler or null);
}

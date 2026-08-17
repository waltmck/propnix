# builders/desktop-item.nix — mkDesktopItem: a `.desktop` launcher (+ symbolic icon) for a propnix app (§5).
#
# Every propnix app ships a desktop entry so it appears in the DE's launcher, keyed by a stable reverse-DNS
# id `org.propnix.<appid>`. The FULL-COLOR raster icon is installed separately as a freedesktop hicolor
# theme (lib/icons/*, merged into the app by mkLauncherPackage); this builder just references it by name
# via `Icon=` and, if given, installs the monochrome `-symbolic.svg` variant (for DE contexts that prefer
# symbolic icons). `startupWMClass` ties the game window to this entry (wine sets the class to the exe
# basename).
{
  lib,
  makeDesktopItem,
  runCommand,
  symlinkJoin,
}:
{
  appid,
  name, # human-visible name (Name=)
  exec, # command to run (typically the app's bin/<pname>, resolved from PATH once installed)
  startupWMClass, # wine's top-level window class (exe basename); ties the window to this entry
  hasIcon ? true, # whether an icon theme is installed for this id (→ set Icon=)
  iconSymbolic ? null, # a monochrome symbolic SVG (currentColor), or null
}:
let
  desktopId = "org.propnix.${appid}";

  item = makeDesktopItem {
    name = desktopId; # .desktop basename → share/applications/org.propnix.<appid>.desktop
    desktopName = name;
    inherit exec;
    # Icon=<id>: resolved from the hicolor theme (raster sizes from extract-pe-icon; the -symbolic.svg
    # below). null → no Icon line.
    icon = if hasIcon then desktopId else null;
    categories = [ "Game" ];
    inherit startupWMClass;
    startupNotify = true;
  };

  # Symbolic variant: `<id>-symbolic.svg` under scalable/apps, the freedesktop convention for symbolic
  # icons (GTK/GNOME pick it up in symbolic contexts).
  symbolicPkgs = lib.optional (iconSymbolic != null) (
    runCommand "propnix-icon-symbolic-${appid}" { } ''
      install -Dm444 ${iconSymbolic} "$out/share/icons/hicolor/scalable/apps/${desktopId}-symbolic.svg"
    ''
  );
in
symlinkJoin {
  name = "propnix-desktop-${appid}";
  paths = [ item ] ++ symbolicPkgs;
}

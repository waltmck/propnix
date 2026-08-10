# Windows Hollow Knight (GOG) installer — credentialed FOD. The Windows installer is a SINGLE
# self-contained InnoSetup .exe (~1.2 GiB, file id en1installer0; there is no en1installer1+).
# innoextract reads the game straight out of this one file. Content-addressed by outputHash, so
# once fetched it is reused without re-downloading.
#
# Build:  nix-build ... --option extra-sandbox-paths /propnix=/var/tmp/propnix
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },
}:
pkgs.runCommand "hollow-knight-win-installer"
  {
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    outputHash = "sha256-2gXRiztXPPABNWObeVCnMdXAgHvmbGMCMtRnG3IfuOQ=";

    nativeBuildInputs = [ pkgs.lgogdownloader pkgs.jq ];
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    allowSubstitutes = false;
    preferLocalBuild = true;
  }
  ''
    if [ ! -r /propnix/credentials.toml ]; then
      echo "propnix: no credentials at /propnix/credentials.toml" >&2
      echo "  nix build --extra-sandbox-paths /propnix=/var/tmp/propnix ..." >&2
      exit 1
    fi
    creddir=$(grep -oP 'credentialDir\s*=\s*"\K[^"]+' /propnix/credentials.toml)
    export XDG_CONFIG_HOME="$TMPDIR/cfg" XDG_CACHE_HOME="$TMPDIR/cache"
    install -d -m700 "$XDG_CONFIG_HOME/lgogdownloader" "$XDG_CACHE_HOME"
    install -m600 "$creddir"/* "$XDG_CONFIG_HOME/lgogdownloader/"
    mkdir -p "$TMPDIR/dl" && cd "$TMPDIR/dl"

    lgogdownloader --download-file "hollow_knight/en1installer0" --no-remote-xml \
      -o hollow_knight_win_installer.exe

    mv hollow_knight_win_installer.exe "$out"
  ''

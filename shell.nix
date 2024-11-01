{}:
with builtins;
let
  pkgs = (import ./default.nix {});
  lib = pkgs.lib;
  channels = (import ./versions.nix { });
  nixPathUpstreams =
    lib.concatStringsSep
    ":"
    (lib.mapAttrsToList (name: channel: "${name}=${channel}") channels);

  nixosRepl = pkgs.writeShellScriptBin "nixos-repl" ''
    sudo -E nix repl nixos-repl.nix
  '';

in pkgs.mkShell {
  name = "fc-nixos";
  buildInputs = [
    pkgs.scriv
    pkgs.bash
  ];
  shellHook = ''
    export NIX_PATH="fc=${toString ./.}:${nixPathUpstreams}:nixos-config=/etc/nixos/configuration.nix"
    export PATH=$PATH:${nixosRepl}/bin
  '';
}

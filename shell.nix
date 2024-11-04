with import <nixpkgs> {};
mkShell {
  packages = [ python3 python3Packages.gitpython ];
}

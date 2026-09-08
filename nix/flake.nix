{
  description = "Invidious Nix Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs-fijxu.url = "github:fijxu/nixpkgs/crystal_1_20_crystal_1_21";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-fijxu,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pkgsFijxu = nixpkgs-fijxu.legacyPackages.${system};
        devPackages = import ./packages.nix { inherit pkgs pkgsFijxu; };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = devPackages;
        };
      }
    );
}

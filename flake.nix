{
  description = "Private, self-hosted AI agents that share compute across your devices";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    # The packages until they land in nixpkgs: mesh-llm and skippy
    # (NixOS/nixpkgs#571722), the Buzz suite, Berd and friends.
    nix-packages.url = "github:kleinbem/nix-packages";
    nix-packages.inputs.nixpkgs.follows = "nixpkgs";
    # Only for the home-manager module's check.
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [ inputs.treefmt-nix.flakeModule ];

      flake = {
        overlays.default = import ./overlay.nix inputs;

        nixosModules.default = {
          imports = [
            inputs.nix-packages.nixosModules.mesh-llm
            ./modules/nixos/mesh-agents.nix
          ];
          nixpkgs.overlays = [ inputs.self.overlays.default ];
        };

        homeManagerModules.default = import ./modules/home-manager/mesh-agents.nix {
          inherit (inputs.self) packages;
        };
      };

      perSystem =
        {
          lib,
          pkgs,
          system,
          ...
        }:
        let
          upstream = inputs.nix-packages.packages.${system};
          # The agent stack, as far as it builds on this system.
          stack = lib.filterAttrs (name: _: upstream ? ${name}) {
            mesh-llm = null;
            skippy = null;
            buzz-app = null;
            buzz-cli = null;
            buzz-relay = null;
            buzz-acp = null;
            berd = null;
            braindump = null;
          };
          mesh-agents = pkgs.callPackage ./pkgs/mesh-agents {
            inherit (upstream) mesh-llm;
          };
        in
        {
          packages = lib.mapAttrs (name: _: upstream.${name}) stack // {
            inherit mesh-agents;
            inherit (pkgs) goose-cli;
            default = mesh-agents;
          };

          checks = lib.optionalAttrs pkgs.stdenv.isLinux {
            module = import ./tests/module.nix {
              inherit pkgs;
              module = inputs.self.nixosModules.default;
            };
            home-manager = import ./tests/home-manager.nix {
              inherit pkgs;
              inherit (inputs) home-manager;
              module = inputs.self.homeManagerModules.default;
            };
          };

          treefmt.programs = {
            nixfmt.enable = true;
            deadnix.enable = true;
            statix.enable = true;
            shellcheck.enable = true;
          };
        };
    };
}

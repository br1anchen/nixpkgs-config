{
  description = "Brian's nixpkgs configuration for macOS and Arch Linux";

  inputs = {
    self.submodules = true;

    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Home manager
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Agent workflow
    herdr = {
      url = "git+https://github.com/herdrdev/herdr?ref=refs/tags/v0.7.5&submodules=1";
    };
    plannotator-src = {
      url = "github:backnotprop/plannotator/v0.25.1";
      flake = false;
    };
    vim-herdr-navigation-src = {
      url = "github:paulbkim-dev/vim-herdr-navigation/820d48f5d9c9a7dece6a4bebfa3982ec30bbfbb7";
      flake = false;
    };

    # Shameless plug: looking for a way to nixify your themes and make
    # everything match nicely? Try nix-colors!
    # nix-colors.url = "github:misterio77/nix-colors";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    let
      forAllSystems = nixpkgs.lib.genAttrs systems;
      systems = [
        "aarch64-linux"
        "i686-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      # Determine home directory based on system type
      mkHomeDirectory =
        system: username:
        if nixpkgs.lib.hasSuffix "darwin" system then "/Users/${username}" else "/home/${username}";

      # Reexport nixpkgs with our overlays applied
      # Accessible on our configurations, and through nix build, shell, run, etc.
      legacyPackages = forAllSystems (
        system:
        import inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = builtins.attrValues overlays;
        }
      );

      # Your custom packages and modifications
      overlays = {
        default = import ./overlay { inherit inputs; };
      };

      # Reusable nixos modules you might want to export
      # These are usually stuff you would upstream into nixpkgs
      nixosModules = import ./modules/nixos;

      # Reusable home-manager modules you might want to export
      # These are usually stuff you would upstream into home-manager
      homeManagerModules = import ./modules/home-manager;

      # Helper function to create home-manager configurations
      mkHome =
        {
          username,
          system,
          agentWorkflow ? true,
        }:
        let
          isDarwin = nixpkgs.lib.hasSuffix "darwin" system;
        in
        home-manager.lib.homeManagerConfiguration {
          pkgs = legacyPackages.${system};
          extraSpecialArgs = {
            inherit
              agentWorkflow
              inputs
              isDarwin
              ;
          };
          modules = (builtins.attrValues homeManagerModules) ++ [
            {
              home = {
                inherit username;
                homeDirectory = mkHomeDirectory system username;
                stateVersion = "22.05";
                sessionVariables = {
                  EDITOR = "nvim";
                  TERMINAL = "ghostty";
                };
              };
            }
            ./home-manager/home.nix
          ];
        };
    in
    {
      inherit
        overlays
        nixosModules
        homeManagerModules
        legacyPackages
        ;

      # Formatter for `nix fmt`
      formatter = forAllSystems (system: legacyPackages.${system}.nixfmt-rfc-style);

      # Devshell for bootstrapping
      # Accessible through 'nix develop' or 'nix-shell' (legacy)
      devShells = forAllSystems (system: {
        default = legacyPackages.${system}.callPackage ./shell.nix { };
      });

      packages = forAllSystems (
        system:
        let
          pkgs = legacyPackages.${system};
          herdrSupported = builtins.elem system [
            "aarch64-linux"
            "x86_64-linux"
            "aarch64-darwin"
          ];
          plannotatorSupported = builtins.elem system [
            "aarch64-linux"
            "x86_64-linux"
            "aarch64-darwin"
            "x86_64-darwin"
          ];
        in
        {
          inherit (pkgs) pi-coding-agent plannotator-pi-extension vim-herdr-navigation;
        }
        // nixpkgs.lib.optionalAttrs herdrSupported {
          herdr = inputs.herdr.packages.${system}.herdr;
        }
        // nixpkgs.lib.optionalAttrs plannotatorSupported {
          inherit (pkgs) plannotator;
        }
      );

      nixosConfigurations = {
        "br1anchen@dune" = nixpkgs.lib.nixosSystem {
          pkgs = legacyPackages.x86_64-linux;
          specialArgs = {
            inherit inputs;
          };
          modules = (builtins.attrValues nixosModules) ++ [
            ./nixos/configuration.nix
          ];
        };
      };

      # Home configurations use explicit usernames so pure evaluation works.
      # Usage: home-manager switch --flake .#darwin (macOS)
      #        home-manager switch --flake .#linux (Linux)
      #        home-manager switch --flake .#deck (Steam Deck with explicit username)
      homeConfigurations = {
        "darwin" = mkHome {
          username = "br1anchen";
          system = "aarch64-darwin";
        };
        "linux" = mkHome {
          username = "brian";
          system = "x86_64-linux";
        };

        "deck" = mkHome {
          username = "deck";
          system = "x86_64-linux";
          agentWorkflow = false;
        };
      };
    };
}

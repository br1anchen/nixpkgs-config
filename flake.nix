{
  description = "Brian's nixpkgs configuration for macOS and Arch Linux";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Home manager
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # TODO: Add any other flake you might need

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

      # Get current username from environment
      currentUser = builtins.getEnv "USER";

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
          username ? currentUser,
          system,
        }:
        let
          isDarwin = nixpkgs.lib.hasSuffix "darwin" system;
        in
        home-manager.lib.homeManagerConfiguration {
          pkgs = legacyPackages.${system};
          extraSpecialArgs = {
            inherit inputs isDarwin;
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

      # Home configurations - uses current $USER by default
      # Usage: home-manager switch --flake .#darwin (macOS)
      #        home-manager switch --flake .#linux (Linux)
      #        home-manager switch --flake .#deck (Steam Deck with explicit username)
      homeConfigurations = {
        # Generic configurations that use current $USER
        "darwin" = mkHome { system = "aarch64-darwin"; };
        "linux" = mkHome { system = "x86_64-linux"; };

        # Legacy/explicit configurations for specific users
        "deck" = mkHome {
          username = "deck";
          system = "x86_64-linux";
        };
      };
    };
}

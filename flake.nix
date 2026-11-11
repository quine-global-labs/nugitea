{
  description = "nugitea: pinned dev tools and the end-to-end test environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # What elixir_nugitea, the Nuxt frontend and the e2e suite need.
      # Cypress itself comes from e2e/package-lock.json.
      tools = pkgs: [
        pkgs.elixir_1_19
        pkgs.nodejs_24
        pkgs.git
        pkgs.curl
        pkgs.openssh # ssh-keygen, for nugitea's SSH host key
      ];
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell { packages = tools pkgs; };
      });

      # `nix run .#e2e`: see e2e/run.sh.
      apps = forAllSystems (pkgs: {
        e2e = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "nugitea-e2e";
              runtimeInputs = tools pkgs;
              text = builtins.readFile ./e2e/run.sh;
            }
          }/bin/nugitea-e2e";
        };
      });
    };
}

{
  description = "Reproducible Nix packaging for NyaTerm";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Upstream NyaTerm source, pinned to a release tag so the packaged
    # MCP sidecar (src-tauri/crates/nyaterm-mcp) is always present.
    # Bump with `nix flake update nyaterm-src` after moving this to a newer tag.
    # For local debugging against another branch or a local checkout, override
    # without touching the lockfile:
    #   nix build .#nyaterm --override-input nyaterm-src \
    #     github:nyakang/nyaterm/main --no-write-lock-file
    nyaterm-src = {
      url = "github:nyakang/nyaterm/v1.2.12";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , nyaterm-src
    ,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      packageFor =
        pkgs:
        pkgs.callPackage ./nix/package.nix {
          inherit nyaterm-src;
        };
    in
    {
      overlays = {
        default = final: prev: {
          nyaterm = packageFor final;
        };
        nyaterm = self.overlays.default;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
        in
        {
          nyaterm = pkgs.nyaterm;
          default = self.packages.${system}.nyaterm;
        }
      );

      apps = forAllSystems (system: {
        nyaterm = {
          type = "app";
          program = "${self.packages.${system}.nyaterm}/bin/nyaterm";
          meta = self.packages.${system}.nyaterm.meta;
        };
        default = self.apps.${system}.nyaterm;
      });

      checks = forAllSystems (system: {
        nyaterm = self.packages.${system}.nyaterm;
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
          package = pkgs.nyaterm;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ package ];
            packages = with pkgs; [
              cargo-tauri
              pnpm_10
              nodejs
              rustc
              cargo
              rustfmt
              clippy
              pkg-config
            ];
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (map (p: p.lib or p.out or p) package.buildInputs);
          };
        }
      );
    };
}

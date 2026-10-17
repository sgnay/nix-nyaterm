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
      url = "github:nyakang/nyaterm/v1.3.0";
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
      lib = nixpkgs.lib;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
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
          pkgs = pkgsFor system;
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

      # Assertions on the built package, so `nix flake check` and
      # `nix build .#checks.<system>.nyaterm` catch a package that lost an
      # output or shipped a binary that reads its frontend from disk.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          package = self.packages.${system}.nyaterm;
          requiredPaths = [
            "bin/nyaterm"
            "bin/nyaterm-mcp"
            "share/applications/nyaterm.desktop"
            "share/icons/hicolor/32x32/apps/nyaterm.png"
            "share/icons/hicolor/128x128/apps/nyaterm.png"
            "share/icons/hicolor/256x256/apps/nyaterm.png"
          ];
        in
        {
          nyaterm = pkgs.runCommand "nyaterm-outputs-check"
            {
              nativeBuildInputs = [ pkgs.gnugrep ];
            } ''
            status=0
            for path in ${lib.concatMapStringsSep " " lib.escapeShellArg requiredPaths}; do
              if [ ! -e "${package}/$path" ]; then
                echo "error: expected package output missing: $path" >&2
                status=1
              fi
            done

            # The frontend must be embedded in the binary, not read from a source tree.
            if ! grep -rqa -- '/assets/' "${package}/bin"; then
              echo "error: frontend assets are not embedded in ${package}/bin" >&2
              status=1
            fi

            [ "$status" -eq 0 ] || exit 1
            echo "verified package outputs in ${package}"
            touch $out
          '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
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

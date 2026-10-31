{
  description = "Reproducible Nix packaging for NyaTerm";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Upstream NyaTerm source, pinned to an immutable commit so builds stay
    # reproducible. Tag `v2.0.0` predates the commit that teaches the binary to
    # honor NYATERM_PACKAGE_MANAGER, so the pin follows `main` until the next
    # v2.x.y release carries it; scripts/update-upstream.sh then advances the
    # pin tag by tag.
    #
    # For local debugging against another ref or a local checkout, override the
    # input without touching the lockfile:
    #   nix build .#nyaterm --override-input nyaterm-src \
    #     github:nyakang/nyaterm/main --no-write-lock-file
    #   nix build .#nyaterm --override-input nyaterm-src path:/path/to/nyaterm
    nyaterm-src = {
      url = "github:nyakang/nyaterm/cc35a5f93a7f6f9b129aa98af07b0185c8b39468";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nyaterm-src,
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
      # output. The application spawns its helpers from its own directory, so a
      # missing nyaterm-mcp, -rdp-helper or -vnc-helper breaks features only at
      # runtime and has to be caught here.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          package = self.packages.${system}.nyaterm;
          requiredPaths = [
            "bin/nyaterm"
            "bin/nyaterm-mcp"
            "bin/nyaterm-rdp-helper"
            "bin/nyaterm-vnc-helper"
            "share/applications/nyaterm.desktop"
            "share/icons/hicolor/32x32/apps/nyaterm.png"
            "share/icons/hicolor/64x64/apps/nyaterm.png"
            "share/icons/hicolor/128x128/apps/nyaterm.png"
            "share/icons/hicolor/256x256/apps/nyaterm.png"
            "share/icons/hicolor/512x512/apps/nyaterm.png"
          ];
        in
        {
          nyaterm = pkgs.runCommand "nyaterm-outputs-check" { } ''
            status=0
            for path in ${lib.concatMapStringsSep " " lib.escapeShellArg requiredPaths}; do
              if [ ! -e "${package}/$path" ]; then
                echo "error: expected package output missing: $path" >&2
                status=1
              fi
            done

            # The embedded UI assets get no assertion here: their paths also
            # occur as ordinary string literals in the binary (`"icons/..."`
            # in nyaterm-desktop), so a grep cannot tell an embedded asset
            # from a reference to one, and rust-embed turns a missing
            # `assets/` tree into a compile error in the first place.

            [ "$status" -eq 0 ] || exit 1
            echo "verified package outputs in ${package}"
            touch $out
          '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

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
              rustc
              cargo
              rustfmt
              clippy
            ];
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
            # `inputsFrom` only propagates the package's build inputs; GPUI's
            # Vulkan backend `dlopen`s libvulkan.so.1, and the package itself
            # supplies it through its wrapper rather than a build input. Add it
            # here so `cargo run` works without a system Vulkan loader.
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
              [ pkgs.vulkan-loader ] ++ map (p: p.lib or p.out or p) package.buildInputs
            );
          };
        }
      );
    };
}

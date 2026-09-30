# NyaTerm for Nix

Official Nix packaging repository for [NyaTerm](https://github.com/nyakang/nyaterm).

This repository maintains the Flake, package expression, development shell, and Nix CI separately from the upstream application source.

## Install

Run without installing:

```bash
nix run github:nyakang/nix-nyaterm
```

Install into the current user's profile:

```bash
nix profile install github:nyakang/nix-nyaterm
```

The package supports `x86_64-linux` and `aarch64-linux`. It bundles the MCP sidecar, a desktop entry, icons, and handlers for `nyaterm://`, `ssh://`, and `telnet://`. Nix manages package updates; NyaTerm's in-app update UI is disabled for Nix-built packages.

The default package does not contain a GitHub OAuth Client ID, so GitHub Gist Device Flow authorization is unavailable unless you override `githubGistClientId`. WebDAV and S3 sync do not require this setting. Termius credential import uses Secret Service; provide a Secret Service implementation in your desktop environment if you need that import path.

## Use the package in NixOS or Home Manager

Add the repository as a flake input and import its overlay:

```nix
inputs.nix-nyaterm.url = "github:nyakang/nix-nyaterm";

nixpkgs.overlays = [ inputs.nix-nyaterm.overlays.default ];
environment.systemPackages = [ pkgs.nyaterm ];
```

For Home Manager, use `home.packages` instead of `environment.systemPackages`:

```nix
inputs.nix-nyaterm.url = "github:nyakang/nix-nyaterm";

nixpkgs.overlays = [ inputs.nix-nyaterm.overlays.default ];
home.packages = [ pkgs.nyaterm ];
```

To enable GitHub Gist Device Flow, pass the public OAuth Client ID while overriding the package:

```nix
pkgs.nyaterm.override { githubGistClientId = "your_client_id"; }
```

## Development shell

Clone this repository and enter its development shell to get the Rust, Node/pnpm, Tauri, and Linux native dependencies:

```bash
nix develop
```

Then work in a clone of the NyaTerm source repository from the shell.

## Maintainer note

The `nyaterm-src` input points at the `nyakang/nyaterm` upstream release tag. The pin must be a tag or revision that ships `src-tauri/crates/nyaterm-mcp`, since that crate is built and installed as the bundled MCP sidecar; older revisions predating the MCP support cannot be packaged.

To build against an in-development branch or a local checkout without changing the committed lock file, override the input:

```bash
nix build .#nyaterm --override-input nyaterm-src github:nyakang/nyaterm/main --no-write-lock-file
nix build .#nyaterm --override-input nyaterm-src path:/path/to/nyaterm --no-write-lock-file
```

To move to a newer NyaTerm release, edit the tag in `flake.nix` and run `nix flake update nyaterm-src` to refresh `flake.lock` before publishing this package.

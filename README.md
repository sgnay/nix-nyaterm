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
nix profile add github:nyakang/nix-nyaterm
```

The package supports `x86_64-linux` and `aarch64-linux`. It bundles the MCP sidecar, a desktop entry, icons, and handlers for `nyaterm://`, `ssh://`, and `telnet://`. Nix manages package updates. The build sets `NYATERM_PACKAGE_MANAGER=nix`, which upstream releases do not read yet; the in-app updater remains present and can check for releases, but cannot replace the binary because `/nix/store` is read-only.

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

## Updating to a new NyaTerm release

The source stays pinned to a release tag so builds remain reproducible, so something has to move that pin. One command does it:

```bash
./scripts/update-upstream.sh          # update the working tree, leave the commit to you
./scripts/update-upstream.sh --commit # update and commit (managed files must be clean)
```

It advances the tag to the newest stable `vX.Y.Z` release across all major/minor lines; pre-release tags are skipped. It refreshes `flake.lock`, then adopts each fixed-output hash Nix reports until the build is clean. Anything else that fails the build is reported as-is instead of being patched around. It finally builds `.#checks.<system>.nyaterm`, which asserts the package outputs, so a bump that loses a file fails the run instead of reaching a pull request.

`Update NyaTerm` (`.github/workflows/update.yml`) runs this weekly and opens a pull request when a bump lands, so the usual workflow is review and merge. It always pushes to the fixed branch `chore/update-nyaterm` and reuses the open pull request on that branch rather than opening duplicates, so an unmerged bump simply gets refreshed. Because a pull request created with the default `GITHUB_TOKEN` does not trigger `pull_request` workflows, that workflow builds both architectures itself before opening the pull request. The build must pass before an update is committed or a pull request is opened; a release with an incompatible source layout needs a package-expression update rather than a hash change.

The source tag and `flake.lock` change on a release bump, and fixed-output hashes may change as well. The package version comes from upstream `package.json` and the Cargo lock is read from the source, so neither needs editing. Two caveats worth knowing:

- The pin must ship `src-tauri/crates/nyaterm-mcp`, since that crate is built and installed as the bundled MCP sidecar. Revisions before `v1.2.6` cannot be packaged.
- `v2.0.0-preview.*` tags are skipped as pre-releases. The stable `v2.0.0` release uses a pure-Rust rewrite with a different tree layout (no `src-tauri/`), so the build will fail until `nix/package.nix` is adapted by hand.

## Maintainer note

The `nyaterm-src` input points at the `nyakang/nyaterm` upstream release tag.

To build against an in-development branch or a local checkout without changing the committed lock file, override the input:

```bash
nix build .#nyaterm --override-input nyaterm-src github:nyakang/nyaterm/main --no-write-lock-file
nix build .#nyaterm --override-input nyaterm-src path:/path/to/nyaterm --no-write-lock-file
```

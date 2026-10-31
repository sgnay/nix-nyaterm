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

The package supports `x86_64-linux` and `aarch64-linux`. It ships the application together with the three helper processes it spawns (`nyaterm-mcp`, `nyaterm-rdp-helper`, `nyaterm-vnc-helper`), a desktop entry, icons, and handlers for `nyaterm://`, `ssh://`, and `telnet://`.

NyaTerm 2.x is a pure-Rust GPUI application: the UI assets and translation catalogs are embedded in the binary, so the package has no separate frontend or sidecar outputs. All four binaries live in `$out/bin` because the application resolves its helpers next to its own executable.

The build bakes `NYATERM_PACKAGE_MANAGER=nix` into the binary, which makes Nix the owner of the update channel: the in-app updater hides its update entry, the tray menu drops the update action, and the About dialog reports the package manager.

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

Clone this repository and enter its development shell to get the Rust toolchain plus the GPUI, GTK, Wayland/X11, and font dependencies:

```bash
nix develop
```

Then work in a clone of the NyaTerm source repository from the shell. There is no Node or pnpm step in 2.x.

## Updating to a new NyaTerm release

The source stays pinned so builds remain reproducible, so something has to move that pin. One command does it:

```bash
./scripts/update-upstream.sh          # update the working tree, leave the commit to you
./scripts/update-upstream.sh --commit # update and commit (managed files must be clean)
```

It advances the pin to the newest stable `vX.Y.Z` release of the line the package is written for (`v2`, so `v2.x.y`); pre-release tags are skipped and a pin on any other line is refused rather than moved. It refreshes `flake.lock`, then adopts the vendored-dependency hash Nix reports until the build is clean. Anything else that fails the build is reported as-is instead of being patched around. It finally builds `.#checks.<system>.nyaterm`, which asserts the package outputs, so a bump that loses a helper binary or an icon fails the run instead of reaching a pull request.

A pin that is a full commit SHA is the one other accepted shape: it is used while `main` carries a change that no release contains yet, as the `NYATERM_PACKAGE_MANAGER` support was before the next release. The script moves that pin to a release only when a clone of upstream shows the release contains the commit, and otherwise keeps it and says why; upstream squashes a release before tagging it, so a tag usually points at a different commit and a release chosen by tag alone could predate the change. A commit a tag does point at is normalized to that tag. A commit that upstream can no longer fetch, a partial SHA, a branch name, or another repository is a hard error, so a green run can never mean the script silently stopped understanding the pin.

The pin decisions are covered by `scripts/tests/update-upstream-test.sh`, which runs the real script against a throwaway repository with stubbed `git` and `nix`, so a change to that logic is checked without network or build. It runs in CI next to the flake check.

The weekly run is not idle while the pin is a commit: a separate `verify-pin` job builds, on both architectures, the pin of the branch the run comes from, so an unreachable revision or a dependency that no longer compiles fails the run in the same week. It is a cache hit whenever the pin has not moved.

`Update NyaTerm` opens a pull request when a bump lands, so the usual workflow is review and merge. It always pushes to the fixed branch `chore/update-nyaterm` and reuses the open pull request on that branch rather than opening duplicates, so an unmerged bump simply gets refreshed. Because a pull request created with the default `GITHUB_TOKEN` does not trigger `pull_request` workflows, that workflow builds both architectures itself before opening the pull request. The build must pass before an update is committed or a pull request is opened; a release with an incompatible source layout needs a package-expression update rather than a hash change.

The source pin, `flake.lock`, and the vendored `cargoHash` change on a release bump. The package version comes from the workspace `Cargo.toml`, and the dependency graph comes from the upstream `Cargo.lock`, so neither is copied into this repository. Three caveats worth knowing:

- The pin must build the whole default workspace: `crates/nyaterm-app` produces `nyaterm`, and the `nyaterm-mcp`, `nyaterm-rdp-helper` and `nyaterm-vnc-helper` helper crates must stay cargo default members. (`crates/nyaterm-activex-helper` also sits among them, but its Windows-only dependencies mean the Linux build produces no binary for it.) A revision that stops building the other helpers cannot be packaged.
- `v2.0.0-preview.*` tags are skipped as pre-releases. Moving between major lines is deliberate: the updater never crosses one, so a v3 rewrite would need the pin moved by hand with `nix/package.nix` adapted first.
- Tag `v2.0.0` predates the change that makes the binary honor `NYATERM_PACKAGE_MANAGER`, so the pin is the `main` commit carrying it until the next `v2.x.y` release. `flake.lock` keeps that commit reproducible; the weekly run replaces it with the release tag as soon as it can show the release contains that commit, and otherwise reports that the pin needs a hand-written bump.

## Maintainer note

`nyaterm-src` pins the upstream commit that introduces `NYATERM_PACKAGE_MANAGER`, because the newest release tag (`v2.0.0`) predates it. The hash and the pin move together: the weekly updater replaces the commit with the next stable `v2.x.y` tag that can be shown to contain it, and adopts the new `cargoHash` in the same run.

Local work does not need a pin change; override the input at build time:

```bash
nix build .#nyaterm --override-input nyaterm-src github:nyakang/nyaterm/main --no-write-lock-file
nix build .#nyaterm --override-input nyaterm-src path:/path/to/nyaterm --no-write-lock-file
```

An override whose `Cargo.lock` matches the pin reuses the committed `cargoHash`; a branch that changes the dependency graph needs the hash refreshed first.

# Nix 版 NyaTerm

[NyaTerm](https://github.com/nyakang/nyaterm) 的官方 Nix 打包仓库。

本仓库独立维护 Flake、软件包表达式、开发环境和 Nix CI，不与上游应用源码放在同一仓库中。

## 安装

无需安装，直接运行：

```bash
nix run github:nyakang/nix-nyaterm
```

安装到当前用户的 profile：

```bash
nix profile install github:nyakang/nix-nyaterm
```

软件包支持 `x86_64-linux` 和 `aarch64-linux`，包含 MCP sidecar、桌面入口、图标，以及 `nyaterm://`、`ssh://` 和 `telnet://` 协议处理器。软件包更新由 Nix 管理，因此通过 Nix 构建的 NyaTerm 会禁用应用内更新界面。

默认软件包不包含 GitHub OAuth Client ID；除非覆盖设置 `githubGistClientId`，否则无法使用 GitHub Gist Device Flow 授权。WebDAV 和 S3 同步不需要此设置。Termius 凭据导入依赖 Secret Service；如需使用该导入功能，请确保桌面环境提供了 Secret Service 实现。

## 在 NixOS 或 Home Manager 中使用

将本仓库添加为 Flake 输入，并导入 overlay：

```nix
inputs.nix-nyaterm.url = "github:nyakang/nix-nyaterm";

nixpkgs.overlays = [ inputs.nix-nyaterm.overlays.default ];
environment.systemPackages = [ pkgs.nyaterm ];
```

在 Home Manager 中，将 `environment.systemPackages` 替换为 `home.packages`：

```nix
inputs.nix-nyaterm.url = "github:nyakang/nix-nyaterm";

nixpkgs.overlays = [ inputs.nix-nyaterm.overlays.default ];
home.packages = [ pkgs.nyaterm ];
```

若要启用 GitHub Gist Device Flow，可在覆盖软件包时传入公开的 OAuth Client ID：

```nix
pkgs.nyaterm.override { githubGistClientId = "your_client_id"; }
```

## 开发环境

克隆本仓库并进入开发环境，即可获得 Rust、Node/pnpm、Tauri 和 Linux 原生依赖：

```bash
nix develop
```

随后可在该环境中使用 NyaTerm 源码仓库的克隆目录进行开发。

## 维护者说明

`nyaterm-src` 输入指向 `nyakang/nyaterm` 上游的 Release Tag。该引用必须指向包含 `src-tauri/crates/nyaterm-mcp` 的 Tag 或 Revision——该 crate 会被构建并作为内置的 MCP sidecar 一同安装，早于 MCP 支持的旧版本无法打包。

若要在不修改已提交 lock 文件的情况下，针对开发中的分支或本地检出进行构建，可覆盖该输入：

```bash
nix build .#nyaterm --override-input nyaterm-src github:nyakang/nyaterm/main --no-write-lock-file
nix build .#nyaterm --override-input nyaterm-src path:/path/to/nyaterm --no-write-lock-file
```

如需升级到更新的 NyaTerm 版本，请修改 `flake.nix` 中的 Tag，并在发布本软件包前运行 `nix flake update nyaterm-src` 刷新 `flake.lock`。

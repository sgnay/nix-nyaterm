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
nix profile add github:nyakang/nix-nyaterm
```

软件包支持 `x86_64-linux` 和 `aarch64-linux`，包含 MCP sidecar、桌面入口、图标，以及 `nyaterm://`、`ssh://` 和 `telnet://` 协议处理器。软件包更新由 Nix 管理。构建时注入了 `NYATERM_PACKAGE_MANAGER=nix`，但上游版本尚未读取该变量；应用内更新界面依然存在并可检查新版本，只是无法替换 `/nix/store` 中的只读二进制。

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

## 更新到新的 NyaTerm 版本

源码固定在某个 Release Tag 上以保证构建可复现，因此需要有人来推进这个引用。一条命令即可完成：

```bash
./scripts/update-upstream.sh          # 更新工作区，是否提交由你决定
./scripts/update-upstream.sh --commit # 更新并提交
```

它会将 Tag 推进到同一版本线上的最新 Release，刷新 `flake.lock`，然后逐个采纳 Nix 报告的 fixed-output hash，直到构建通过。若是其他原因导致构建失败，会原样报错，而不会用改 hash 的方式掩盖问题。Tag 只在同一版本线内推进；若出现新的 major/minor 版本线，脚本会给出警告而不会自行跳转。

`Update NyaTerm`（`.github/workflows/update.yml`）每周运行一次，在有版本更新时自动开 Pull Request，因此日常只需 review 后 merge。该工作流始终推送到固定分支 `chore/update-nyaterm`，并复用该分支上已有的 Pull Request 而非重复创建，因此未合并的更新只会被刷新，不会堆积多个 PR。由于使用默认 `GITHUB_TOKEN` 创建的 Pull Request 不会触发 `pull_request` 工作流，该工作流会在开 PR 前自行完成双架构构建。

通常只有 fixed-output hash 会变化：版本号取自 `package.json`，Cargo 锁文件直接读取源码，两者都无需手工修改。有两点需要注意：

- 该引用必须包含 `src-tauri/crates/nyaterm-mcp`，因为该 crate 会被构建并作为内置的 MCP sidecar 一同安装；`v1.2.6` 之前的版本无法打包。
- `v2.0.0-preview.*` 是纯 Rust 重写版，目录结构不同（没有 `src-tauri/`），需要手工重写 `nix/package.nix`，无法靠更新 hash 解决。

## 维护者说明

`nyaterm-src` 输入指向 `nyakang/nyaterm` 上游的 Release Tag。

若要在不修改已提交 lock 文件的情况下，针对开发中的分支或本地检出进行构建，可覆盖该输入：

```bash
nix build .#nyaterm --override-input nyaterm-src github:nyakang/nyaterm/main --no-write-lock-file
nix build .#nyaterm --override-input nyaterm-src path:/path/to/nyaterm --no-write-lock-file
```

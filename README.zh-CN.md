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

软件包支持 `x86_64-linux` 和 `aarch64-linux`，并随应用一起安装它启动的三个 helper 进程（`nyaterm-mcp`、`nyaterm-rdp-helper`、`nyaterm-vnc-helper`），以及桌面入口、图标和 `nyaterm://`、`ssh://`、`telnet://` 协议处理器。

NyaTerm 2.x 是纯 Rust 编写的 GPUI 应用：UI 资源与翻译目录在编译期嵌入二进制，因此软件包不再有独立的前端或 sidecar 输出。四个二进制都放在 `$out/bin` 下，因为应用会在自身可执行文件所在目录查找 helper。

构建时会把 `NYATERM_PACKAGE_MANAGER=nix` 固化进二进制，从而由 Nix 接管更新通道：应用内更新入口隐藏、托盘菜单移除更新项、关于对话框显示包管理器。

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

克隆本仓库并进入开发环境，即可获得 Rust 工具链以及 GPUI、GTK、Wayland/X11 和字体相关依赖：

```bash
nix develop
```

随后可在该环境中使用 NyaTerm 源码仓库的克隆目录进行开发。2.x 不再有 Node/pnpm 构建步骤。

## 更新到新的 NyaTerm 版本

源码固定以保证构建可复现，因此需要有人来推进这个引用。一条命令即可完成：

```bash
./scripts/update-upstream.sh          # 更新工作区，是否提交由你决定
./scripts/update-upstream.sh --commit # 更新并提交（受管理文件需无未提交修改）
```

它会将引用推进到本包所属版本线最新的稳定版 `vX.Y.Z`（本仓库对应 `v2`，即只更新到 `v2.x.y`），并跳过 preview、beta 等预发布标签；其他版本线上的引用会被直接拒绝，而不是被改写；随后刷新 `flake.lock`，逐个采纳 Nix 报告的 vendored 依赖 hash，直到构建通过。若因其他原因构建失败，会原样报错，不会用改 hash 的方式掩盖问题。最后它会构建 `.#checks.<system>.nyaterm`，断言包内文件是否齐全，缺失 helper 或图标的版本会直接失败，不会进入 PR。

除 Release Tag 外，只接受完整 commit SHA 这一种引用形式：当 `main` 上有尚未进入任何稳定版的改动时（例如下一次发版前的 `NYATERM_PACKAGE_MANAGER` 支持），就是这种情况。只有当上游的克隆仓库能证明某个稳定版包含该 commit 时，脚本才会把引用改到该版本；否则保留 commit 引用并说明原因——上游发布前会先 squash 再打 tag，tag 通常指向另一个 commit，仅凭 tag 选版可能选到早于该改动的版本。若有 tag 正好指向该 commit，则引用改写为该 tag。若上游已取不到该 commit、或是短 SHA、分支名、其他仓库，一律报错退出，绿色的运行结果不会再掩盖脚本已无法识别的引用。

引用判定的逻辑由 `scripts/tests/update-upstream-test.sh` 覆盖：它在临时仓库中用 stub 的 `git`、`nix` 运行真实脚本，因此改动这段逻辑无需联网或构建即可验证；该测试与 flake check 一起在 CI 中运行。

引用为 commit 时每周任务并非空转：独立的 `verify-pin` 任务会在两个架构上构建本次运行所属分支的引用，因此 revision 失效或依赖无法编译都会在同一周内让该次运行失败。引用未变动时这只是缓存命中。

有版本更新时，`Update NyaTerm` 会自动开 Pull Request，因此日常只需 review 后 merge。该工作流始终推送到固定分支 `chore/update-nyaterm`，并复用该分支上已有的 Pull Request 而非重复创建，因此未合并的更新只会被刷新，不会堆积多个 PR。由于使用默认 `GITHUB_TOKEN` 创建的 Pull Request 不会触发 `pull_request` 工作流，该工作流会在开 PR 前自行完成双架构构建。构建通过后才会提交或开 PR；若新版本的源码结构不兼容，需要先调整 package 表达式，不能只改 hash。

升级时会更新源码引用、`flake.lock` 和 vendored 依赖的 `cargoHash`。版本号取自上游 workspace `Cargo.toml`，依赖图直接来自上游 `Cargo.lock`，两者都不需要复制进本仓库。有三点需要注意：

- 该引用必须能构建整个默认 workspace：`crates/nyaterm-app` 产出 `nyaterm`，而 `nyaterm-mcp`、`nyaterm-rdp-helper`、`nyaterm-vnc-helper` 必须继续是 cargo 的 default members（`crates/nyaterm-activex-helper` 也在其中，但它的依赖仅限 Windows，Linux 构建不会产出该二进制）。不再构建这些 helper 的版本无法打包。
- `v2.0.0-preview.*` 预发布标签会被跳过。跨 major 版本线是有意为之：更新脚本不会跨越 major，v3 这类重写需要先手工修改引用并调整 `nix/package.nix`。
- `v2.0.0` 早于让二进制读取 `NYATERM_PACKAGE_MANAGER` 的改动，因此在下一个 `v2.x.y` 发布之前，引用是携带该改动的 `main` commit。`flake.lock` 保证该 commit 可复现；一旦每周任务能证明新版本包含该 commit，就会把它替换成对应 Release Tag，否则会报告需要手工更新引用。

## 维护者说明

`nyaterm-src` 固定引入 `NYATERM_PACKAGE_MANAGER` 的上游 commit，因为最新 Release Tag（`v2.0.0`）早于该改动。hash 与引用是一体的：每周更新脚本会用下一个能证明包含该 commit 的稳定 `v2.x.y` tag 替换它，并在同一次运行中采纳新的 `cargoHash`。

本地开发无需修改引用，构建时覆盖输入即可：

```bash
nix build .#nyaterm --override-input nyaterm-src github:nyakang/nyaterm/main --no-write-lock-file
nix build .#nyaterm --override-input nyaterm-src path:/path/to/nyaterm --no-write-lock-file
```

若覆盖后的源码 `Cargo.lock` 与固定引用一致，会复用已提交的 `cargoHash`；改动了依赖图的分支需要先刷新 hash。

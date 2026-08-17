# codex-rs 打包 & 测试指南

> 适用范围：`gienx` fork 下基于 `codex-rs` 工作区的构建、测试与打包。

## 1. 环境准备

- Rust 工具链：**1.95.0**（`codex-rs/rust-toolchain.toml` 锁定，会自动安装）
- 组件：`clippy`、`rustfmt`、`rust-src`
- 测试运行器：`cargo-nextest`
  ```bash
  cargo install --locked cargo-nextest
  ```
- 打包工具：`cargo-dist`
  ```bash
  cargo install --locked cargo-dist
  ```

## 2. 工作区说明

- **git 仓库根**：`codex/`
- **cargo 工作区根**：`codex/codex-rs/`（所有 cargo 命令需在此目录下执行）
- GitHub Actions workflow 在 `codex/.github/workflows/`，`cargo-dist` 配置在 `codex-rs/Cargo.toml` 的 `[workspace.metadata.dist]`

## 3. 构建

```bash
cd codex-rs

# debug 构建（CLI 二进制 codex）
cargo build -p codex-cli

# release 构建
cargo build -p codex-cli --release
```

产物路径：`codex-rs/target/debug/codex` 或 `codex-rs/target/release/codex`。

> 平台专属 crate（如 `codex-linux-sandbox`、`gienx-windows-sandbox-setup`）仅在对应平台编译，其他平台会自动跳过。

## 4. 测试

```bash
cd codex-rs

# 全工作区测试（nextest，推荐）
just test

# 或直接用 cargo
cargo nextest run --no-fail-fast

# 指定 crate
cargo nextest run -p codex-cli
```

静态检查：

```bash
cargo clippy --tests
cargo fmt --all -- --check
```

## 5. 打包（cargo-dist）

```bash
cd codex-rs

# 本地预览打包产物（不发布）
cargo dist plan

# 仅构建当前平台发行包
cargo dist build
```

产物输出到 `codex-rs/target/distrib/`，按平台生成 `.tar.xz` / `.zip` 等，含 checksum 文件。

## 6. CI 自动打包

推 tag 即触发 GitHub Actions 跨平台矩阵构建，产物挂到 GitHub Release：

```bash
git tag v0.142.4-beta.2
git push origin v0.142.4-beta.2
```

详见 `gienx/packaging/DESIGN.md` 与 `gienx/packaging/DOWNLOAD.md`。

## 7. 麒麟 V10 SP1 ARM64 包

cargo-dist 的 Linux 包是在较新 Ubuntu 上编的，glibc 会高于目标机的 **2.31**，不能拿去跑银河麒麟桌面 V10 SP1。麒麟包走独立流水线 `release-kylin-aarch64.yml`，在 **Debian 11 / glibc 2.31** 容器里编，并带上 sandbox 用的 `bwrap` 和 `rg`。

本机（必须是 aarch64 Linux 且 glibc ≤ 2.31）：

```bash
./gienx/scripts/build-kylin-aarch64-package.sh
# 产物目录（仓库根目录）：
#   dist/gienx-kylin-v10-aarch64-unknown-linux-gnu.tar.xz
#   dist/gienx-kylin-v10-aarch64-unknown-linux-gnu.tar.xz.sha256
```

脚本只 strip 临时组包目录里的副本，不修改 `codex-rs/target/` 中保留调试信息的 Cargo 构建产物。

在 Apple Silicon 上用 Docker 交叉到 arm64 + Debian 11。

直连 `docker.io` 在国内常会 `context deadline exceeded`。用仓库脚本（默认 DaoCloud 镜像 + 中科大 apt/rustup）：

```bash
./gienx/scripts/docker-build-kylin-aarch64.sh
```

该脚本保留仓库内的 `codex-rs/target/`，并用 Docker named volumes 缓存 Cargo registry/git 下载；重复构建不要删除这些缓存或执行 `cargo clean`。

某个镜像挂了就换：

```bash
BASE_IMAGE=docker.1ms.run/library/debian:11 ./gienx/scripts/docker-build-kylin-aarch64.sh
```

本机已有 Clash 等代理时，也可让 Docker Desktop 走 `http://127.0.0.1:7890`，再 `FROM debian:11` 直拉 Hub。Docker 中的 `/src/dist` 映射到启动脚本时的仓库根目录 `./dist`，不是 `codex-rs/target/`。

给 `~/Documents/superclient` 准备 Electron 输入目录时，解压**整个包**，不要只复制 `gienx`：

```bash
cd /path/to/gienx
mkdir -p ~/Documents/superclient/binaries/linux-arm64
tar -xJf dist/gienx-kylin-v10-aarch64-unknown-linux-gnu.tar.xz \
  -C ~/Documents/superclient/binaries/linux-arm64
```

解压后必须保留 `bin/gienx`、`codex-resources/bwrap`、`codex-path/rg`、`codex-package.json` 的相对结构。该包不提供 Electron 另外需要的 `gienx-proxy`、`node` 和 `node_repl`。

方案、Electron 目标路径与验收命令见 `gienx/docs/麒麟系统适配方案.md`。

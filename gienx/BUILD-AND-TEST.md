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

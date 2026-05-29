# Giencoder 开发指南

## 1. 环境准备

```bash
# 安装 Xcode 命令行工具
xcode-select --install

# 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# 进入项目，自动安装 Rust 1.93.0
cd codex-rs && rustup show

# 验证
rustc --version  # 应显示 1.93.0
```

## 2. 编译

```bash
cd codex-rs

cargo build            # 开发版（快）
cargo build --release  # 发布版（优化，部署用）
```

| 类型 | 产物路径 |
|---|---|
| 开发版 | `target/debug/codex` |
| 发布版 | `target/release/codex` |

## 3. 运行

```bash
cargo run --bin codex              # 启动 TUI 交互界面
cargo run --bin codex -- --help    # 传参数
./target/debug/codex               # 运行产物
```

## 4. 调试

### VS Code

安装插件：**rust-analyzer** + **CodeLLDB**

`.vscode/launch.json`：

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "lldb",
      "request": "launch",
      "name": "Debug codex",
      "cargo": {
        "args": ["build", "--bin=codex", "--package=codex-cli"]
      },
      "cwd": "${workspaceFolder}/codex-rs",
      "env": {
        "RUST_LOG": "debug",
        "RUST_BACKTRACE": "full"
      }
    }
  ]
}
```

行号左侧点红点打断点 → `F5` 启动调试。

### 命令行

```bash
RUST_LOG=debug RUST_BACKTRACE=full cargo run --bin codex
RUST_LOG=codex_core=trace cargo run --bin codex   # 只看某个模块
```

## 5. 日志

默认写到 `~/.codex/log/`：

| 文件 | 内容 |
|---|---|
| `codex-tui.log` | 主程序 |
| `codex-login.log` | 登录模块 |

```bash
tail -f ~/.codex/log/codex-tui.log
```

## 6. 常用命令

```bash
rustup toolchain list         # 已安装 toolchain
cargo clean                   # 清理编译产物
du -sh codex-rs/target/       # 产物占用空间
```

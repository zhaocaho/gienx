# Win7 上 codex-rs exec_command 卡住问题 — 修复方案

## 问题描述

Win7 (6.1.7601) 上，用户发送命令后 codex-rs 启动 `powershell.exe` 执行，但进程启动后不退出，导致整个 turn 卡住 42 秒以上直到用户手动中断。

## 根因分析

### 1. 卡住的直接原因

codex-rs 在 Windows 上 spawn PowerShell 时，命令行缺少 `-NonInteractive` 参数。在 restricted token 下，PowerShell 2.0 可能尝试交互式操作（如等待用户输入、加载 profile 中的交互脚本），导致进程 hang。

### 2. 配置 cmd 无效的根因

`codex-rs/shell-command/src/shell_detect.rs` 第 277 行硬编码：

```rust
if cfg!(windows) {
    get_shell(ShellType::PowerShell, /*path*/ None).unwrap_or_else(ultimate_fallback_shell)
}
```

Windows 上**强制优先使用 PowerShell**，忽略用户配置的 shell 类型。

## 修复方案

### 方案 A：修改 shell_detect.rs（推荐，治本）

**文件**: `codex-rs/shell-command/src/shell_detect.rs`

**改动位置**: `default_user_shell_from_path` 函数（约第 275 行）

**改动内容**: 在 Windows 分支前，优先检查用户配置的 shell path：

```rust
pub fn default_user_shell_from_path(user_shell_path: Option<PathBuf>) -> DetectedShell {
    // 优先使用用户配置的 shell（修复 Win7 强制 PowerShell 问题）
    if let Some(ref shell_path) = user_shell_path {
        if let Some(shell_type) = detect_shell_type(shell_path) {
            if let Some(shell) = get_shell(shell_type, Some(shell_path)) {
                return shell;
            }
        }
    }

    if cfg!(windows) {
        get_shell(ShellType::PowerShell, /*path*/ None).unwrap_or_else(ultimate_fallback_shell)
    } else {
        let user_default_shell = user_shell_path
            .and_then(|shell| detect_shell_type(&shell))
            .and_then(|shell_type| get_shell(shell_type, /*path*/ None));

        let shell_with_fallback = if cfg!(target_os = "macos") {
            user_default_shell
                .or_else(|| get_shell(ShellType::Zsh, /*path*/ None))
                .or_else(|| get_shell(ShellType::Bash, /*path*/ None))
        } else {
            user_default_shell
                .or_else(|| get_shell(ShellType::Bash, /*path*/ None))
                .or_else(|| get_shell(ShellType::Zsh, /*path*/ None))
        };

        shell_with_fallback.unwrap_or_else(ultimate_fallback_shell)
    }
}
```

### 方案 B：给 PowerShell 加 `-NonInteractive`（治标）

**文件**: `codex-rs/core/src/shell.rs`

**改动位置**: `derive_exec_args` 方法中 `ShellType::PowerShell` 分支（约第 32 行）

**改动内容**:

```rust
ShellType::PowerShell => {
    let mut args = vec![self.shell_path.to_string_lossy().to_string()];
    if !use_login_shell {
        args.push("-NoProfile".to_string());
        args.push("-NonInteractive".to_string());  // ← 新增这一行
    }
    args.push("-Command".to_string());
    args.push(command.to_string());
    args
}
```

### 方案 C：同时应用 A + B（最稳妥）

两个改动都做，既让配置生效，又防止 PowerShell 交互 hang。

## 编译步骤

在另一台电脑上（需要 Rust 工具链）：

```bash
# 1. 克隆仓库
git clone <repo_url>
cd gienx
git checkout win7-compatable

# 2. 应用修改（方案 A + B）
# 编辑 codex-rs/shell-command/src/shell_detect.rs
# 编辑 codex-rs/core/src/shell.rs

# 3. 编译
cd codex-rs
cargo build --release --target x86_64-pc-windows-msvc

# 4. 产物位置
# target/x86_64-pc-windows-msvc/release/gienx.exe
```

## 部署到 Win7

1. 将编译好的 `gienx.exe` 复制到 Win7 机器
2. 替换 `C:\Users\THao\AppData\Local\Programs\GienX\resources\binaries\win32\gienx.exe`
3. 重启 Electron 应用
4. 发送命令测试

## 验证方法

1. 在 Win7 上打开任务管理器
2. 在 Electron 中发送命令（如 `ls` 或 `dir`）
3. 观察任务管理器：
   - 应该看到 `cmd.exe` 进程（如果配置了 cmd）或带 `-NonInteractive` 参数的 `powershell.exe`
   - 进程应该在命令执行完后自动退出
   - 不应有进程卡住

## 临时 workaround（不改代码）

如果暂时无法编译，在 Win7 上执行：

```cmd
:: 重命名 powershell.exe，强制 codex-rs 回退到 cmd.exe
ren C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe powershell.exe.bak

:: 测试完后恢复
ren C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe.bak powershell.exe
```

## 相关文件清单

| 文件 | 作用 |
|------|------|
| `codex-rs/shell-command/src/shell_detect.rs` | Shell 类型检测和默认 shell 选择 |
| `codex-rs/core/src/shell.rs` | Shell 命令行参数构造 |
| `codex-rs/windows-sandbox-rs/src/unified_exec/backends/legacy.rs` | Win7 legacy 路径的进程 spawn |
| `codex-rs/windows-sandbox-rs/src/process.rs` | 管道读取和进程创建 |

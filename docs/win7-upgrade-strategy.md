# Codex 版本升级 — Win7 兼容性迁移方案

> 适用场景：从上游 codex 新版本合并代码到 `win7-compatable-v2` 分支时，如何保持 Win7 兼容性  
> 基线版本：codex v142（`gienx` 分支，commit `09939d50c`）  
> 最后更新：2026-08-18

---

## 一、方案概述

Win7 兼容方案分为 **三部分**：

| 部分 | 目标 | 实现方式 | 状态 |
|------|------|---------|------|
| **Part A: Cargo Registry Patch** | 修改第三方依赖（`windows`/`windows-core`/`windows-sys` crate + `windows_x86_64_msvc` build script） | 存储修改文件 + 构建前自动应用 patch | ✅ 已实现 |
| **Part B: 源码条件编译** | 修改项目源码以兼容 Win7 | 使用 `#[cfg(feature = "win7-compat")]` 隔离 Win7 专用代码 | ✅ 已实现 |
| **Part C: ConPTY 动态加载** | 避免静态导入 Win10+ API | 使用 `GetProcAddress` 运行时动态加载 | ✅ 已实现 |

**核心原则**：
- Part A 针对**第三方依赖**，版本固定，patch 文件可复用
- Part B 针对**项目源码**，使用条件编译隔离 Win7 逻辑，减少与上游的冲突
- Part C 针对 **Win10+ 专属 API**，必须动态加载，不能有任何静态导入
- **最小化改动**：只修改真正需要 Win7 兼容的文件

---

## 二、Part A: Cargo Registry Patch（已实现）

### 2.1 原理

修改 `~/.cargo/registry/src/` 下的第三方 crate 源码，使其兼容 Win7。通过 `apply-patches.ps1` 脚本自动化应用。

### 2.2 文件结构

```
codex-rs/patches/win7/
── apply-patches.ps1                          ← patch 应用脚本
├── windows-core-0.62.2/src/imp/
│   ├── bindings.rs                            ← combase.dll → ole32.dll
│   ├── factory_cache.rs                       ← CoIncrementMTAUsage → CoInitializeEx
│   ── com_bindings.rs                        ← RoGetActivationFactory 动态加载
├── windows-0.62.2/src/Windows/Win32/System/
│   ├── Com/mod.rs                             ← 同上
│   └── WinRT/mod.rs                           ← 同上
├── windows-sys-0.61.2/src/Windows/Win32/System/
│   └── Com/mod.rs                             ← 同上
└── windows_x86_64_msvc-0.48.5/
    └── build.rs                               ← 添加 x86_64-win7-windows-msvc 目标支持
```

### 2.3 关键 patch 说明

| Patch 文件 | 修改内容 | 原因 |
|-----------|---------|------|
| `windows-core-0.62.2/.../bindings.rs` | `combase.dll` → `ole32.dll` | Win7 没有 combase.dll |
| `windows-core-0.62.2/.../factory_cache.rs` | `CoIncrementMTAUsage` → `CoInitializeEx` | Win7 没有 CoIncrementMTAUsage |
| `windows-core-0.62.2/.../com_bindings.rs` | `RoGetActivationFactory` 动态加载 | Win7 没有此函数 |
| `windows_x86_64_msvc-0.48.5/build.rs` | 添加 `x86_64-win7-windows-msvc` 目标 | 否则链接器找不到 `windows.0.48.5.lib` |

### 2.4 构建流程

```powershell
# 1. 下载依赖
cargo fetch

# 2. 应用 patch
powershell -ExecutionPolicy Bypass -File patches\win7\apply-patches.ps1

# 3. 编译
$env:RUSTC_BOOTSTRAP = "1"
cargo build --bin gienx --features win7-compat --target x86_64-win7-windows-msvc -Z build-std
```

---

## 三、Part B: 源码条件编译（已实现）

### 3.1 原理

使用 Rust 的 `#[cfg(feature = "win7-compat")]` 属性隔离 Win7 专用代码。构建时通过 `--features win7-compat` 启用。

### 3.2 需要条件编译的文件清单

| 文件 | Win7 改动 | 条件编译方式 |
|------|-----------|-------------|
| `shell-command/src/command_safety/powershell_parser.rs` | Win7 检测跳过 AST 解析 | `#[cfg(feature = "win7-compat")]` 包裹检测逻辑 |
| `tui/src/tui.rs` | 终端功能降级为 warn（6处） | `#[cfg(feature = "win7-compat")]` 修改错误处理 |
| `windows-sandbox-rs/src/bin/setup_main/win/firewall.rs` | INetFwRule3 → INetFwRule2 | `#[cfg(feature = "win7-compat")]` 使用 INetFwRule2 |
| `core/src/tools/handlers/unified_exec/exec_command.rs` | ConPTY 不支持时 fallback 到 pipe | `#[cfg(feature = "win7-compat")]` 添加守卫 |

### 3.3 Feature Flag 配置

各 crate 的 `Cargo.toml` 中添加了 `win7-compat` feature：

```toml
# codex-rs/features/Cargo.toml
[features]
win7-compat = []

# codex-rs/shell-command/Cargo.toml
[features]
win7-compat = []

# codex-rs/tui/Cargo.toml
[features]
win7-compat = ["codex-shell-command/win7-compat"]

# codex-rs/windows-sandbox-rs/Cargo.toml
[features]
win7-compat = []

# codex-rs/core/Cargo.toml
[features]
win7-compat = []
code-mode-runtime = ["codex-code-mode/runtime"]

# codex-rs/cli/Cargo.toml
[features]
win7-compat = [
    "codex-features/win7-compat",
    "codex-tui/win7-compat",
    "codex-core/win7-compat",
    "codex_windows_sandbox/win7-compat",
]
code-mode-runtime = ["codex-core/code-mode-runtime"]
```

### 3.4 code-mode-runtime feature

`code-mode-runtime` feature 用于禁用 V8 编译（V8 在 Win7 上无法编译）。这是独立于 `win7-compat` 的 feature，但默认不启用。

涉及文件：
- `code-mode/Cargo.toml` — `runtime = ["dep:v8"]`，v8 设为 optional
- `code-mode/src/lib.rs` — `#[cfg(feature = "runtime")]` 包裹 runtime 模块
- `core/src/tools/mod.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹 code_mode 模块
- `core/src/tools/handlers/mod.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹 CodeMode 处理器
- `core/src/state/service.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹 code_mode_service 字段
- `core/src/session/session.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹 code_mode_service 初始化
- `core/src/session/handlers.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹 shutdown 逻辑
- `core/src/session/turn.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹 turn worker
- `core/src/session/tests.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹测试
- `core/src/tools/spec_plan.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹 code mode 相关函数
- `core/src/tools/registry_tests.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹测试
- `core/src/tools/tool_dispatch_trace_tests.rs` — `#[cfg(feature = "code-mode-runtime")]` 包裹测试

---

## 四、Part C: ConPTY 动态加载（已实现）

### 4.1 原理

`ResizePseudoConsole`、`CreatePseudoConsole`、`ClosePseudoConsole` 等 ConPTY API 只在 Windows 10 1809+ 上可用。静态导入会导致 Win7 上 PE 加载失败（"The procedure entry point could not be located"）。必须使用 `GetProcAddress` 运行时动态加载。

### 4.2 涉及文件

| 文件 | 改动 | 说明 |
|------|------|------|
| `utils/pty/src/win/psuedocon.rs` | `shared_library!` 宏动态加载 | 已使用动态加载，无需修改 |
| `utils/pty/src/pty.rs` | `conpty_supported()` 运行时检测 + pipe fallback | 已实现，无需修改 |
| `windows-sandbox-rs/src/conpty/mod.rs` | `try_resize_pseudoconsole` 动态加载 | 从 win7-compatable 分支复制 |
| `windows-sandbox-rs/src/unified_exec/backends/legacy.rs` | 移除静态导入，改用 `try_resize_pseudoconsole` | 必须修改 |
| `windows-sandbox-rs/src/bin/command_runner/win.rs` | 移除静态导入，改用 `try_resize_pseudoconsole` | 必须修改 |

### 4.3 关键注意事项

**绝对不能有任何静态导入 ConPTY API**，否则 Win7 上 PE 加载会直接失败。检查方法：

```powershell
# 检查 PE 导入表
dumpbin /imports target/x86_64-win7-windows-msvc/debug/gienx.exe | Select-String "ResizePseudoConsole"
# 应该无输出
```

---

## 五、完整升级流程

### 5.1 升级前准备

```bash
# 1. 记录当前 Win7 改动清单
git log --oneline 09939d50c^..HEAD > win7-changes-before.txt

# 2. 创建升级分支
git checkout win7-compatable-v2
git checkout -b win7-compatable-v3
```

### 5.2 合并上游代码

```bash
# 3. 合并上游新版本
git merge upstream/v150 --no-commit

# 4. 解决冲突
#    - 先解决非 Win7 文件的冲突
#    - 再处理 Win7 相关文件的冲突（见 5.3）
```

### 5.3 冲突处理策略

#### Part A: Cargo Registry Patch

```bash
# 5. 检查 Cargo.lock 中 windows crate 版本是否变化
git diff HEAD -- codex-rs/Cargo.lock | grep "windows"

# 6. 如果版本变化：
#    a. 运行 cargo fetch 下载新版本 crate
#    b. 对比新旧版本 crate 源码，确认是否仍需要 patch
#    c. 如果需要，手动修改新版本 crate 源码，生成新 patch 文件
#    d. 更新 apply-patches.ps1 中的文件映射
#    e. 在 Win7 实机上验证编译通过
```

#### Part B: 源码条件编译

```bash
# 7. 检查以下 4 个文件是否有冲突：
#    - shell-command/src/command_safety/powershell_parser.rs
#    - tui/src/tui.rs
#    - windows-sandbox-rs/src/bin/setup_main/win/firewall.rs
#    - core/src/tools/handlers/unified_exec/exec_command.rs

# 8. 冲突处理原则：
#    - 保留上游的新功能/重构
#    - 重新应用我们的 Win7 降级逻辑（用 #[cfg(feature = "win7-compat")] 包裹）
#    - 如果上游重构了模块结构，需要找到新的位置重新应用降级逻辑
```

#### Part C: ConPTY 动态加载

```bash
# 9. 检查以下文件是否有静态导入 ResizePseudoConsole：
#    - windows-sandbox-rs/src/unified_exec/backends/legacy.rs
#    - windows-sandbox-rs/src/bin/command_runner/win.rs
#    - utils/pty/src/win/psuedocon.rs（应使用 shared_library! 宏）

# 10. 如果上游新增了 ConPTY 相关调用：
#     - 必须使用 try_resize_pseudoconsole 动态加载
#     - 绝对不能使用 windows_sys::Win32::System::Console::ResizePseudoConsole 静态导入
```

### 5.4 升级后验证

```powershell
# 11. 应用 Cargo Registry Patch
powershell -ExecutionPolicy Bypass -File patches\win7\apply-patches.ps1

# 12. 编译 Win7 兼容版本
$env:RUSTC_BOOTSTRAP = "1"
cargo build --bin gienx --features win7-compat --target x86_64-win7-windows-msvc -Z build-std

# 13. PE 导入表检查（必须通过）
dumpbin /imports target/x86_64-win7-windows-msvc/debug/gienx.exe | Select-String "ResizePseudoConsole"
# 应该无输出

dumpbin /imports target/x86_64-win7-windows-msvc/debug/gienx.exe | Select-String "combase"
# 应该无输出

# 14. Win7 实机测试清单：
#    - [ ] gienx.exe 能正常启动（无 Entry Point Not Found 错误）
#    - [ ] shell_command 工具能正常执行 PowerShell 命令
#    - [ ] 命令执行不会卡住
#    - [ ] TUI 界面正常渲染（无 crash）
#    - [ ] 文件读写工具正常
#    - [ ] 退出时正常清理（无残留进程）
```

---

## 六、v2 分支的优势

### 6.1 最小化改动

| 对比项 | v1 分支 | v2 分支 |
|--------|---------|---------|
| 修改文件数 | ~40 | **~30**（含 code-mode-runtime） |
| 调试日志 | 8 个文件 | **0** |
| 功能改进 | 3 个文件 | **0** |
| 代码格式化 | 3 个文件 | **0** |
| 升级冲突风险 | 高 | **低** |

### 6.2 升级流程简化

v2 分支只修改 4 个源码文件（Part B），升级时只需要处理这 4 个文件的冲突：

1. `powershell_parser.rs` — Win7 跳过 AST 解析
2. `tui.rs` — 终端功能降级（6 处）
3. `firewall.rs` — INetFwRule2 降级
4. `exec_command.rs` — ConPTY 守卫

### 6.3 不包含的内容

v2 分支**不包含**以下内容（这些应该提交到主分支或移除）：

- 调试日志（`tracing::info!`）— 对所有平台都有益，但不是 Win7 专属
- 功能改进（`shell.rs`、`shell_detect.rs`）— 通用改进，应该单独提交
- 代码格式化（`permissions.rs`、`bwrap.rs`）— 格式调整，不是 Win7 兼容

---

## 七、风险评估矩阵

| 上游改动类型 | 对 Part A 的影响 | 对 Part B 的影响 | 对 Part C 的影响 | 处理难度 | 预估工时 |
|-------------|-----------------|-----------------|-----------------|----------|----------|
| `windows` crate 版本升级 | **高** — patch 失效 | 无 | 无 | 高 | 2-4 天 |
| `windows_x86_64_msvc` 版本升级 | **高** — build.rs patch 失效 | 无 | 无 | 中 | 1-2 天 |
| ConPTY 模块重构 | 无 | 无 | **高** — 需检查静态导入 | 中 | 1-2 天 |
| 防火墙模块重构 | 无 | **中** — 需确认新 API 是否兼容 | 无 | 中 | 1-2 天 |
| TUI 终端初始化重构 | 无 | **低** — 降级逻辑简单 | 无 | 低 | 0.5 天 |
| shell_command 执行链重构 | 无 | **中** — 需确认 PowerShell 解析跳过是否仍有效 | 无 | 低 | 0.5 天 |
| 构建系统重构 | **中** — 需重新集成 patch 流程 | **中** — 需重新集成 feature flag | 无 | 中 | 1 天 |
| 纯业务逻辑改动 | 无 | 无 | 无 | 无 | 0 |

---

## 八、快速参考

### 8.1 关键文件速查

| 文件 | 所属部分 | Win7 改动 | 升级时重点关注 |
|------|---------|-----------|---------------|
| `patches/win7/apply-patches.ps1` | Part A | patch 脚本 | crate 版本变化时必须更新 |
| `patches/win7/windows-core-0.62.2/...` | Part A | crate patch | crate 版本变化时必须更新 |
| `patches/win7/windows_x86_64_msvc-0.48.5/build.rs` | Part A | build.rs patch | crate 版本变化时必须更新 |
| `Cargo.toml`（各 crate） | Part B | feature flag | 构建系统重构时 |
| `shell-command/.../powershell_parser.rs` | Part B | Win7 跳过 AST | 上游修改命令安全解析时 |
| `tui/src/tui.rs` | Part B | 终端降级（6处） | 上游重构终端初始化时 |
| `windows-sandbox-rs/.../firewall.rs` | Part B | INetFwRule2 降级 | 上游重构防火墙时 |
| `core/.../exec_command.rs` | Part B | ConPTY 守卫 | 上游重构 exec_command 时 |
| `windows-sandbox-rs/.../conpty/mod.rs` | Part C | 动态加载 | 上游重构 conpty 时 |
| `windows-sandbox-rs/.../legacy.rs` | Part C | 移除静态导入 | 上游重构 legacy 时 |
| `windows-sandbox-rs/.../command_runner/win.rs` | Part C | 移除静态导入 | 上游重构 command_runner 时 |

### 8.2 编译命令速查

```powershell
# Part A: 应用 Cargo Registry Patch
powershell -ExecutionPolicy Bypass -File patches\win7\apply-patches.ps1

# Part B+C: 编译 Win7 兼容版本
$env:RUSTC_BOOTSTRAP = "1"
cargo build --bin gienx --features win7-compat --target x86_64-win7-windows-msvc -Z build-std

# PE 导入表检查
dumpbin /imports target/x86_64-win7-windows-msvc/debug/gienx.exe | Select-String "ResizePseudoConsole"
# 应该无输出
```

### 8.3 相关文档

| 文档 | 内容 |
|------|------|
| `docs/win7-compatibility.md` | Win7 兼容性问题全景分析 |
| `docs/win7-cargo-patch-solution.md` | Part A: Cargo Registry Patch 方案说明 |
| `docs/win7-exec-command-fix.md` | shell_command 卡住问题修复记录 |
| `docs/win7-installation-requirements.md` | Win7 环境安装要求 |
| `docs/win7-prerequisites.md` | Win7 前置条件 |
| `docs/win7-compatibility-impact.md` | Win7 兼容对功能的影响 |
---

## 一、环境准备（新电脑首次构建）

### 1.1 安装 Rust 工具链

```powershell
# 安装 Rust（从 https://rustup.rs 下载 rustup-init.exe）
# 安装时选择默认选项即可

# 安装 nightly 工具链（x86_64-win7-windows-msvc 不是标准目标，需要 nightly）
rustup toolchain install nightly

# 安装 rust-src 组件（-Z build-std 需要）
rustup component add rust-src --toolchain nightly

# 验证安装
rustup toolchain list
# 应该显示 stable 和 nightly
```

### 1.2 安装 Visual Studio Build Tools

需要 C++ 构建工具来链接 Windows 系统库：

1. 下载 [Visual Studio Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/)
2. 安装时勾选 **"使用 C++ 的桌面开发"** 工作负载
3. 确保安装以下组件：
   - MSVC v143 - VS 2022 C++ x64/x86 生成工具
   - Windows 10 SDK 或 Windows 11 SDK

### 1.3 验证环境

```powershell
# 检查 rustc 版本
rustc --version
# 应该显示 rustc 1.x.x (nightly)

# 检查 cargo 版本
cargo --version

# 检查链接器（dumpbin）
& "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\*\bin\HostX64\x64\dumpbin.exe" /?
# 应该显示帮助信息
```

---

## 二、方案概述

Win7 兼容方案分为 **三部分**：

| 部分 | 目标 | 实现方式 | 状态 |
|------|------|---------|------|
| **Part A: Cargo Registry Patch** | 修改第三方依赖（`windows`/`windows-core`/`windows-sys` crate + `windows_x86_64_msvc` build script） | 存储修改文件 + 构建前自动应用 patch | ✅ 已实现 |
| **Part B: 源码条件编译** | 修改项目源码以兼容 Win7 | 使用 `#[cfg(feature = "win7-compat")]` 隔离 Win7 专用代码 | ✅ 已实现 |
| **Part C: ConPTY 动态加载** | 避免静态导入 Win10+ API | 使用 `GetProcAddress` 运行时动态加载 | ✅ 已实现 |

**核心原则**：
- Part A 针对**第三方依赖**，版本固定，patch 文件可复用
- Part B 针对**项目源码**，使用条件编译隔离 Win7 逻辑，减少与上游的冲突
- Part C 针对 **Win10+ 专属 API**，必须动态加载，不能有任何静态导入
- **最小化改动**：只修改真正需要 Win7 兼容的文件

---

## 三、Part A: Cargo Registry Patch（已实现）
---

## 六、完整构建流程（新电脑首次构建）

### 6.1 环境准备

参见第一章"环境准备"。

### 6.2 克隆代码

```bash
git clone <repository-url>
cd gienx
git checkout win7-compatable-v2
```

### 6.3 下载依赖并应用 Patch

```powershell
cd codex-rs

# 下载依赖
cargo fetch

# 应用 Win7 兼容 Patch（必须！）
powershell -ExecutionPolicy Bypass -File patches\win7\apply-patches.ps1
```

**这一步不能跳过**，否则：
- `combase.dll` 在 Win7 上不存在 → 链接失败
- `CoIncrementMTAUsage` 在 Win7 上不存在 → 链接失败
- `windows.0.48.5.lib` 找不到 → 链接失败（build.rs 不支持 `x86_64-win7-windows-msvc` 目标）

### 6.4 编译

```powershell
$env:RUSTC_BOOTSTRAP = "1"
cargo +nightly build --bin gienx --features win7-compat --target x86_64-win7-windows-msvc -Z build-std
```

### 6.5 验证

```powershell
# 检查 PE 导入表（必须通过）
dumpbin /imports target/x86_64-win7-windows-msvc/debug/gienx.exe | Select-String "ResizePseudoConsole"
# 应该无输出

dumpbin /imports target/x86_64-win7-windows-msvc/debug/gienx.exe | Select-String "combase"
# 应该无输出
```

### 6.6 为什么不能直接 `cargo build`？

| 问题 | 原因 |
|------|------|
| `x86_64-win7-windows-msvc` 不是标准目标 | 需要 `nightly` + `-Z build-std` |
| `windows-core`/`windows`/`windows-sys` crate 静态链接 Win10+ API | 需要 patch 修改为动态加载或兼容 API |
| `windows_x86_64_msvc-0.48.5` 的 build.rs 不支持 Win7 目标 | 需要 patch 添加目标支持 |
| `ResizePseudoConsole` 等 ConPTY API 静态导入 | 代码中已改为动态加载，但 patch 仍需要 |

---

## 七、Part B: 源码条件编译（已实现）
---

## 八、Part C: ConPTY 动态加载（已实现）
---

## 九、完整升级流程（从上游合并新版本）
---

## 十、v2 分支的优势
---

## 十一、风险评估矩阵
---

## 十二、快速参考

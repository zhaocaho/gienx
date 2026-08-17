# GienX Windows 7 兼容性影响分析

> 文档维护: win7-compatable 分支  
> 最后更新: 2026-08-13  
> 适用产品: GienX Desktop (Windows 7 SP1 x64)

---

## 一、概述

本文档说明 GienX 适配 Windows 7 后，哪些功能受到影响、降级原因及实际影响程度。分析基于 `D:\gienx\superclient` 项目的实际调用方式。

---

## 二、受影响功能清单

| # | 受影响功能 | 产品使用场景 | 降级影响 | 原因 |
|---|-----------|------------|---------|------|
| 1 | **ConPTY 伪终端** | gienx.exe 执行 agent shell 命令（`exec_command` 工具），sandbox 内运行用户命令 | 回退到 pipe 模式（普通管道）。命令执行和输出捕获仍正常工作，但丢失终端控制能力（如交互式程序、实时光标控制）。对 agent 批量执行命令的场景基本无感 | ConPTY 需要 Win10 build 17763+，Win7 不支持。`conpty_supported()` 检测 build 号后回退 pipe |
| 2 | **Windows 防火墙规则 (INetFwRule3)** | sandbox 离线模式：`gienx-windows-sandbox-setup.exe` 创建出站规则，阻止沙箱进程访问外网，仅放行 proxy 端口 | Win7 的 `INetFwRule3` 不支持 `LocalUser` 属性（按用户 SID 过滤规则）。回退到 WFP 过滤器或跳过用户级规则，sandbox 网络隔离能力可能不完整 | Win7 防火墙 COM 接口版本低于 Win10，缺少 `INetFwRule3` 的部分属性 |
| 3 | **WinRT / RoGetActivationFactory** | 部分 windows crate 的 WinRT 调用路径（如 `factory_cache`） | 返回 `REGDB_E_CLASSNOTREG`，走 `DllGetActivationFactory` fallback。实际影响有限，因为 superclient 通过 JSON-RPC 与 gienx.exe 通信，不直接触发 WinRT | Win7 无 WinRT 支持 |
| 4 | **code-mode-runtime (V8)** | agent 执行 JavaScript 代码片段（如果启用了该工具） | 如果 Win7 构建时禁用了 `code-mode-runtime` feature，则 JavaScript 执行工具不可用 | V8 引擎编译复杂，通过 feature gate 控制 |

---

## 三、不受影响的功能

以下功能在 Win7 上正常工作，不受兼容性降级影响：

### 3.1 核心功能

- **AI 对话 / 代码编辑 / 文件操作** — superclient 通过 `app-server` 子命令以 JSON-RPC over stdin/stdout 与 gienx.exe 通信，不涉及 TUI
- **gienx-proxy 代理转发** — 纯 HTTP 代理，无终端/系统 API 依赖
- **浏览器控制（CDP）** — 走 Electron `webContents.debugger`，不经过 gienx.exe
- **搜索（rg）、Git 操作** — 独立二进制，不涉及 Win7 兼容问题

### 3.2 TUI 相关降级（不影响产品）

以下 TUI 功能在 Win7 上降级，但**产品不使用 gienx.exe 的 TUI 模式**，因此无影响：

- **Bracketed Paste** — 产品不使用 gienx.exe 的交互式输入
- **Scroll Region** — 产品不使用 gienx.exe 的终端滚动
- **ANSI 渲染 / Virtual Terminal Processing** — 产品有自己的 Electron 终端（node-pty），不依赖 gienx.exe 的渲染

---

## 四、技术细节

### 4.1 ConPTY 降级机制

```rust
// codex-rs/utils/pty/src/win/psuedocon.rs
pub fn conpty_supported() -> bool {
    windows_build_number().is_some_and(|build| build >= MIN_CONPTY_BUILD)
}

const MIN_CONPTY_BUILD: u32 = 17_763; // Win10 1809
```

Win7 的 build 号为 7601，远低于 17763，因此 `conpty_supported()` 返回 `false`，所有 PTY 操作回退到 pipe 模式。

### 4.2 防火墙降级机制

```rust
// codex-rs/windows-sandbox-rs/src/bin/setup_main/win/firewall.rs
// INetFwRule3 的 LocalUser 属性在 Win7 上不可用
// 代码中有 graceful degradation，但具体行为取决于 Win7 的防火墙 API 版本
```

### 4.3 WinRT 降级机制

```rust
// cargo registry 中的 windows-core/windows-sys crate
// RoGetActivationFactory 被替换为返回 REGDB_E_CLASSNOTREG
// 走 DllGetActivationFactory fallback 路径
```

---

## 五、验证建议

### 5.1 功能验证清单

在 Win7 上部署后，建议验证以下功能：

1. **AI 对话** — 发送消息、接收响应、流式输出
2. **代码编辑** — 创建/修改/删除文件
3. **命令执行** — agent 执行 shell 命令（`exec_command` 工具）
4. **文件搜索** — 使用 rg 搜索代码
5. **Git 操作** — 提交、推送、拉取
6. **浏览器控制** — CDP 调试、网页截图
7. **sandbox 网络隔离** — 离线模式下验证网络规则是否生效

### 5.2 预期行为

- 命令执行可能缺少交互式终端特性（如实时光标控制），但输出捕获正常
- sandbox 网络隔离在 Win7 上可能不如 Win10+ 精确（按用户过滤可能失效）
- 其他功能应与 Win10+ 表现一致

---

## 六、参考链接

- Rust Win7 target 文档: https://doc.rust-lang.org/rustc/platform-support/win7-windows-msvc.html
- ConPTY 文档: https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session
- Windows 防火墙 COM API: https://learn.microsoft.com/en-us/windows/win32/api/icftypes/

---

## 七、变更日志

| 日期 | 变更 |
|------|------|
| 2026-08-13 | 初始版本，分析 Win7 兼容性影响 |

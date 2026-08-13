# codex-rs Windows 7 兼容性分析

> 分支: `win7-compatable` | 日期: 2026-08-11

## 一、整体结论

**当前 codex-rs 的打包产物无法直接支持 Windows 7。** 存在 2 个硬阻断问题（防火墙 COM 接口不兼容 + ConPTY API 静态链接导致 PE 加载失败）+ 1 个功能降级问题（ConPTY 不可用，且多个调用路径未做运行时守卫）+ 若干需要验证的边界条件。

## 二、产物清单

codex-rs 在 Windows 上打包以下二进制：

| 产物 | 用途 | 是否受 Win7 兼容性影响 |
|------|------|----------------------|
| `gienx.exe` | 主 CLI/TUI 程序 | 间接受影响（ConPTY 不可用） |
| `gienx-windows-sandbox-setup.exe` | 沙箱一次性安装器（需管理员权限） | **🔴 硬阻断**（防火墙 COM 接口） |
| `gienx-command-runner.exe` | 沙箱内命令执行器 | **🔴 硬阻断**（`ResizePseudoConsole` 静态导入 + ConPTY 不可用） |

## 三、硬阻断问题

### 🔴 问题 1：`INetFwRule3` 防火墙 COM 接口不兼容（Windows 8+ 专有）

**文件**: `codex-rs/windows-sandbox-rs/src/bin/setup_main/win/firewall.rs`

**问题描述**：防火墙模块大量使用了 `INetFwRule3` COM 接口，这个接口仅在 Windows 8+ 上可用。Windows 7 最高只支持到 `INetFwRule2`。

**关键代码位置**:

```rust
// firewall.rs:7 - 导入 INetFwRule3
use windows::Win32::NetworkManagement::WindowsFirewall::INetFwRule3;

// firewall.rs:278 - 强制转换为 INetFwRule3
let rule: INetFwRule3 = match unsafe { rules.Item(&name) } {
    Ok(existing) => existing.cast().map_err(|err| {
        anyhow::Error::new(SetupFailure::new(
            SetupErrorCode::HelperFirewallRuleCreateOrAddFailed,
            format!("cast existing firewall rule to INetFwRule3 failed: {err:?}"),
        ))
    })?,
    ...
};

// firewall.rs:286 - 创建 INetFwRule3 实例
let new_rule: INetFwRule3 =
    unsafe { CoCreateInstance(&NetFwRule, None, CLSCTX_INPROC_SERVER) }.map_err(...)?;

// firewall.rs:329 - 所有配置函数都使用 INetFwRule3
fn configure_rule(rule: &INetFwRule3, spec: &BlockRuleSpec<'_>) -> Result<()> { ... }
fn configure_rule_network_scope(rule: &INetFwRule3, spec: &BlockRuleSpec<'_>) -> Result<()> { ... }
```

**Windows 防火墙 COM 接口版本历史**:

| 接口 | 引入版本 | Win7 可用 |
|------|---------|----------|
| `INetFwRule` | Windows Vista | ✅ |
| `INetFwRule2` | **Windows 7** | ✅ |
| `INetFwRule3` | **Windows 8** | 🔴 |

**影响**：
- 所有防火墙规则操作（`gienx-windows-sandbox-setup.exe` 的核心功能）在 Win7 上会失败
- `CoCreateInstance` 创建 `NetFwRule` 再 cast 到 `INetFwRule3` 会在 COM 层返回错误
- Sandbox 网络隔离功能完全无法初始化

**改造方案**：

方案 A（运行时动态选择接口版本）：

```rust
// 尝试 INetFwRule3，失败则降级到 INetFwRule2
fn get_firewall_rule(rules: &INetFwRules, name: &BSTR) -> Result<FirewallRule> {
    match unsafe { rules.Item(name) } {
        Ok(existing) => {
            // 优先尝试 INetFwRule3
            if let Ok(rule3) = existing.cast::<INetFwRule3>() {
                return Ok(FirewallRule::V3(rule3));
            }
            // 降级到 INetFwRule2 (Win7 兼容)
            if let Ok(rule2) = existing.cast::<INetFwRule2>() {
                return Ok(FirewallRule::V2(rule2));
            }
            Err(...)
        }
        Err(_) => { /* 创建新规则 */ }
    }
}
```

方案 B（推荐优先考虑）：直接全部使用 `INetFwRule2`

- `INetFwRule2` 已经包含 `SetLocalUserAuthorizedList` / `LocalUserAuthorizedList` 方法（这正是 Windows 7 引入的）
- 当前代码未使用 `INetFwRule3` 独有的方法（如 `SetLocalAppPackageId` 等 Win8+ 特性）
- 经源码核实，所有使用的方法均存在于 `INetFwRule2`：`SetName`、`SetDescription`、`SetDirection`、`SetAction`、`SetEnabled`、`SetProfiles`、`SetProtocol`、`SetRemoteAddresses`、`SetRemotePorts`、`SetLocalUserAuthorizedList`、`LocalUserAuthorizedList`
- 直接替换为 `INetFwRule2` 即可，功能完整性不受影响
- API 签名完全兼容，改动量最小

**推荐采用方案 B**，改动范围仅限 `firewall.rs` 一个文件。`INetFwPolicy2`（Vista 引入）无需修改，Win7 兼容。

---

### 🔴 问题 2：`ResizePseudoConsole` 静态链接导致 `gienx-command-runner.exe` PE 加载失败

**文件**:
- `codex-rs/windows-sandbox-rs/src/bin/command_runner/win.rs:63`
- `codex-rs/windows-sandbox-rs/src/unified_exec/backends/legacy.rs:39`

**问题描述**：这两处通过 `windows-sys` **静态导入**了 `ResizePseudoConsole`（Win10 1809+ 专有函数），不同于 `psuedocon.rs` 中通过 `shared_library!` 动态加载的做法。静态导入意味着该函数的符号引用会写入 PE 文件的导入表（`.idata` section），Windows PE 加载器在程序启动时（执行任何代码之前）就会尝试在 `kernel32.dll` 中解析该符号。

Win7 的 `kernel32.dll` 不导出 `ResizePseudoConsole`，因此加载器直接报错：

> "The procedure entry point ResizePseudoConsole could not be located in the dynamic link library KERNEL32.dll"

这导致 `gienx-command-runner.exe` **在 Win7 上根本无法启动**，比问题 3（ConPTY 运行时创建失败）更为严重。

**关键代码位置**：

```rust
// command_runner/win.rs:63 - 静态导入（windows-sys 的 #[link(name = "kernel32")]）
use windows_sys::Win32::System::Console::ResizePseudoConsole;

// command_runner/win.rs:465 - 实际调用点（在 spawn_input_loop 的 Message::Resize 分支）
let _ = ResizePseudoConsole(
    *hpc,
    COORD {
        X: cols as i16,
        Y: rows as i16,
    },
);

// legacy.rs:39 - 同样的问题
use windows_sys::Win32::System::Console::ResizePseudoConsole;

// legacy.rs:253 - 实际调用点
ResizePseudoConsole(
    hpc,
    COORD {
        X: size.cols as i16,
        Y: size.rows as i16,
    },
)
```

**对比：psuedocon.rs 中的正确做法**：

```rust
// psuedocon.rs:69-79 - 通过 shared_library! 动态加载，运行时解析符号
shared_library!(ConPtyFuncs,
    pub fn CreatePseudoConsole(size: COORD, hInput: HANDLE, hOutput: HANDLE,
        flags: DWORD, hpc: *mut HPCON) -> HRESULT,
    pub fn ResizePseudoConsole(hpc: HPCON, size: COORD) -> HRESULT,
    pub fn ClosePseudoConsole(hpc: HPCON),
);
```

**为什么 psuedocon.rs 的做法是正确的**：
- `shared_library!` 编译输出的是运行时 `GetProcAddress` 调用，不会生成 PE 导入表项
- 即使 Win7 的 `kernel32.dll` 不导出这些函数，PE 加载器也不会报错
- 只有在代码实际调用这些函数时才会失败，而调用前可以检查 `conpty_supported()`

**为什么 command_runner/win.rs 和 legacy.rs 的做法会出问题**：
- `windows-sys` 使用 `#[link(name = "kernel32")] extern "system"` 生成标准 FFI 绑定
- Rust 编译器/Linker 会将所有被引用的外部函数写入 PE 导入表
- 即使 `ResizePseudoConsole` 只在 `if req.tty` 分支中被调用，但它仍然出现在编译产物中（非 LTO 编译下 link 器无论运行时是否可达都会保留引用）
- PE 加载器在 `main()` 执行前就尝试解析所有导入符号，一旦找不到就终止进程

**影响**：
- `gienx-command-runner.exe` 在 Win7 上双击运行即报错弹出，无任何日志输出
- `gienx.exe`（主 CLI）如果链接了 `legacy.rs`（通过 `codex-windows-sandbox` crate），也可能受同样问题影响，具体取决于 LTO 优化和 dead code elimination 结果

**改造方案**：

两处都改为动态加载 `ResizePseudoConsole`：

```rust
// 方案：在 command_runner/win.rs 和 legacy.rs 中
// 移除静态导入，改为 GetProcAddress 动态获取函数指针

use std::sync::OnceLock;

type FnResizePseudoConsole = unsafe extern "system" fn(
    HPCON,     // hPC
    COORD,     // size
) -> HRESULT;

static RESIZE_PSEUDO_CONSOLE: OnceLock<Option<FnResizePseudoConsole>> = OnceLock::new();

fn get_resize_pseudoconsole() -> Option<FnResizePseudoConsole> {
    *RESIZE_PSEUDO_CONSOLE.get_or_init(|| {
        let kernel32 = unsafe {
            windows_sys::Win32::System::LibraryLoader::GetModuleHandleW(
                std::ffi::OsStr::new("kernel32.dll").encode_wide()
                    .chain(std::iter::once(0))
                    .collect::<Vec<u16>>()
                    .as_ptr(),
            )
        };
        if kernel32 == 0 {
            return None;
        }
        let proc = unsafe {
            windows_sys::Win32::System::LibraryLoader::GetProcAddress(
                kernel32,
                std::ffi::CStr::from_bytes_with_name("ResizePseudoConsole\0")
                    .unwrap()
                    .as_ptr(),
            )
        };
        if proc.is_none() {
            return None;
        }
        Some(unsafe { std::mem::transmute(proc.unwrap()) })
    })
}
```

调用点改为先检查函数指针是否可用：

```rust
Message::Resize { payload: ResizePayload { rows, cols } } => {
    if let Some(resize_fn) = get_resize_pseudoconsole() {
        if let Ok(guard) = hpc_handle.lock()
            && let Some(hpc) = guard.as_ref()
        {
            unsafe {
                let _ = resize_fn(*hpc, COORD {
                    X: cols as i16,
                    Y: rows as i16,
                });
            }
        }
    }
}
```

---

## 四、功能降级问题

### 🟡 问题 3：ConPTY（Pseudo Console）不可用

**文件**:
- `codex-rs/utils/pty/src/win/psuedocon.rs`
- `codex-rs/utils/pty/src/win/conpty.rs`
- `codex-rs/windows-sandbox-rs/src/conpty/mod.rs`
- `codex-rs/windows-sandbox-rs/src/bin/command_runner/win.rs`
- `codex-rs/windows-sandbox-rs/src/unified_exec/backends/legacy.rs`

**问题描述**：`CreatePseudoConsole` / `ResizePseudoConsole` / `ClosePseudoConsole` 需要 Windows 10 1809 (build 17763)+。Windows 7 上没有这些 API。

**好消息**：`psuedocon.rs` 中的 ConPTY 核心函数已经做了**运行时检测**和**动态加载**：

```rust
// psuedocon.rs:67 - ConPTY 最低版本检查
const MIN_CONPTY_BUILD: u32 = 17_763;

// psuedocon.rs:87-97 - 通过 shared_library! 动态加载 kernel32.dll
fn load_conpty() -> ConPtyFuncs {
    let kernel = ConPtyFuncs::open(Path::new("kernel32.dll")).expect(
        "this system does not support conpty.  Windows 10 October 2018 or newer is required",
    );
    ...
}

// psuedocon.rs:103-105 - 运行时检测
pub fn conpty_supported() -> bool {
    windows_build_number().is_some_and(|build| build >= MIN_CONPTY_BUILD)
}
```

**坏消息**：存在三个严重缺陷：

#### 3a. `load_conpty()` 在 lazy_static 初始化时 panic（而非返回错误）

```rust
// psuedocon.rs:99-101
lazy_static! {
    static ref CONPTY: ConPtyFuncs = load_conpty();
}
```

`CONPTY` 在所有 `PsuedoCon` 操作（`new`/`resize`/`drop`）中都会被访问。一旦被访问，`lazy_static!` 就会初始化并调用 `load_conpty()`，其中的 `.expect()` 直接 panic 而非返回 `Result`。

以下代码路径会触发该 panic（**即使调用方设置了 `tty=false`，只要这些函数被链接进二进制，就有可能因其他路径的 lazy_static 触发而崩**）：

- `ConPtySystem::openpty()` → `create_conpty_handles()` → `PsuedoCon::new()` → 访问 `CONPTY`
- `spawn_conpty_process_as_user()` → `RawConPty::new()` → 同上
- `create_conpty()` → `RawConPty::new()` → 同上

#### 3b. `exec_command` handler 缺少 `conpty_supported()` 守卫

`tool_config.rs:108` 仅守卫了 **shell tool** 的 UnifiedExec 路径：

```rust
// tool_config.rs:108 - 只保护了 shell tool
if codex_utils_pty::conpty_supported() {
    ConfigShellToolType::UnifiedExec
} else {
    ConfigShellToolType::ShellCommand   // 降级到传统 pipe 模式
}
```

但 `exec_command` handler（`exec_command.rs:240`）中 `tty` 直接来自 LLM 的工具调用参数，**没有任何 runtime 守卫**：

```rust
// exec_command.rs:34 - 默认值为 false，但 LLM 可显式传入 true
#[serde(default = "default_tty")]
tty: bool,

fn default_tty() -> bool {
    false   // 默认关，但 LLM 可以传 true
}
```

如果 LLM 显式传入 `tty: true`，会一路传递到 `spawn_conpty_process_as_user()` → `CONPTY` lazy_static 初始化 → panic。

#### 3c. `legacy.rs` 同样直接调用 `spawn_conpty_process_as_user()` 无守卫

```rust
// legacy.rs:72-80 - tty=true 时直接调 ConPTY，无 conpty_supported() 检查
let (pi, mut conpty) = spawn_conpty_process_as_user(
    h_token, command, cwd, env_map, use_private_desktop, logs_base_dir,
)?;
```

**影响**：
- TTY 模式（交互式终端，`tty=true`）无法使用
- 必须回退到 pipe 模式（`tty=false`）
- `gienx-command-runner.exe` 的 `spawn_conpty_process_as_user()` 调用路径需要确认 fallback 正确
- 如果 `conpty_supported()` 检查不到位，会导致 panic 而非优雅降级

**改造要求**：
1. 确认所有 ConPTY 调用路径在 `conpty_supported() == false` 时正确 fallback 到 pipe 模式
2. `load_conpty()` 中的 `expect()` 在 Win7 上调用会 panic，需要改为 Result 返回并向上传播（同时需要重新设计 lazy_static 的初始化策略，使其在模块首次访问时不会崩溃）
3. 建议在启动时主动检测并提示用户"当前系统不支持交互式终端模式（TTY）"
4. 排查 `pty.rs` 中 `platform_native_pty_system()` 在 Win7 上的行为

### 🟢 ConPTY 各调用路径分析

| 调用路径 | 文件 | Win7 行为 | 风险 | 是否有 `conpty_supported()` 守卫 |
|---------|------|----------|------|------------------------------|
| `spawn_pty_process()` → `conpty_supported()` | `pty.rs` | 正常 fallback | ✅ 低 | ✅ 是 |
| `tool_config.rs` shell tool 路径 | `tool_config.rs:108` | fallback 到 ShellCommand | ✅ 低 | ✅ 是 |
| `exec_command` handler → `manager.exec_command()` | `exec_command.rs:340` | **panic** | 🔴 高 | ❌ 无 |
| `create_conpty()` (公共 API) | `conpty/mod.rs:77` | **panic** | 🔴 高 | ❌ 无 |
| `spawn_conpty_process_as_user()` (公共 API) | `conpty/mod.rs:93` | **panic** | 🔴 高 | ❌ 无 |
| `command_runner/win.rs` TTY 分支 | `command_runner/win.rs:286` | **PE 加载失败 + panic** | 🔴 高 | ❌ 无（且含静态导入问题 2） |
| `legacy.rs` TTY 分支 | `legacy.rs:72` | **panic** | 🔴 高 | ❌ 无（且含静态导入问题 2） |
| `elevated_impl.rs` TTY 分支 | `elevated_impl.rs:193` | 硬编码 `tty: false` | ✅ 低 | N/A（已硬编码 false） |
| `wrapper.rs` TTY 分支 | `wrapper.rs:185` | 硬编码 `tty: false` | ✅ 低 | N/A（已硬编码 false） |
| `debug_sandbox.rs` TTY 分支 | `debug_sandbox.rs:394` | 硬编码 `tty: false` | ✅ 低 | N/A（已硬编码 false） |

---

## 五、需要验证的边界条件

### 🟢 问题 4：WFP (Windows Filtering Platform) 兼容性

**文件**: `codex-rs/windows-sandbox-rs/src/wfp.rs`、`filter_specs.rs`

WFP 在 Windows 7 上可用（版本 1.0）。当前使用的 API 列表：

| WFP API | 引入版本 | Win7 可用 |
|---------|---------|----------|
| `FwpmEngineOpen0` | Vista | ✅ |
| `FwpmTransactionBegin0` | Vista | ✅ |
| `FwpmTransactionCommit0` | Vista | ✅ |
| `FwpmTransactionAbort0` | Vista | ✅ |
| `FwpmProviderAdd0` | Vista | ✅ |
| `FwpmSubLayerAdd0` | Vista | ✅ |
| `FwpmFilterAdd0` | Vista | ✅ |
| `FwpmFilterDeleteByKey0` | Vista | ✅ |
| `FWPM_CONDITION_ALE_USER_ID` | Vista | ✅ |
| `FWPM_CONDITION_IP_PROTOCOL` | Vista | ✅ |
| `FWPM_CONDITION_IP_REMOTE_PORT` | Vista | ✅ |

当前未使用 Win8+ 专有条件（如 `FWPM_CONDITION_ALE_APP_ID`），**理论兼容**，但需要在 Win7 上实际验证。

### 🟢 问题 5：Rust 工具链和编译目标

- Rust 1.95.0（`codex-rs/rust-toolchain.toml`）的 `x86_64-pc-windows-msvc` target 默认 `_WIN32_WINNT=0x0601`（Win7），编译器层面兼容
- `codex-rs/.cargo/config.toml` 配置了 `/STACK:8388608` + `crt-static`，静态链接 CRT，消除了 VC Runtime 版本依赖
- `windows` crate 0.58 / `windows-sys` 0.52 生成的绑定可能包含 Win8+ 符号，关键是要确保这些符号不会被**静态链接**进 PE 导入表（见问题 2）

### 🟢 问题 6：其他 Windows API 兼容性总览

| API | 引入版本 | 模块 | 状态 |
|-----|---------|------|------|
| `CreateProcessAsUserW` | Win2000 | process, conpty | ✅ |
| `CreateProcessWithLogonW` | Win2000 | runner_client | ✅ |
| `CreateProcessW` | Win2000 | psuedocon | ✅ |
| `CreateRestrictedToken` | Win2000 | token | ✅ |
| `GetTokenInformation` | Win2000 | token | ✅ |
| `SetTokenInformation` | Win2000 | token | ✅ |
| `AdjustTokenPrivileges` | Win2000 | token | ✅ |
| `InitializeProcThreadAttributeList` | Vista | proc_thread_attr | ✅ |
| `UpdateProcThreadAttribute` | Vista | proc_thread_attr | ✅ |
| `DeleteProcThreadAttributeList` | Vista | proc_thread_attr | ✅ |
| `ConvertStringSidToSidW` | Win2000 | winutil, setup | ✅ |
| `ConvertSidToStringSidW` | Win2000 | winutil | ✅ |
| `LookupAccountNameW` | Win2000 | winutil | ✅ |
| `CheckTokenMembership` | Win2000 | setup | ✅ |
| `AllocateAndInitializeSid` | Win2000 | setup | ✅ |
| `CreateWellKnownSid` | Win2000 | token | ✅ |
| `SetEntriesInAclW` | Win2000 | setup, token | ✅ |
| `SetNamedSecurityInfoW` | Win2000 | setup, acl | ✅ |
| `GetNamedSecurityInfoW` | Win2000 | acl | ✅ |
| `SetSecurityInfo` | Win2000 | desktop, acl | ✅ |
| `CREATE_NO_WINDOW` (0x08000000) | Win2000 | setup | ✅ |
| `CreateJobObjectW` | Win2000 | command_runner | ✅ |
| `AssignProcessToJobObject` | Win2000 | command_runner | ✅ |
| `CreateMutexW` | Win2000 | read_acl_mutex | ✅ |
| `NetUserAdd` | Win NT | sandbox_users | ✅ |
| `NetLocalGroupAdd` | Win NT | sandbox_users | ✅ |
| `RegCreateKeyExW` | Win2000 | hide_users | ✅ |
| `CryptProtectData` (DPAPI) | Win2000 | dpapi | ✅ |
| `RtlGetVersion` (ntdll) | Win2000 | psuedocon | ✅ |
| `INetFwPolicy2` (COM) | **Vista** | firewall | ✅ |
| `CreatePseudoConsole` | **Win10 1809** | psuedocon (动态), conpty | 🟡 |
| `ResizePseudoConsole` | **Win10 1809** | command_runner (静态), legacy (静态) | 🔴 |
| `ClosePseudoConsole` | **Win10 1809** | psuedocon (动态) | 🟡 |
| `INetFwRule3` (COM) | **Win8** | firewall | 🔴 |

---

## 六、改造方案

### 6.1 改造优先级

| 优先级 | 改造项 | 改造内容 | 预估工作量 |
|--------|--------|---------|-----------|
| **P0** | 防火墙接口降级 | `firewall.rs` 中将 `INetFwRule3` 替换为 `INetFwRule2` | 1-2 天 |
| **P0** | `ResizePseudoConsole` 静态导入改动态加载 | `command_runner/win.rs` + `legacy.rs` 中用 `GetProcAddress` 替换 `windows-sys` 静态导入 | 1 天 |
| **P1** | `load_conpty()` panic → 错误传播 | `psuedocon.rs` 中 `expect()` 改为 `Result`，重新设计 lazy_static 初始化策略 | 1 天 |
| **P1** | 在调用链入口增加 `conpty_supported()` 守卫 | `exec_command` handler 中覆盖 `tty` 为 `false` 当 `!conpty_supported()`；`legacy.rs` 中增加检查 | 0.5 天 |
| **P1** | ConPTY fallback 完整性排查 | 排查所有 10 个调用路径（见四中的路径表），确保 Win7 上 pipe 模式降级不崩溃 | 1-2 天 |
| **P1** | 启动时系统版本检测 | 在 CLI/TUI 入口增加版本检查，Win7 上给出明确提示 | 0.5 天 |
| **P2** | CI 增加 Win7 编译验证 | 至少确保 `x86_64-pc-windows-msvc` target 编译通过 | 1 天 |
| **P3** | 完整 Win7 E2E 测试 | WFP、ACL、Token、沙箱创建等功能的 Win7 实机验证 | 3-5 天 |

### 6.2 P0 改造详细步骤（firewall.rs）

1. 将 `use windows::Win32::NetworkManagement::WindowsFirewall::INetFwRule3;` 改为 `INetFwRule2`
2. 将函数签名中的 `&INetFwRule3` 改为 `&INetFwRule2`
3. 将 `existing.cast::<INetFwRule3>()` 改为 `existing.cast::<INetFwRule2>()`
4. 将 `CoCreateInstance` 返回类型的 `INetFwRule3` 改为 `INetFwRule2`
5. `INetFwRule2` 方法签名完全兼容（`SetLocalUserAuthorizedList`、`SetRemoteAddresses`、`SetRemotePorts` 等方法都存在于 `INetFwRule2`），无需额外改动
6. 测试代码中的 `INetFwRule3` 引用同步修改
7. 编译验证：`cargo check --target x86_64-pc-windows-msvc --bin gienx-windows-sandbox-setup`

### 6.3 P0 改造详细步骤（ResizePseudoConsole 动态加载）

**文件 1**: `codex-rs/windows-sandbox-rs/src/bin/command_runner/win.rs`

1. 删除第 63 行的 `use windows_sys::Win32::System::Console::ResizePseudoConsole;`
2. 添加 `GetProcAddress` + `GetModuleHandleW` 动态加载 `ResizePseudoConsole` 的辅助函数
3. 在第 465 行的 `Message::Resize` 分支中，先检查函数指针是否加载成功再调用

**文件 2**: `codex-rs/windows-sandbox-rs/src/unified_exec/backends/legacy.rs`

1. 删除第 39 行的 `use windows_sys::Win32::System::Console::ResizePseudoConsole;`
2. 添加同样的动态加载辅助函数（或提取为共享工具函数）
3. 在 `resize_conpty_handle()` 函数（第 253 行）中改为动态调用

**共享建议**：将 `ResizePseudoConsole` 的动态加载逻辑提取到 `codex-rs/utils/pty/src/win/psuedocon.rs` 的 `ConPtyFuncs` 中，统一管理所有 ConPTY 函数的动态加载，避免分散实现。

### 6.4 P1 改造详细步骤（ConPTY fallback）

1. **`psuedocon.rs`**: 将 `load_conpty()` 的 `expect()` 改为返回 `Result`，并重新设计 `lazy_static! { static ref CONPTY }` 的初始化逻辑——可改为 `OnceLock<Option<ConPtyFuncs>>` 或在每次访问时做 try 初始化
2. **`pty.rs`**: 确认 `platform_native_pty_system()` 在 Win7 上的行为——检查 `ConPtySystem::openpty()` 在 `CreatePseudoConsole` 不可用时的错误处理
3. **`exec_command.rs`**: 在 handler 入口（约第 240 行）增加：当 `!conpty_supported()` 时，强制覆盖 `tty = false`，防止 LLM 误传 `tty: true`
4. **`legacy.rs`**: 在 `spawn_legacy_process()` 入口（第 65-66 行）增加 `conpty_supported()` 检查，`!conpty_supported()` 时强制 `tty = false`
5. **`command_runner/win.rs`**: 在 `spawn_ipc_process()` 中（第 286 行）增加 `conpty_supported()` 检查作为防御性编程，即使上游已做了守卫
6. **`conpty/mod.rs`**: 在 `spawn_conpty_process_as_user()` 和 `create_conpty()` 入口增加 `conpty_supported()` 检查，作为最后一道防线

### 6.5 启动检测伪代码

```rust
// 在 CLI/TUI 启动入口添加
fn check_windows_compatibility() {
    if cfg!(windows) {
        if !conpty_supported() {
            eprintln!("[WARNING] ConPTY not available on this Windows version.");
            eprintln!("Interactive terminal mode (TTY) is disabled. Using pipe mode.");
        }
        if let Some(build) = windows_build_number() {
            if build < 7601 {
                eprintln!("[ERROR] Windows 7 SP1 or newer is required.");
            }
        }
    }
}
```

---

## 七、测试计划

### 7.1 编译验证

```bash
# 在 Windows 环境下
cargo build --target x86_64-pc-windows-msvc --release \
  --bin gienx-windows-sandbox-setup \
  --bin gienx-command-runner
```

### 7.2 PE 导入表验证（针对问题 2）

```bash
# 使用 dumpbin 检查 command_runner 的导入表是否还包含 ResizePseudoConsole
dumpbin /imports gienx-command-runner.exe | grep -i "ResizePseudoConsole"
# 预期输出为空（表示已改为动态加载）
```

### 7.3 功能验证清单

- [ ] `gienx-windows-sandbox-setup.exe` 在 Win7 上能正常完成沙箱初始化
- [ ] 防火墙规则能正常创建/更新（INetFwRule2 路径）
- [ ] WFP 过滤器能正常安装
- [ ] 沙箱用户能正常创建
- [ ] ACL 权限能正常设置
- [ ] `gienx-command-runner.exe` 在 Win7 上能正常启动（验证问题 2 修复）
- [ ] TTY 模式自动降级为 pipe 模式，不崩溃
- [ ] Pipe 模式下命令执行正常
- [ ] 退出/清理流程正常
- [ ] LLM 传入 `tty: true` 时 `exec_command` 不崩溃，正确降级为 pipe 模式

---

## 八、风险与注意事项

1. **Windows 7 EOL 状态**：Windows 7 已于 2020-01-14 结束支持，微软不再提供安全更新。确保客户知晓此风险。
2. **上游兼容性**：本改造仅限于 gienx fork，上游 openai/codex 仓库不会合并 Win7 兼容代码，后续合并需持续关注 `firewall.rs` 和 ConPTY 相关文件的变更。
3. **MSVC Runtime**：虽然启用了 `crt-static`，但 Win7 可能需要 KB2999226（Universal CRT）和 KB3118401 更新才能正常运行静态链接的 CRT。
4. **TLS 1.2**：Win7 默认不启用 TLS 1.2，而 codex-rs 使用 `rustls`（aws_lc_rs 加密后端），不受系统 SCHANNEL 限制，此点无影响。
5. **LTO 不确定性**：问题 2（`ResizePseudoConsole` 静态导入）对 `gienx.exe` 的影响取决于 LTO 和 dead code elimination。即使某个编译版本恰好被优化掉了该引用，也不应依赖编译器的优化行为——必须显式改为动态加载。
6. **`conpty/mod.rs` 是库代码**：`spawn_conpty_process_as_user()` 和 `create_conpty()` 作为公共 API 被多个调用方（`command_runner`、`legacy`、`elevated` backend）使用，在入口处增加 `conpty_supported()` 守卫或改为返回 `Result` 可一次性保护所有调用路径。

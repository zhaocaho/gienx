
# GienX Windows 7 安装与运行前置要求

> 文档维护: win7-compatable 分支  
> 最后更新: 2026-08-13  
> 适用产品: GienX Desktop (Windows 7 SP1 x64)

---

## 一、概述

GienX 在 Windows 7 SP1 (x64) 上运行需要满足以下前置条件。本文档说明安装包应自动处理的事项，以及用户手动处理的事项。

### 架构说明

```
D:\gienx\superclient\                  ← 项目源码
├── binaries\win32-x64\                ← 打包产物目录
│   ├── gienx.exe                      ← 本项目 (codex-rs) 编译
│   ├── gienx-proxy.exe                ← gienx-proxy 项目编译
│   ├── codex-command-runner.exe
│   ├── codex-windows-sandbox-setup.exe
│   ├── node.exe / node_repl.exe
│   └── rg.exe
├── rust\gienx-proxy\                  ← gienx-proxy 源码
└── ...

D:\客户端\gienx\gienx\                 ← codex-rs 源码
└── target\x86_64-win7-windows-msvc\debug\gienx.exe  ← 编译产物
```

---

## 二、前置组件清单

GienX 在 Windows 7 SP1 (x64) 上运行需要安装以下 5 个组件。缺少任何一个都会导致启动失败或 API 连接失败。

| # | 组件 | 解决的问题 |
|---|------|-----------|
| 1 | **KB2919355** | Windows 更新服务栈补丁。安装其他系统补丁的前置条件，确保后续补丁能正常安装。 |
| 2 | **KB2999226** | Universal C Runtime (UCRT)。提供 `api-ms-win-crt-*.dll` 系列运行时库（共 10 个），GienX 及其依赖的原生 C 库（SQLite、OpenSSL、zstd 等）需要这些库才能运行。缺少此补丁会导致程序启动时报 "找不到 api-ms-win-crt-*.dll" 错误。 |
| 3 | **KB3140245** | TLS 1.2 协议支持。Win7 默认只支持 TLS 1.0/1.1，而现代 API 服务（阿里云、OpenAI、Anthropic 等）要求 TLS 1.2。缺少此补丁会导致 HTTPS 连接失败，报错 "stream disconnected" 或 "SSL/TLS 握手失败"。安装后还需启用注册表项（见下方说明）。 |
| 4 | **VC++ 2015-2022 Redistributable** | Visual C++ 运行时库。提供 `VCRUNTIME140.dll`，GienX 使用 MSVC 编译，依赖此运行时。缺少会导致启动时报 "找不到 VCRUNTIME140.dll" 错误。 |
| 5 | **GlobalSign Root CA - R3 根证书** | SSL 证书信任链。GienX 连接的 API 服务（阿里云、OpenAI、Anthropic 等）使用的 SSL 证书由 GlobalSign 签发，其根证书为 GlobalSign Root CA - R3。Win7 默认根证书存储中不包含此证书，导致 TLS 握手时报 "SEC_E_UNTRUSTED_ROOT" 错误。可通过安装时导入或 gienx-proxy 内置证书解决。 |

> **注意：** KB2919355 和 KB2999226 在实际测试中未手动安装。部分 Win7 系统可能已通过 Windows Update 自动安装，或 GienX 的依赖未使用这些 CRT 函数。如遇到 "找不到 api-ms-win-crt-*.dll" 错误，仍需安装 KB2999226。

### TLS 1.2 注册表启用（KB3140245 安装后必须执行）

KB3140245 安装后，默认可能未启用 TLS 1.2 Client。需运行以下命令（管理员权限）：

```cmd
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v DisabledByDefault /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v Enabled /t REG_DWORD /d 1 /f
```

然后重启电脑。

### 根证书配置（两种方案）

**方案 A：安装时导入证书**

在 GienX 安装包中捆绑 `globalsign-root-r3.cer` 文件，安装脚本自动导入到"受信任的根证书颁发机构"存储。适用于所有 API 服务。

**方案 B：gienx-proxy 内置证书（推荐）**

在 gienx-proxy 代码中内置 GlobalSign Root CA - R3 证书，无需依赖系统证书存储。用户无感知，但证书过期时需更新代码。

### 验证安装成功

```cmd
:: 检查 UCRT
dir C:\Windows\System32\api-ms-win-crt-runtime-l1-1-0.dll

:: 检查 VCRUNTIME
dir C:\Windows\System32\VCRUNTIME140.dll

:: 检查 TLS 1.2 注册表
reg query "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"

:: 测试 HTTPS 连接（任意 API 端点）
curl -v https://api.openai.com/v1/models
```

#### 方案 A：安装时导入根证书（推荐）

在 GienX 安装包中捆绑 `globalsign-root-r3.cer` 文件，安装时自动导入到受信任的根证书颁发机构存储。

**导出证书（在 Win10 上操作）：**

```powershell
$uri = "https://token-plan.cn-beijing.maas.aliyuncs.com"
$request = [System.Net.HttpWebRequest]::Create($uri)
try { $request.GetResponse() } catch {}
$cert = $request.ServicePoint.Certificate
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.Build($cert)

# 导出根证书
$rootCert = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
$rootCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert) |
    Set-Content -Path "$env:USERPROFILE\Desktop\globalsign-root-r3.cer" -Encoding Byte
```

**安装时导入（安装脚本）：**

```powershell
# 以管理员权限运行
$certPath = Join-Path $PSScriptRoot "globalsign-root-r3.cer"
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath)
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
$store.Open("ReadWrite")
$store.Add($cert)
$store.Close()
Write-Output "GlobalSign Root CA - R3 installed successfully"
```

#### 方案 B：gienx-proxy 内置证书（最终方案）

在 `gienx-proxy` 的 `reqwest::Client` 构建时，内置 GlobalSign Root CA - R3 证书，这样无需依赖系统证书存储。

```rust
// D:\gienx\superclient\rust\gienx-proxy\src\server.rs
use reqwest::Certificate;

const GLOBALSIGN_ROOT_CA_R3_PEM: &str = r#"
-----BEGIN CERTIFICATE-----
MIIDujCCAqKgAwIBAgILBAAAAAABD4Ym5g0wDQYJKoZIhvcNAQELBQAwTDEgMB4G
A1UECxMXR2xvYmFsU2lnbiBSb290IENBIC0gUjMxEzARBgNVBAoTCkdsb2JhbFNp
Z24xEzARBgNVBAMTCkdsb2JhbFNpZ24wHhcNMDkwMzE4MTAwMDAwWhcNMjkwMzE4
MTAwMDAwWjBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJvb3QgQ0EgLSBSMzETMBEG
A1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFsU2lnbjCCASIwDQYJKoZI
hvcNAQEBBQADggEPADCCAQoCggEBAMwldpB5BngiFvXAg7aEyiie/QV2EcWtiHL8
RgJDx7KKnQRfJMsuS+FggkbhUqsMgUdwbN1k0ev1LKMPgj0MK66X17YUhhB5uzsT
gHeMCOFJ0mpiLx9e+pZo34knlTifBtc+ycsmWQ1z3rDI6SYOgxXG71uL0gRgykmm
KPZpO/bLyCiR5Z2KYVc3rHQU3HTgOu5yLy6c+9C7v/U9AOEGM+iCK65TpjoWc4zd
QQ4gOsC0p6Hpsk+QLjJg6VfLuQSSaGjlOCZgdbKfd/+RFO+uIEn8rUAVSNECMWEZ
XriX7613t2Saer9fwRPvm2L7DWzgVGkWqQPabumDk3F2xmmFghcCAwEAAaNCMEAw
DgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFI/wS3+o
LkUkrk1Q+mOai97i3Ru8MA0GCSqGSIb3DQEBCwUAA4IBAQBLQNvAUKr+yAzv95ZU
RUm7lgAJQayzE4aGKAczymvmdLm6AC2upArT9fHxD4q/c2dKg8dEe3jgr25sbwMp
jjM5RcOO5LlXbKr8EpbsU8Yt5CRsuZRj+9xTaGdWPoO4zzUhw8lo/s7awlOqzJCK
6fBdRoyV3XpYKBovHd7NADdBj+1EbddTKJd+82cEHhXXipa0095MJ6RMG3NzdvQX
mcIfeg7jLQitChws/zyrVQ4PkX4268NXSb7hLi18YIvDQVETI53O9zJrlAGomecs
Mx86OyXShkDOOyyGeMlhLxS67ttVb9+E7gUJTb0o2HLO02JQZR7rkpeDMdmztcpH
WD9f
-----END CERTIFICATE-----
"#;

pub fn build_client() -> reqwest::Client {
    let cert = Certificate::from_pem(GLOBALSIGN_ROOT_CA_R3_PEM.as_bytes())
        .expect("Failed to parse GlobalSign root certificate");

    reqwest::Client::builder()
        .add_root_certificate(cert)
        .connect_timeout(std::time::Duration::from_secs(30))
        .read_timeout(std::time::Duration::from_secs(300))
        .build()
        .expect("reqwest client with certificate must build")
}
```

**优点：**
- 用户无感知，无需手动导入证书
- 安全性完整（仍然验证证书）
- 跨平台兼容

**缺点：**
- 证书过期时需要更新代码（通常 1-2 年）
- 如果 API 换 CA，需要更新代码

---

## 四、编译级前置（构建 Win7 兼容二进制）

### 4.1 编译环境准备

在构建机器（Windows 10/11 x64）上需要完成以下准备：

1. **安装 Rust 工具链**（MSVC 版本）
   ```powershell
   # 如果尚未安装
   rustup install stable-x86_64-pc-windows-msvc
   rustup default stable-x86_64-pc-windows-msvc
   ```

2. **添加 `rust-src` 组件**（`-Z build-std` 需要从源码编译标准库）：
   ```powershell
   rustup component add rust-src
   ```

3. **安装 Visual Studio Build Tools**（MSVC 编译器，如果尚未安装）

4. **修改 cargo registry 源码**（仅 gienx.exe 需要）

   以下 crate 静态导入了 Win8+ 才有的 API，需要手动替换为 Win7 兼容版本：

   **修改文件：**
   - `windows-core-0.58.0/src/imp/bindings.rs`
   - `windows-core-0.62.2/src/imp/bindings.rs`
   - `windows-core-0.58.0/src/imp/factory_cache.rs`
   - `windows-core-0.62.2/src/imp/factory_cache.rs`
   - `windows-sys-0.52.0/src/Windows/Win32/System/Com/mod.rs`
   - `windows-sys-0.60.2/src/Windows/Win32/System/Com/mod.rs`
   - `windows-sys-0.61.2/src/Windows/Win32/System/Com/mod.rs`
   - `windows-0.58.0/src/Windows/Win32/System/Com/mod.rs`
   - `windows-0.62.2/src/Windows/Win32/System/Com/mod.rs`
   - `windows-0.62.2/src/Windows/Win32/System/WinRT/mod.rs`

   **修改内容：**
   1. `combase.dll` → `ole32.dll`（Win7 没有 combase.dll，COM 功能在 ole32.dll）
   2. `CoIncrementMTAUsage` → `CoInitializeEx(NULL, COINIT_MULTITHREADED)`（等价替换）
   3. `RoGetActivationFactory` → 返回 `REGDB_E_CLASSNOTREG`，走 `DllGetActivationFactory` fallback

   > gienx-proxy 不需要此步骤，它不依赖这些 crate。

### 4.2 gienx.exe 编译命令

```powershell
cd D:\客户端\gienx\gienx\codex-rs

$env:RUSTC_BOOTSTRAP = "1"
$env:RUSTFLAGS = "-L native=C:\Users\<username>\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\windows_x86_64_msvc-0.48.5\lib"

cargo build --bin gienx --target x86_64-win7-windows-msvc -Z build-std
```

产物位置：`codex-rs\target\x86_64-win7-windows-msvc\debug\gienx.exe`

**关键编译参数说明：**

| 参数 | 作用 |
|------|------|
| `--target x86_64-win7-windows-msvc` | Tier 3 target，标准库自动降级到 Win7 兼容 API |
| `-Z build-std` | 从源码编译标准库（rustup 不提供预编译 std） |
| `RUSTC_BOOTSTRAP=1` | 启用 nightly 特性（build-std 需要） |
| `RUSTFLAGS -L native=...` | 添加 windows_x86_64_msvc-0.48.5 的 .lib 路径，解决 `windows.0.48.5.lib` 找不到问题 |

> **注意：** `RUSTFLAGS` 中的 `<username>` 需要替换为实际用户名。可通过以下命令查找实际路径：
> ```powershell
> Get-ChildItem "$env:USERPROFILE\.cargo\registry\src" -Directory | Select-Object -ExpandProperty FullName
> ```

### 4.3 本项目源码修改

| 文件 | 修改内容 |
|------|---------|
| `tui/src/tui.rs` | 终端检测降级、bracketed paste 降级、scroll_region 降级、virtual terminal 降级 |
| `windows-sandbox-rs/src/bin/setup_main/win/firewall.rs` | `INetFwRule3` 降级为 WFP 过滤器 |
| `windows-sandbox-rs/src/conpty/mod.rs` | `ResizePseudoConsole` 动态加载 |
| `utils/pty/src/win/psuedocon.rs` | ConPTY 动态加载 |
| `windows-sandbox-rs/src/unified_exec/backends/legacy.rs` | tty 降级 |
| `windows-sandbox-rs/src/bin/command_runner/win.rs` | tty 降级 |
| `core/src/tools/spec_plan.rs` 等 | `code-mode-runtime` feature gate |
| `.cargo/config.toml` | `crt-static` + `/STACK:8388608` |
| `.gitattributes` | 强制迁移 SQL 文件 CRLF 行尾 |

### 4.4 迁移 SQL 文件行尾

`codex-rs/state/migrations/*.sql` 必须使用 CRLF 行尾，否则与现有数据库校验和不匹配，导致启动失败。

`.gitattributes` 已配置：
```
codex-rs/state/migrations/*.sql text eol=crlf
codex-rs/state/logs_migrations/*.sql text eol=crlf
codex-rs/state/memory_migrations/*.sql text eol=crlf
codex-rs/state/goals_migrations/*.sql text eol=crlf
```

---

## 五、gienx-proxy 编译与证书

### 5.1 编译环境准备

gienx-proxy 的编译环境准备比 gienx.exe 简单，**不需要修改 cargo registry 源码**，也**不需要 `RUSTFLAGS`**。

需要完成的准备：

1. **安装 Rust 工具链**（MSVC 版本）
2. **添加 `rust-src` 组件**：
   ```powershell
   rustup component add rust-src
   ```

### 5.2 gienx-proxy 编译命令

```powershell
cd D:\gienx\superclient\rust\gienx-proxy

$env:RUSTC_BOOTSTRAP = "1"
cargo build --bin gienx-proxy --target x86_64-win7-windows-msvc -Z build-std
```

产物位置：`rust\gienx-proxy\target\x86_64-win7-windows-msvc\debug\gienx-proxy.exe`

### 5.3 证书方案

**推荐：内置证书链（方案 B）**

在 `server.rs` 中内置 GlobalSign Root CA - R3 证书，这样无需依赖系统证书存储。

**备选：安装时导入证书（方案 A）**

如果不用内置方案，则安装脚本需要捆绑 `globalsign-root-r3.cer` 并自动导入。

---

## 六、部署前置清单

### 6.1 安装包应包含

```
GienX-Setup.exe
├── binaries/win32-x64/
│   ├── gienx.exe                    ← Win7 target 编译
│   ├── gienx-proxy.exe              ← Win7 target 编译 + 内置证书
│   ├── codex-command-runner.exe     ← Win7 target 编译
│   ├── codex-windows-sandbox-setup.exe
│   ├── node.exe / node_repl.exe
│   └── rg.exe
├── prerequisites/
│   ├── Windows6.1-KB2919355-x64.msu
│   ├── Windows6.1-KB2999226-x64.msu
│   ├── Windows6.1-KB3140245-x64.msu
│   ├── vc_redist.x64.exe
│   └── globalsign-root-r3.cer       ← 如果不用内置证书方案
└── install.ps1                      ← 安装脚本
```

### 6.2 安装脚本流程

```powershell
# install.ps1 (需管理员权限)

# 1. 检查 Win7 SP1
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Version -lt "6.1.7601") {
    Write-Error "Requires Windows 7 SP1 or later"
    exit 1
}

# 2. 安装前置补丁
$prereqs = @(
    "Windows6.1-KB2919355-x64.msu",
    "Windows6.1-KB2999226-x64.msu",
    "Windows6.1-KB3140245-x64.msu"
)
foreach ($kb in $prereqs) {
    $path = Join-Path $PSScriptRoot "prerequisites\$kb"
    if (Test-Path $path) {
        Write-Output "Installing $kb..."
        Start-Process -FilePath "wusa.exe" -ArgumentList "`"$path`" /quiet /norestart" -Wait
    }
}

# 3. 启用 TLS 1.2
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v DisabledByDefault /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v Enabled /t REG_DWORD /d 1 /f

# 4. 安装 VC++ Redistributable
$vcPath = Join-Path $PSScriptRoot "prerequisites\vc_redist.x64.exe"
if (Test-Path $vcPath) {
    Start-Process -FilePath $vcPath -ArgumentList "/install /quiet /norestart" -Wait
}

# 5. 导入根证书（如果不用内置方案）
$certPath = Join-Path $PSScriptRoot "prerequisites\globalsign-root-r3.cer"
if (Test-Path $certPath) {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $store.Open("ReadWrite")
    $store.Add($cert)
    $store.Close()
}

# 6. 复制二进制文件
$binDest = "C:\Program Files\GienX\binaries\win32-x64"
New-Item -ItemType Directory -Force -Path $binDest | Out-Null
Copy-Item -Path "$PSScriptRoot\binaries\win32-x64\*" -Destination $binDest -Recurse

# 7. 重启
Write-Output "Installation complete. Please restart your computer."
Shutdown /r /t 60 /c "GienX installation requires a restart"
```

---

## 七、验证清单

### 7.1 安装后验证

```cmd
:: 1. 系统组件
dir C:\Windows\System32\api-ms-win-crt-runtime-l1-1-0.dll
dir C:\Windows\System32\VCRUNTIME140.dll
reg query "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"

:: 2. 网络连接
curl -v https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/models

:: 3. 启动测试
gienx.exe --version
gienx-proxy.exe --help
```

### 7.2 PE 导入表验证

使用 `scripts/check_pe_imports.py` 检查二进制是否包含 Win8+ API：

```powershell
python scripts\check_pe_imports.py binaries\win32-x64\gienx.exe
python scripts\check_pe_imports.py binaries\win32-x64\gienx-proxy.exe
```

预期输出：`OK: no deny-listed imports found`

---

## 八、常见问题

### Q1: 启动报 "The program can't start because VCRUNTIME140.dll is missing"
**A:** 未安装 VC++ 2015-2022 Redistributable。运行 `vc_redist.x64.exe`。

### Q2: 启动报 "The procedure entry point GetSystemTimePreciseAsFileTime could not be located in KERNEL32.dll"
**A:** 使用了 `x86_64-pc-windows-msvc` target 编译的二进制，需要用 `x86_64-win7-windows-msvc` + `-Z build-std` 重新编译。

### Q3: 启动报 "The procedure entry point CoIncrementMTAUsage could not be located in ole32.dll"
**A:** 同上，需要 win7 target 编译。

### Q4: 启动报 "stream disconnected before completion: error sending request for url"
**A:** TLS 1.2 未启用或根证书未安装。检查 KB3140245 是否安装、注册表是否启用、根证书是否导入。

### Q5: 启动报 "stdout is not a terminal" 或 "Bracketed paste not implemented"
**A:** TUI 终端兼容性问题。确认使用最新编译的二进制（已修复降级逻辑）。

### Q6: 数据库报错 "migration 1 was previously applied but has been modified"
**A:** 迁移 SQL 文件行尾不对。确认 .gitattributes 配置正确，文件是 CRLF 行尾。

---

## 九、参考链接

- Rust Win7 target 文档: https://doc.rust-lang.org/rustc/platform-support/win7-windows-msvc.html
- Universal CRT: https://support.microsoft.com/en-us/topic/update-for-universal-crt-in-windows-33e4c5c4-7c81-4d23-b343-4a3f0880f4c5
- TLS 1.2 on Windows 7: https://support.microsoft.com/en-us/topic/update-to-enable-tls-1-1-and-tls-1-2-as-default-secure-protocols-in-winhttp-in-windows-33e4c5c4-7c81-4d23-b343-4a3f0880f4c5

---

## 十、变更日志

| 日期 | 变更 |
|------|------|
| 2026-08-11 | 初始分析文档 |
| 2026-08-12 | 添加编译前置、证书配置 |
| 2026-08-13 | 完善安装流程、添加 gienx-proxy 证书方案、补充编译环境准备步骤 |

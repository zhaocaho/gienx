
# GienX Windows 7 前置组件清单

> 本文档说明 GienX 在 Windows 7 SP1 (x64) 上运行必须安装的 5 个组件。缺少任何一个都会导致启动失败或 API 连接失败。

---

## 组件清单

| # | 组件 | 解决的问题 |
|---|------|-----------|
| 1 | **KB2919355** | Windows 更新服务栈补丁。安装其他系统补丁的前置条件，确保后续补丁能正常安装。 |
| 2 | **KB2999226** | Universal C Runtime (UCRT)。提供 `api-ms-win-crt-*.dll` 系列运行时库（共 10 个），GienX 及其依赖的原生 C 库（SQLite、OpenSSL、zstd 等）需要这些库才能运行。缺少此补丁会导致程序启动时报 "找不到 api-ms-win-crt-*.dll" 错误。 |
| 3 | **KB3140245** | TLS 1.2 协议支持。Win7 默认只支持 TLS 1.0/1.1，而现代 API 服务（阿里云、OpenAI、Anthropic 等）要求 TLS 1.2。缺少此补丁会导致 HTTPS 连接失败，报错 "stream disconnected" 或 "SSL/TLS 握手失败"。安装后还需启用注册表项（见下方说明）。 |
| 4 | **VC++ 2015-2022 Redistributable** | Visual C++ 运行时库。提供 `VCRUNTIME140.dll`，GienX 使用 MSVC 编译，依赖此运行时。缺少会导致启动时报 "找不到 VCRUNTIME140.dll" 错误。 |
| 5 | **GlobalSign Root CA - R3 根证书** | SSL 证书信任链。GienX 连接的 API 服务（阿里云、OpenAI、Anthropic 等）使用的 SSL 证书由 GlobalSign 签发，其根证书为 GlobalSign Root CA - R3。Win7 默认根证书存储中不包含此证书，导致 TLS 握手时报 "SEC_E_UNTRUSTED_ROOT" 错误。可通过安装时导入或 gienx-proxy 内置证书解决。 |

> **注意：** KB2919355 和 KB2999226 在实际测试中未手动安装。部分 Win7 系统可能已通过 Windows Update 自动安装，或 GienX 的依赖未使用这些 CRT 函数。如遇到 "找不到 api-ms-win-crt-*.dll" 错误，仍需安装 KB2999226。

---

## TLS 1.2 注册表启用（KB3140245 安装后必须执行）

KB3140245 安装后，默认可能未启用 TLS 1.2 Client。需运行以下命令（管理员权限）：

```cmd
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v DisabledByDefault /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v Enabled /t REG_DWORD /d 1 /f
```

然后重启电脑。

---

## 根证书配置（两种方案）

### 方案 A：安装时导入证书

在 GienX 安装包中捆绑 `globalsign-root-r3.cer` 文件，安装脚本自动导入到"受信任的根证书颁发机构"存储。适用于所有 API 服务。

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

### 方案 B：gienx-proxy 内置证书（推荐）

在 gienx-proxy 代码中内置 GlobalSign Root CA - R3 证书，无需依赖系统证书存储。用户无感知，但证书过期时需更新代码。

---

## 验证安装成功

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

---

## 编译环境与命令

### 编译环境准备

在构建机器（Windows 10/11 x64）上需要完成以下准备：

1. **添加 `rust-src` 组件**（`-Z build-std` 需要从源码编译标准库）：
   ```powershell
   rustup component add rust-src
   ```

### gienx.exe 编译命令

```powershell
cd D:\客户端\gienx\gienx\codex-rs

$env:RUSTC_BOOTSTRAP = "1"
$env:RUSTFLAGS = "-L native=C:\Users\<username>\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\windows_x86_64_msvc-0.48.5\lib"

cargo build --bin gienx --target x86_64-win7-windows-msvc -Z build-std
```

产物位置：`codex-rs\target\x86_64-win7-windows-msvc\debug\gienx.exe`

| 参数 | 作用 |
|------|------|
| `--target x86_64-win7-windows-msvc` | Tier 3 target，标准库自动降级到 Win7 兼容 API |
| `-Z build-std` | 从源码编译标准库（rustup 不提供预编译 std） |
| `RUSTC_BOOTSTRAP=1` | 启用 nightly 特性（build-std 需要） |
| `RUSTFLAGS -L native=...` | 添加 windows crate 的 .lib 路径，解决链接找不到问题 |

### gienx-proxy 编译命令

```powershell
cd D:\gienx\superclient\rust\gienx-proxy

$env:RUSTC_BOOTSTRAP = "1"
cargo build --bin gienx-proxy --target x86_64-win7-windows-msvc -Z build-std
```

产物位置：`rust\gienx-proxy\target\x86_64-win7-windows-msvc\debug\gienx-proxy.exe`

gienx-proxy 不需要修改 cargo registry 源码，也不需要 `RUSTFLAGS`。

> 完整的编译前置说明（cargo registry patch、源码修改清单等）请参阅 `docs/win7-installation-requirements.md`。

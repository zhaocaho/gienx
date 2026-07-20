# gienx 下载与使用

> 用终端下载，**无 macOS 隔离属性（quarantine）**，下载完直接能用。
> 浏览器下载才会被 macOS 打上 `com.apple.quarantine` 标记、触发 Gatekeeper 拦截——这跟构建无关，是浏览器加的。

## 当前版本

`v0.142.4-beta.2`（prerelease）。下面命令里的版本号换成最新 tag 即可。

仓库：https://github.com/zhaocaho/gienx/releases

---

## 方式一：一键安装脚本（自动识别平台）

最省事，自动探测系统、下载对应包、装到 `~/.cargo/bin`（已在 PATH）。

**mac / linux：**
```bash
curl --proto '=https' --tlsv1.2 -sSf \
  https://github.com/zhaocaho/gienx/releases/download/v0.142.4-beta.2/codex-cli-installer.sh | sh
```

**Windows (PowerShell)：**
```powershell
powershell -c "irm https://github.com/zhaocaho/gienx/releases/download/v0.142.4-beta.2/codex-cli-installer.ps1 | iex"
```

装完 `gienx --version` 即可用。

---

## 方式二：终端手动下载平台包（推荐，无隔离）

用 `gh`（已登录）或 `curl` 下载，**都不会加 quarantine**。

### mac Apple Silicon (M 芯片)
```bash
gh release download v0.142.4-beta.2 --repo zhaocaho/gienx \
  --pattern 'codex-cli-aarch64-apple-darwin.tar.xz*'
tar xf codex-cli-aarch64-apple-darwin.tar.xz
./gienx --version
# 想全局可用: sudo mv gienx /usr/local/bin/  (或放 ~/.local/bin)
```

### mac Intel
```bash
gh release download v0.142.4-beta.2 --repo zhaocaho/gienx \
  --pattern 'codex-cli-x86_64-apple-darwin.tar.xz*'
tar xf codex-cli-x86_64-apple-darwin.tar.xz
./gienx --version
```

### Windows x64
```powershell
gh release download v0.142.4-beta.2 --repo zhaocaho/gienx `
  --pattern 'codex-cli-x86_64-pc-windows-msvc.zip*'
Expand-Archive codex-cli-x86_64-pc-windows-msvc.zip -DestinationPath .
.\gienx.exe --version
```
或 curl：
```powershell
curl -LO https://github.com/zhaocaho/gienx/releases/download/v0.142.4-beta.2/codex-cli-x86_64-pc-windows-msvc.zip
```

### Linux x64 (glibc)
```bash
gh release download v0.142.4-beta.2 --repo zhaocaho/gienx \
  --pattern 'codex-cli-x86_64-unknown-linux-gnu.tar.xz*'
tar xf codex-cli-x86_64-unknown-linux-gnu.tar.xz
./gienx --version
# 全局: sudo mv gienx /usr/local/bin/
```

> 没有 `gh`？用 curl 等价命令：
> ```bash
> curl -LO https://github.com/zhaocaho/gienx/releases/download/v0.142.4-beta.2/codex-cli-aarch64-apple-darwin.tar.xz
> curl -LO https://github.com/zhaocaho/gienx/releases/download/v0.142.4-beta.2/codex-cli-aarch64-apple-darwin.tar.xz.sha256
> ```

每个包内容：`gienx`(Windows 为 `gienx.exe`) + `CHANGELOG.md` + `LICENSE` + `README.md`。

---

## 校验（可选）

```bash
# 单包校验
shasum -a 256 -c codex-cli-aarch64-apple-darwin.tar.xz.sha256
# 输出 OK 即通过

# 全部产物一次校验
gh release download v0.142.4-beta.2 --repo zhaocaho/gienx --pattern 'sha256.sum'
shasum -a 256 -c sha256.sum
```

---

## 关于 macOS 隔离属性（quarantine）

| 下载方式 | 是否加 `com.apple.quarantine` | 能否直接跑 |
|---|---|---|
| 终端 `curl` / `gh` | ❌ 不加 | ✅ 直接跑 |
| 浏览器（Safari/Chrome） | ✅ 加 | ❌ Gatekeeper 拦，需先处理 |

- 构建产物本身是干净的，CI/cargo-dist **从不加** quarantine。
- 该属性是**你 Mac 上的浏览器**在下载时加的，与 GitHub Actions 无关。
- 如果手头已有浏览器下载的带隔离文件，去掉即可：
  ```bash
  xattr -dr com.apple.quarantine gienx        # 去隔离
  xattr gienx                                  # 查看剩余属性
  ```

## Electron / 内嵌使用

把 gienx 打进**签名+公证**的 Electron `.app`（放 `Resources/` 里），子二进制继承 app 信任，`child_process.spawn` 直接调用，**无隔离、无弹窗、无需用户"打开"**：

```js
const { spawn } = require('node:child_process');
const gienxPath = require('path').join(process.resourcesPath, 'gienx');
const child = spawn(gienxPath, ['exec', '--...'], { stdio: ['pipe','pipe','pipe'] });
child.stdout.on('data', d => { /* 处理输出 */ });
```

> 签名+公证是设计文档 §12 的后续项；当前 beta 未签名，对外正式分发前需补上。

---

## 列出所有可用产物

```bash
gh release view v0.142.4-beta.2 --repo zhaocaho/gienx --json assets --jq '.assets[].name'
```

或浏览器看：https://github.com/zhaocaho/gienx/releases/tag/v0.142.4-beta.2

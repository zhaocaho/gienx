# gienx 跨平台打包方案设计文档

> 状态：草案 v1
> 作者：gienx
> 日期：2026-07-17
> 适用范围：基于 `codex-rs` 工作区的 `gienx` fork，产出 macOS(Apple Silicon/Intel)、Windows、Linux 原生发行包。

---

## 1. 背景与目标

### 1.1 目标
为 `gienx` fork 提供一套**可重复、自动化**的跨平台原生打包流水线，覆盖：

| 平台 | target triple | 产物形态 |
|------|---------------|----------|
| macOS Apple Silicon | `aarch64-apple-darwin` | 单包（或与 Intel 合成 universal2 单包） |
| macOS Intel | `x86_64-apple-darwin` | 合入 universal2，或独立包 |
| Windows x64 | `x86_64-pc-windows-msvc` | `.zip`，可选 `.msi` |
| Linux x64 (glibc) | `x86_64-unknown-linux-gnu` | `.tar.gz` |
| Linux x64 (静态，兜底老系统) | `x86_64-unknown-linux-musl` | `.tar.gz`（可选） |

> **范围边界**：仓库保持 openai/codex 整个 monorepo 不变（含 codex-ts、sdk 等），但**流水线只产出 `codex-rs` 的二进制与安装包**——CI 仅进入 `codex-rs/` 工作区构建、打包，monorepo 其余部分不参与打包、不出任何产物。

### 1.2 非目标
- 不做交叉编译（从一台机器编全部平台）。
- 不打 TypeScript/Python SDK 部分（`codex-ts`、`sdk/`），仅 Rust 工作区 `codex-rs`。
- 不在本期实现 npm 发版（如未来需要可扩展）。

### 1.3 关键约束（来自仓库现状）
1. **cargo 工作区根是 `codex-rs/`，git 仓库根是上一层 `codex/`**。GitHub Actions workflow 文件必须放在仓库根的 `.github/workflows/`，而 cargo-dist 的配置 `[workspace.metadata.dist]` 必须在 `codex-rs/Cargo.toml`。两者不重合，是本方案最大的实施约束（见 §6）。
2. `codex-rs` 是多二进制工作区，且含**平台专属二进制**：
   - Linux 专属：`codex-linux-sandbox`、`bwrap`（`cfg(target_os = "linux")`）
   - Windows 专属：`codex-windows-sandbox-setup`、`codex-command-runner`（`cfg(windows)`）
   - 开发/测试用，**不应进发行包**：`md-events`、`codex-write-config-schema`、`codex-app-server-test-notify-capture`、`codex-execpolicy-legacy`
3. 工具链固定 `1.95.0`（`rust-toolchain.toml`）。
4. `.cargo/config` 已对 Windows MSVC/GNU 做了链接参数配置，不能被覆盖。

---

## 2. 方案选型

### 2.1 选定方案：cargo-dist + GitHub Actions 原生矩阵构建

`cargo-dist`（axodotdev/cargo-dist）是 Rust 生态专做「多平台原生打包 + GitHub Release + 安装脚本」的标准工具，契合本仓库多二进制 + 平台专属二进制的特点。

### 2.2 为什么不用其他方案

| 备选 | 否决理由 |
|------|----------|
| 本机交叉编译 | Linux/Windows 平台专属 crate（`linux-sandbox`、`windows-sandbox-rs`、`bwrap`）在 macOS 上编不过；需装多套交叉工具链，维护成本高 |
| 纯手写矩阵 + `upload-artifact` + `action-gh-release` | 安装脚本、universal2、checksum、自更新全要自己写，长期维护负担大 |
| `cross` | 面向交叉编译，同样踩平台专属 crate 的坑 |

### 2.3 为什么用原生矩阵而非交叉编译
平台专属 crate 天然只在对应平台原生环境编译通过。在每平台原生 CI runner 上构建，产物最干净、与最终用户环境一致。macOS 两架构在同一 runner 上分别构建后 `lipo` 成 universal2。

---

## 3. 打包对象范围

### 3.1 主发行二进制
- `codex`（`cli/`，CLI 入口，必发）

### 3.2 运行时依赖二进制（按需随主包）
`codex` 运行时可能调用：`apply_patch`、`codex-exec`、`codex-execpolicy`、`codex-mcp-server`、`codex-responses-api-proxy`、`codex-app-server`。需在实施阶段用 `cargo --bin` 或 `cargo-dist` 的 `binaries` 配置确认实际运行时依赖集，避免漏发。

### 3.3 平台专属二进制（仅对应平台编入）
- Linux：`codex-linux-sandbox`、`bwrap`
- Windows：`codex-windows-sandbox-setup`、`codex-command-runner`

### 3.4 排除项（不进发行包）
`md-events`、`codex-write-config-schema`、`codex-app-server-test-notify-capture`、`codex-execpolicy-legacy`、`codex-tui`（若 TUI 已并入 `codex` 主二进制则单独排除）、`codex-code-mode-host`（按需评估）、`codex-stdio-to-uds`、`codex-file-search`、`codex-execve-wrapper`（按运行时是否需要评估）。

> 实施时通过 `[workspace.metadata.dist]` 的 `binaries`/`include` 配置或显式 `[package.metadata.dist]` 精确控制，避免平台专属二进制在不支持的目标上编译失败。

---

## 4. 目标矩阵

| Matrix entry | runner | target | 产物 |
|--------------|--------|--------|------|
| macos-arm64 | `macos-14` | `aarch64-apple-darwin` | 合入 universal2 |
| macos-x64 | `macos-14`(交叉 x86_64) 或 `macos-13` | `x86_64-apple-darwin` | 合入 universal2 |
| macos-universal | 同上 lipo | universal2 | 单个 `.tar.gz` / `.pkg` |
| windows-x64 | `windows-latest` | `x86_64-pc-windows-msvc` | `.zip`（+可选 `.msi`） |
| linux-gnu-x64 | `ubuntu-latest` | `x86_64-unknown-linux-gnu` | `.tar.gz` |
| linux-musl-x64（可选） | `ubuntu-latest` | `x86_64-unknown-linux-musl` | `.tar.gz`（静态） |

**macOS universal2 策略**：开启 `universal-binaries = true`，cargo-dist 自动 `lipo` 合并 arm64 + x86_64 成单包，用户无需挑架构。如发现体积过大或签名问题，退化为双架构独立包。

---

## 5. 触发与版本

- **触发**：打版本 tag 并推送 → 触发 `release.yml`。
- **tag 格式**：必须是 cargo-dist 能解析的版本 tag，即 `v<version>`（如 `v0.142.4-beta.1`）或包作用域 `codex-cli/v<version>`。**不能加 `gienx-` 等前缀**——cargo-dist 会把前缀字符当成版本号导致解析失败。
- **与上游不冲突**：上游 openai/codex 用 `rust-v*` 前缀打 tag，所以 gienx 用纯 `v<version>` 不会撞。
- **版本须与 tag 精确匹配**：tag 的版本必须等于 `codex-rs/Cargo.toml` 的 `workspace.package.version`（含 prerelease 后缀）。发 prerelease 就把版本设成 `0.142.4-beta.1` 再打 `v0.142.4-beta.1`；发正式版用 `0.142.4` + `v0.142.4`。
- 流水线产出：各平台包 + `SHA256SUMS` 校验 + 一键安装脚本（`curl … | sh` / PowerShell）。

---

## 6. 实施关键约束：仓库根 ≠ 工作区根

- git 仓库根：`/Users/zhaochao/code/github-libs/codex/`（openai/codex monorepo）
- cargo 工作区根：`codex-rs/`（`Cargo.toml` 在此）

**处理方式**：
1. `[workspace.metadata.dist]` 配置块写在 **`codex-rs/Cargo.toml`**。
2. 生成的 release workflow 放在 **仓库根 `.github/workflows/release.yml`**（GitHub 只认这个路径）。
3. workflow 中给所有 cargo/dist 步骤设 `defaults.run.working-directory: codex-rs`，使 `cargo dist build` 在 `codex-rs/` 下运行、正确发现工作区。
4. `dist-workspace.toml`（若有）放 `codex-rs/` 下。

**风险**：cargo-dist 官方模板默认假设「仓库根 = 工作区根」，路径处理可能与 `working-directory` 不完全契合。实施第一步需用 `cargo dist init` 验证生成的 workflow 在 `codex-rs` 子目录场景下能否正确产出并上传产物；若不行，回退为手写 workflow + 直接调用 `cargo dist build`，自行控制路径与上传。

---

## 7. 实施步骤

1. **初始化 cargo-dist**
   - `cd codex-rs && cargo install cargo-dist --locked`
   - `cargo dist init`，按提示选目标 target 列表、是否 universal2、是否出 `.msi`。
   - 把生成的 `release.yml` 落到仓库根 `.github/workflows/release.yml`，并加 `working-directory: codex-rs`。
2. **配置 `[workspace.metadata.dist]`**（`codex-rs/Cargo.toml`）要点：
   - `cargo-dist version = "0.x"`（pin 一个版本）
   - `targets = [...]`（§4 矩阵）
   - `include = ["UPGRADE.md", ...]`（附带文档）
   - `universal-binaries = [["codex"]]`（macOS 单二进制合并）
   - `installers = ["shell", "powershell"]`（生成安装脚本）
   - `dist = true`
3. **二进制范围控制**：在 `[workspace.metadata.dist]` 显式声明要发的二进制，或用 `precise-builds`/bin 列表排除开发用二进制，验证平台专属二进制不破坏其他 target。
4. **本地试跑**（单平台，不推 tag）：
   ```
   cd codex-rs && cargo dist build --target x86_64-apple-darwin
   ```
   确认产物结构与二进制清单符合 §3 预期。
5. **tag 试发**：`git tag gienx-v0.1.0 && git push origin gienx-v0.1.0`，观察 CI 全平台矩阵是否都通过、Release 产物齐全。
6. **musl / `.msi` 按需在第 5 步后增量开启**，先跑通 gnu + universal2 + Windows zip 主路径。

---

## 8. CI 成本

- 公开仓库（`zhaocaho/gienx` 若设为 public）：矩阵免费，几乎不设上限。
- 私有仓库：macOS runner 按 10× 计费，一次 release 约 mac + win + linux ≈ 10~15 分钟额度。建议仓库设为 public，或仅在发版时触发、日常不跑。
- 仅打 tag 触发，不在 PR 上跑全矩阵，控制成本。

---

## 9. 产物清单（发版后）

每个 tag 在 GitHub Release 页产出：

```
gienx-v0.1.0-aarch64-apple-darwin.tar.gz     (或 universal2 单包)
gienx-v0.1.0-x86_64-apple-darwin.tar.gz
gienx-v0.1.0-x86_64-pc-windows-msvc.zip      (+可选 .msi)
gienx-v0.1.0-x86_64-unknown-linux-gnu.tar.gz
gienx-v0.1.0-x86_64-unknown-linux-musl.tar.gz (可选)
gienx-v0.1.0-SHA256SUMS
install.sh / install.ps1 (cargo-dist 生成)
```

---

## 10. 风险与缓解

| 风险 | 缓解 |
|------|------|
| cargo-dist 与「仓库根≠工作区根」不兼容 | §6 先验证，必要时手写 workflow 直接调 `cargo dist build` |
| 平台专属二进制在不支持 target 上编译失败 | `[workspace.metadata.dist]` 显式 bin 范围；矩阵 target 与二进制 capability 匹配 |
| universal2 体积过大 / 代码签名缺失 | 退化为双架构独立包；后续按需引入 Apple 开发者证书与 notarize |
| 升级上游 tag 后二进制集合变化 | 参考 `codex-rs/UPGRADE.md`，每次 rebase 升级后重新核对 §3 的二进制清单 |
| Linux glibc 版本过新导致老发行版无法运行 | 增开 musl 静态 target 兜底；或在 ubuntu-latest 上注意 baseline |

---

## 11. 与升级流程的关系

打包方案与 `codex-rs/UPGRADE.md` 的 rebase-onto-tag 升级机制解耦：
- 升级只改源码基线（rebase 到新上游 tag）。
- 打包在新基线上打 `v<version>` tag（见 §5 格式要求）即可发版。
- 升级后**必须重新核对 §3 二进制清单**（上游可能增删 `[[bin]]`），否则矩阵可能漏发或编不过。

---

## 12. 后续可扩展

- npm 发版（`@gienx/codex` 平台专属包）：cargo-dist 支持 npm installer，未来按需开启。
- Apple notarization / Windows 代码签名：证书就绪后在 workflow 增 signing 步骤。
- 自更新：cargo-dist 生成 `dist-manifest`，可接自更新器。
- Homebrew tap / winget：CI 产出后追加发布动作。

---

## 13. 实施现状（2026-07-17）

首次落地完成，提交 `ebd54fb871`（分支 `gienx`）。与设计的差异与要点：

- **工具版本**：cargo-dist `0.32.0`（可执行文件名 `dist`），配置用独立 `dist-workspace.toml`（非旧版 `[workspace.metadata.dist]`）。
- **§6 子目录问题已解决**：在**仓库根**放 `dist-workspace.toml`，`[workspace] members = ["cargo:codex-rs"]` 显式指向 codex-rs cargo 工作区。`dist` 从仓库根即可找到配置并定位到 codex-rs，**无需** workflow 设 `working-directory: codex-rs`。`dist generate` 生成的 `.github/workflows/release.yml` 直接可用，`dist generate --check` 无漂移。
- **§4 universal2 暂未启用**：v0.32 的 `universal-binaries` 键被接受但未合并出 universal archive，行为与文档不符。首版按设计允许的兜底——**macOS 双架构独立包**（arm64、x86_64 各一个 archive）。universal2 留待后续验证正确语法或升级 cargo-dist 版本后再开。
- **§3 二进制范围**：用 `[package.metadata.dist] dist = false` 排除 23 个含二进制的 crate，**仅发 `codex-cli`（`codex`）**。每个平台产出一个含 `codex`（Windows 为 `codex.exe`）+ `CHANGELOG/LICENSE/README` 的压缩包，附 `sha256` 校验和 shell/powershell 安装脚本。
- **运行时辅助二进制（sandbox/apply_patch 等）暂未随包发布**：这些 crate 设了 `dist=false`。`codex` 二进制已把 TUI/CLI/exec/apply-patch 逻辑作为库链接进去；但 Linux 的 `codex-linux-sandbox`、Windows 的 `codex-windows-sandbox-setup` 是独立进程，是否需要随 `codex` 一起分发待运行时验证（设计 §3.2 待办）。
- **触发**：打版本 tag（如 `gienx-v0.142.4`）即触发；workflow 也对 PR 跑轻量 `dist plan`（不跑全矩阵）。
- **未做真机跨平台构建验证**：本地仅 `dist plan` + `dist generate --check` 通过；完整跨平台构建验证靠打 tag 跑 CI。musl/windows 是否一次过需在首次发版时确认，失败则按 §10 回退（如去 musl）。

**首次试发命令**（确认仓库已推送、CI 通后）：
```bash
# 版本已是 0.142.4-beta.1，打对应 prerelease tag
git tag v0.142.4-beta.1
git push origin v0.142.4-beta.1
# 到 GitHub Actions 看 Release 流水线；成功后 Releases 页出现各平台包
```

# Giencoder - Codex 银行内部定制版

基于 OpenAI Codex (`openai/codex`) 的银行内部定制分支，采用 rebase 工作流保持与上游同步。

---

## 分支信息

| 项目 | 值 |
|---|---|
| 分支名 | `giencoder` |
| 基于版本 | `rust-v0.134.0` |
| 上游仓库 | `origin` → `openai/codex` |
| 上游 tag 格式 | `rust-vX.Y.Z`（如 `rust-v0.134.0`） |

---

## 开发规范

### commit 消息格式

所有定制改动统一使用 `giencoder:` 前缀，便于识别和 cherry-pick：

```bash
git commit -m "giencoder: 替换品牌名和标识"
git commit -m "giencoder: 替换鉴权地址为银行内部 SSO"
git commit -m "giencoder: 自定义配置路径"
git commit -m "giencoder: 添加银行定制子代理角色"
```

### 改动原则

1. **改动尽量集中**：每个 commit 只做一件事，便于 rebase 时解冲突
2. **改动文件尽量少**：能通过配置文件解决的不改代码
3. **不动核心引擎逻辑**：品牌、鉴权、配置路径等改动集中在外围模块

---

## 日常开发

```bash
# 确认在 giencoder 分支
git branch

# 正常开发
# ...编辑代码...

# 提交改动
git add <文件>
git commit -m "giencoder: 描述你的改动"
```

---

## 升级流程（rebase 方式）

### 升级前准备

```bash
# 1. 确认在 giencoder 分支
git branch
# 应显示: * giencoder

# 2. 确认所有改动已提交（不要有未提交的修改）
git status
# 如果有未提交的改动，先提交
git add .
git commit -m "giencoder: 升级前保存当前改动"

# 3. 创建备份 tag（重要！出问题可以回退）
git tag giencoder-backup-before-$(date +%Y%m%d)
```

### 执行升级

```bash
# 4. 拉取上游最新代码和 tag
git fetch origin --tags

# 5. 确认目标版本 tag 存在
git tag | grep "rust-v0.135"
# 应显示: rust-v0.135.0 等

# 6. 执行 rebase（把新版本的代码"垫"到你的分支底下）
git rebase rust-v0.135.0
```

### 处理冲突

rebase 过程中可能会遇到冲突：

```bash
# 查看哪些文件冲突了
git status
# 显示: both modified: path/to/file.rs

# 编辑冲突文件，解决冲突
# 搜索 <<<<<<< HEAD 和 ======= 和 >>>>>>> 标记
# 保留你需要的内容，删除冲突标记

# 标记为已解决
git add <解决好的文件>

# 继续 rebase
git rebase --continue

# 如果又有冲突，重复上面的步骤
# 直到 rebase 完成
```

### 放弃升级（回退）

```bash
# 如果冲突太多或出了问题，放弃这次 rebase
git rebase --abort

# 回到升级前的备份
git reset --hard giencoder-backup-before-XXXXXXXX
```

### 升级后验证

```bash
# 7. 确认编译通过
cd codex-rs
cargo build

# 8. 跑一下测试（可选）
cargo test

# 9. 确认 git 历史干净
git log --oneline -10
# 应该看到：
# rust-v0.135.0 的提交记录（上游新代码）
#   giencoder: 你的改动1
#   giencoder: 你的改动2
#   giencoder: 你的改动3
```

---

## 完整升级示例

```bash
# 从 rust-v0.134.0 升级到 rust-v0.135.0

# === 准备阶段 ===
git branch                          # 确认在 giencoder
git status                          # 确认无未提交改动
git tag giencoder-backup-before-20260529

# === 执行升级 ===
git fetch origin                    # 拉取上游
git rebase rust-v0.135.0            # rebase 到新版本

# === 处理冲突（如果有） ===
# git status                        # 查看冲突文件
# vim <冲突文件>                     # 解决冲突
# git add <文件>
# git rebase --continue             # 继续

# === 验证 ===
cd codex-rs && cargo build          # 编译验证
git log --oneline -10               # 查看历史
```

---

## 升级日志

记录每次升级的情况，方便排查问题：

| 日期 | 从 | 到 | 冲突文件 | 备注 |
|---|---|---|---|---|
| 2026-05-29 | — | rust-v0.134.0 | — | 初始创建 giencoder 分支 |
| | | | | |

---

## 常见冲突及处理方式

### 品牌名相关文件

| 文件 | 冲突原因 | 处理方式 |
|---|---|---|
| `cli/src/main.rs` | 你改了程序名，上游改了逻辑 | 保留你的程序名，接受上游逻辑 |
| `tui/src/lib.rs` | 你改了界面文字 | 保留你的文字，接受上游 UI 改动 |

### 鉴权相关文件

| 文件 | 冲突原因 | 处理方式 |
|---|---|---|
| `login/src/auth/manager.rs` | 你改了鉴权 URL | 保留你的 URL，接受上游逻辑 |
| `login/src/device_code_auth.rs` | 你改了设备码地址 | 保留你的地址 |

### 配置路径相关文件

| 文件 | 冲突原因 | 处理方式 |
|---|---|---|
| `utils/home-dir/src/lib.rs` | 你改了默认目录名 | 保留你的目录名 |
| `config/src/config_toml.rs` | 上游改了配置格式 | 接受上游，再适配你的改动 |

### 不太会冲突的文件

| 文件 | 说明 |
|---|---|
| `core/src/**/*.rs` | 核心引擎代码，你一般不改 |
| `Cargo.toml` | 上游加新 crate，直接接受 |
| 测试文件 | 上游测试改动，直接接受 |

---

## 定制改动清单

按优先级排列需要做的改动：

### 必改项

- [ ] 品牌名替换（codex → giencoder 或银行产品名）
- [ ] 鉴权地址替换（auth.openai.com → 银行内部 SSO）
- [ ] 默认配置路径（~/.codex → ~/.giencoder）

### 可选项

- [ ] 自定义子代理角色（安全审计、合规审查等）
- [ ] model provider 替换（指向内部模型网关）
- [ ] 禁用 ChatGPT 登录（只保留内部鉴权方式）
- [ ] 内部日志/监控对接

---

## 项目结构速查

```
codex/
├── codex-rs/                    ← Rust workspace（你的改动主要在这里）
│   ├── cli/                     ← CLI 入口（品牌名）
│   ├── core/                    ← 核心引擎（子代理、工具）
│   ├── login/                   ← 鉴权模块（鉴权地址）
│   ├── config/                  ← 配置读取
│   ├── tui/                     ← 终端 UI
│   ├── app-server/              ← App Server
│   ├── model-provider/          ← 模型提供者（API 地址）
│   └── utils/home-dir/          ← 默认路径（~/.codex）
│
├── sdk/
│   ├── python/                  ← Python SDK
│   └── typescript/              ← TypeScript SDK
│
├── GIENCODER_README.md          ← 本文档
└── codex-rs/Cargo.toml          ← workspace 根配置
```

---

## 快速命令参考

```bash
# 查看当前分支
git branch --show-current

# 查看所有 tag（排序）
git tag | grep "^rust-v[0-9]" | sort -V

# 查看两个版本之间的差异
git log --oneline rust-v0.134.0..rust-v0.135.0

# 查看你的改动有哪些
git log --oneline rust-v0.134.0..giencoder

# 查看某次升级改了哪些文件
git diff --stat rust-v0.134.0..rust-v0.135.0

# 编译
cd codex-rs && cargo build

# 运行
cargo run --bin codex
```

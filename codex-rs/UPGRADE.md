# gienx 升级指南

本文档说明如何把 `gienx` 分支从当前上游 tag 升级到新的上游 tag（例如从 `rust-v0.142.4` 升级到 `rust-v0.145.0`）。

## 分支模型

`gienx` 是一个「追上游」的 fork 分支，结构如下：

```
upstream(openai/codex)  ──●──●──●── rust-v0.142.4 ──●──●──●── rust-v0.145.0
                                                   │
gienx                                              └─ 自定义提交 A, B, C ──► gienx HEAD
```

- `gienx` = 某个上游 tag（基线 tag） + 你自己的若干自定义提交。
- 升级 = 把这批自定义提交 **rebase 到更新的上游 tag 上**，基线从旧 tag 迁到新 tag。
- 这个机制参考自 `giencoder` fork（其提交 `升级至 rust-v0.135.0 后更新锁文件和升级日志` 就是同一种 rebase-onto-tag 模式），但 `gienx` 不携带 `giencoder` 的任何修改内容，从 `rust-v0.142.4` 干净起步。

## 远程仓库

初始配置如下（已在创建分支时设好）：

| remote | 仓库 | 用途 |
|--------|------|------|
| `origin` | `git@github.com:zhaocaho/gienx.git` | 你自己的 fork，push/pull 主仓库 |
| `upstream` | openai/codex | 上游，**只用来 fetch 新 tag**，不直接 push |

核对：
```bash
git remote -v
```

## 升级前准备

1. 确保工作区干净：
   ```bash
   git checkout gienx
   git status            # 必须是 clean
   ```
2. 记录当前基线 tag（用于稍后 rebase 的 `<OLD_TAG>`）：
   ```bash
   git describe --tags --abbrev=0    # 例如 rust-v0.142.4
   ```
3. 确认本地工具链：`rustup show`（本项目固定 `1.95.0`，见 `rust-toolchain.toml`）。

## 升级步骤

### 1. 拉取上游新 tag

```bash
git fetch upstream --tags --prune --prune-tags
```

确认目标 tag 已到本地：
```bash
NEW_TAG=rust-v0.145.0
git tag -l "$NEW_TAG"           # 应能看到该 tag
git log --oneline -1 "$NEW_TAG" # 确认 commit
```

### 2. rebase 自定义提交到新 tag

```bash
OLD_TAG=rust-v0.142.4          # 当前基线，即上一步 git describe 的输出
NEW_TAG=rust-v0.145.0

git rebase --onto "$NEW_TAG" "$OLD_TAG" gienx
```

含义：把 `OLD_TAG..gienx` 范围内（也就是你的全部自定义提交）重新应用到 `NEW_TAG` 之上。`gienx` 分支的基线就此迁到 `rust-v0.145.0`。

> 这一步会**重写 `gienx` 的历史**，所以稍后必须用 `--force-with-lease` 推送。如果你只有自己一个人在用，这是安全的。

### 3. 处理冲突

如果某个自定义提交改的文件在上游也动了，rebase 会暂停并提示冲突：

```bash
# 查看冲突文件
git status

# 手动编辑冲突文件，解决后
git add <已解决的文件>
git rebase --continue

# 中途想放弃：
git rebase --abort
```

冲突通常集中在：
- `Cargo.toml` / `Cargo.lock`（依赖版本上游变了）
- `model-provider-info`、`core` 等你改动过的 crate

> 经验：`Cargo.lock` 的冲突一般不要手工逐行解，直接 `cargo update` 或 `cargo generate-lockfile` 重新生成更可靠（见下一步）。

### 4. 更新锁文件并校验编译

rebase 完成后，重新生成/更新锁文件并保证能编译：

```bash
# 让 Cargo 根据 rebase 后的 Cargo.toml 重新解析依赖
cargo update
# 验证 workspace 能构建（按你实际需要的 feature）
cargo build --release -p codex-cli
# 如果有 lockfile 变化，提交
git add Cargo.lock
git commit -m "chore: 升级至 ${NEW_TAG} 后更新锁文件" || echo "lockfile 未变化"
```

### 5. 跑测试（强烈建议）

```bash
cargo test --workspace
```

至少跑你改动过的 crate 的测试，确认升级没有破坏自定义功能。

### 6. 推送到 origin

因为 rebase 重写了历史，必须强制推送：

```bash
git push origin gienx --force-with-lease
```

`--force-with-lease` 比 `--force` 安全：如果远端有你没拉到的提交会拒绝，防止覆盖别人的工作。

### 7. 打 tag（可选但推荐）

给你的 fork 当前状态打一个版本 tag，方便回滚和发布打包：

```bash
git tag "gienx-${NEW_TAG}"        # 例如 gienx-rust-v0.145.0
git push origin "gienx-${NEW_TAG}"
```

发布打包（mac M / Intel / Windows / Linux）见 `.github/workflows/release.yml`（基于 cargo-dist 的矩阵构建），打 tag 即触发。

## 升级日志

每次升级后在下表追加一行，留痕以便追溯：

| 升级日期 | 旧基线 | 新基线 | 是否有冲突 | 跑测试 | 操作人 | 备注 |
|----------|--------|--------|------------|--------|--------|------|
| 2026-07-17 | — | rust-v0.142.4 | — | — | — | gienx 分支初次建立，干净起步 |

## 常见问题

**Q: rebase 后自定义提交太多、冲突太烦，怎么办？**
A: 如果自定义提交不多（≤5 个），也可改用 cherry-pick：`git checkout -b gienx-new "$NEW_TAG"` 然后 `git cherry-pick <commit-A> <commit-B> ...`，最后 `git branch -M gienx-new gienx`。适合提交少、且每个提交独立的情况。

**Q: 想看升级前后的差异？**
A: `git diff "$OLD_TAG"..gienx -- <你的改动路径>` 查看你的自定义改动总量；`git log --oneline "$OLD_TAG"..gienx` 看自定义提交列表。

**Q: 升级出问题想回滚？**
A: `git reflog` 找到 rebase 前的 HEAD，`git reset --hard <reflog点>`；或用升级前打的备份 tag。

**Q: 上游 tag 命名不规则（`rust-v0.142.4`、`rust-vv0.99.0` 等都有）？**
A: 以 `git tag -l 'rust-v*' | sort -V` 排序后取最新的稳定 tag（避免 `-alpha`/`-beta`），升级前先 `git log` 确认是正式发布。

## 备份建议

升级前给当前 `gienx` 打一个备份 tag，万一 rebase 炸了能秒回：

```bash
git tag "gienx-backup-$(date +%Y%m%d)" gienx
git push origin "gienx-backup-$(date +%Y%m%d)"
```

# Gienx 品牌化改造设计

> 视角：质量经理。目标：零功能破坏、可回滚、可验证、未来可一键再改名。
> 范围：`codex-rs/` 工作区 + `gienx/` 打包/下载脚本。

---

## 1. 目标与决策

将 `codex-rs` 品牌化为 `gienx`，四件事：

1. **进程名** → `gienx`（打包出的主可执行文件名）。
2. **配置目录** `~/.codex` 与仓内 `.codex/` → `.gienx`，收敛为**单一常量**。
3. **提示词品牌**（`You are Codex`→`You are Gienx`、OpenAI 描述词→GienTech）**通过 `model_catalog_json` 覆盖处理，不改源码提示词**（前提见 §4.2）。
4. `CODEX_HOME` 环境变量名**保留不变**（向后兼容）。

**绝对约束**：只改配置目录路径、进程名、提示词身份文案；不改任何业务逻辑、模型调用、沙箱/exec 策略语义。

| # | 决策项 | 选定 |
|---|--------|------|
| D1 | 配置目录 | `~/.codex` 与仓内 `.codex/` 统一改为 `.gienx`，单一常量承载 |
| D2 | 进程名范围 | 仅改 `[[bin]] name = gienx`；`package.name` / `[lib] name` / crate 依赖图不动 |
| D3 | 提示词品牌 | **通过 `model_catalog_json` 覆盖**（catalog 设 `model_messages`/`base_instructions` 为 Gienx/GienTech）；源码提示词改动**延后**为技术债（见 §4.2） |
| D4 | `CODEX_HOME` | 保留原名，不引入 `GIENX_HOME` |

---

## 2. 现状（精确事实）

### 2.1 配置目录的真相源

- **全局 `~/.codex`**：单一解析入口 `codex-rs/utils/home-dir/src/lib.rs:59`（`p.push(".codex")`），`CODEX_HOME` 覆盖入口在 `:14`。`find_codex_home()` 被 `core`/`tui`/`network-proxy`/`app-server-transport` 等统一调用。
- **仓内项目级 `.codex/`**：生产代码硬编码于 `codex-rs/config/src/loader/mod.rs:915` 与 `:1224`。

### 2.2 `.codex` 路径段的全部生产硬编码点

精确扫描（只认作为路径段的 `.codex`，排除 `codex_home` 等变量名、`.codex-plugin` 契约、`/etc/codex` 系统路径）：

| 站点 | file:line | 性质 |
|---|---|---|
| 全局 home | `utils/home-dir/src/lib.rs:59` | 中央解析 |
| 项目层发现 | `config/src/loader/mod.rs:915, :1224` | 中央 loader |
| **沙箱保护路径常量** | `protocol/src/permissions.rs:25` | `PROTECTED_METADATA_CODEX_PATH_NAME = ".codex"`，与 `.git`/`.agents` 同列，writable-root 下只读保护 |
| **沙箱默认 RO 规则** | `protocol/src/permissions.rs:616` | `append_default_read_only_project_root_subpath(..., ".codex")` |
| **Windows 沙箱保护** | `windows-sandbox-rs/src/workspace_acl.rs:14` | `protect_workspace_subdir(cwd, psid, ".codex")` |
| Windows 沙箱其余 | `windows-sandbox-rs/src/allow.rs:323`、`spawn_prep.rs:646`、`setup.rs:1813`、`bin/setup_main/win.rs:1171`、`bin/command_runner/win/cwd_junction.rs:19` | 同义保护/路径 |
| **Linux bwrap 特判** | `linux-sandbox/src/bwrap.rs:416, :1938` | `project_subpath != Path::new(".codex")` + `project_roots(Some(".codex".into()))` |
| **state 独立 home 解析** | `state/src/bin/logs_client.rs:144, :146` | `default_codex_home() = home.join(".codex")`，**绕过 `find_codex_home()` 与 `CODEX_HOME`** |
| **app-server 独立项目发现** | `app-server/src/config/external_agent_config.rs:453, :540, :623, :990, :1045, :1096, :1115` | `.codex/{config.toml,hooks.json,agents}` 独立拼接，不复用 config loader |
| external-agent-migration | `external-agent-migration/src/lib.rs`（~23 处，prod/test 混合） | 迁移目标 `/repo/.codex` |

### 2.3 已走中央、无需改逻辑的站点（仅注释/文案）

| 站点 | 证据 |
|---|---|
| `arg0/src/lib.rs` `.env` 加载 | `:289` 调 `find_codex_home().join(".env")` |
| `arg0` `ILLEGAL_ENV_VAR_PREFIX = "CODEX_"` | `:288`，env 过滤前缀，**保留**（与 D4 一致） |
| `message-history/src/lib.rs` history 路径 | `:115` 走 `config`，仅注释 |
| `rollout/src/recorder.rs` sessions 路径 | `:1423` 走 `config.codex_home().push(SESSIONS_SUBDIR)`，仅注释 |

### 2.4 提示词品牌：源码不改，通过 catalog 覆盖（D3）

**决策**：源码提示词（`core/*.md`、`models-manager/prompt.md`、`protocol/src/prompts/base_instructions/default.md`、`prompts/templates/realtime/backend_prompt.md`、`models-manager/src/model_info.rs:17` 常量、`models-manager/models.json`、相关测试断言）**本次一律不改**。这些文件当前仍是 "Codex/OpenAI" 文本，作为**兜底死路径**保留。

**为什么可以不改**：在打包客户端"必加载 catalog"的约束下，运行时下发提示词由 catalog 的 `model_messages`/`base_instructions` 决定，源码常量被遮蔽、不可达。覆盖关系与字段语义见 §4.2。

**保留的技术债**：源码常量仍是潜在泄漏面（catalog 漏覆盖某 slug / 加载失败 / realtime 模式时触发）。条件与 DoD 见 §4.2、§6.3。

> `GPT-5` / `GPT-5.2` / `GPT-5.5` 等模型 API 标识保留不改（无论源码还是 catalog）。

### 2.5 打包/下载对二进制名的耦合

- `gienx/scripts/download-codex-binaries.sh:69-72` 映射表 `inner_binary` 列硬编码 `codex`/`codex.exe`，`:3-4` 注释"保持原名 codex"。
- `gienx/packaging/DOWNLOAD.md` 含 `./codex`、`mv codex`、`xattr ... codex`、`codex.exe`、Electron `process.resourcesPath/codex`、`spawn(codexPath...)`。
- 产物 tarball 前缀 `codex-cli-*` 来自 `package.name = "codex-cli"`，**保留不变**。

### 2.6 不在范围（显式不动）

- `.codex-plugin/` 插件清单契约（`core-plugins/src/{store,marketplace_add,remote_bundle,plugin_bundle_archive,manifest}.rs`）——插件市场格式契约，改名破坏兼容。
- `/etc/codex/config.toml`、`/etc/codex/managed_config.toml`（`config/src/loader/mod.rs:53`、`loader/layer_io.rs:20`）——Linux 系统级路径，本次不动。
- `dot_codex_folder` 结构体字段名——与序列化/测试耦合，仅改路径值，字段名保留。
- `CODEX_HOME` 环境变量名（D4）。
- `package.name`、`[lib] name`、所有 crate 名 / 依赖路径。
- prompt 文件**文件名**。
- 模型 API 标识 `GPT-5`/`GPT-5.2`/`GPT-5.5` 等（功能标识，不改成 "GienTech-5"）。
- `OpenAI-compatible`（API 兼容性技术术语，如 `models-manager/src/manager.rs` 注释，保留）。
- `chatgpt` auth 模式与 `ChatGPT` 账户逻辑（OAuth 功能流，保留）。
- `models.json` `migration_markdown`/`message` 里的 `openai.com` 外链（指向真实模型供应商页面，单独决策，本次默认保留 URL；"in Codex" 文案按 D3 同步为 "in Gienx"）。
- 辅助二进制名 `codex-exec`/`codex-linux-sandbox`/`codex-mcp-server` 等。
- 子文件名 `config.toml`、`auth.json`、`history.jsonl`、`sessions/`、`log/`、`themes/`、`pets/`。
- `tui/Cargo.toml:10` `codex-tui`（本次不动，可选后续）。
- 沙箱/exec 策略/权限/rollout 业务逻辑。

---

## 3. 设计：单一常量

### 3.1 常量归属

将目录段常量置于所有相关 crate 共同依赖的底层 crate。`protocol/Cargo.toml:21` 已依赖 `codex-utils-absolute-path`，`home-dir`/`config` 亦依赖 utils 系列。

```rust
// codex-rs/utils/absolute-path/src/lib.rs（或新建 codex-utils-brand）
/// 品牌配置目录段。同时用于：
/// - 全局 home 默认目录 ~/.<BRAND_HOME_DIR_SEGMENT>
/// - 仓内项目级配置目录 <repo>/.<BRAND_HOME_DIR_SEGMENT>/
/// - 沙箱对该目录的只读保护路径名
///
/// 未来再改名：改这一行 + Cargo.toml [[bin]] name + 打包脚本/文案。
pub const BRAND_HOME_DIR_SEGMENT: &str = ".gienx";
```

> 用带点号的 `".gienx"`：现有代码 `home_dir().push(".codex")`、`project.join(".codex")`、`Path::new(".codex")`、`protect_workspace_subdir(cwd, psid, ".codex")` 均直接推带点号段，一处常量同时覆盖全局、项目级、沙箱保护三类语义。

### 3.2 所有站点引用同一常量

§2.2 全部生产硬编码点改为引用 `BRAND_HOME_DIR_SEGMENT`。重点：

- `utils/home-dir/src/lib.rs:59` → `p.push(BRAND_HOME_DIR_SEGMENT)`
- `config/src/loader/mod.rs:915, :1224` → `.join(BRAND_HOME_DIR_SEGMENT)`
- `protocol/src/permissions.rs:25` → 常量值改为 `BRAND_HOME_DIR_SEGMENT`（或常量本身引用之）
- `protocol/src/permissions.rs:616` → `append_default_read_only_project_root_subpath(..., BRAND_HOME_DIR_SEGMENT)`
- `windows-sandbox-rs/src/workspace_acl.rs:14` 等 6 处 → 引用常量
- `linux-sandbox/src/bwrap.rs:416, :1938` → 引用常量
- `state/src/bin/logs_client.rs:144, :146` → **改为调用 `find_codex_home()`**，根治绕过 `CODEX_HOME` 的问题；不再保留独立 `default_codex_home()`
- `app-server/src/config/external_agent_config.rs` 7 处 → 引用常量
- `external-agent-migration/src/lib.rs` ~23 处 → 逐处区分 prod/test，prod 引用常量

### 3.3 一个变量的边界

| 能被常量统一（Rust 范围内真正做到"一处改名"） | 跨语言/跨产物，需人工同步（量小且固定） |
|---|---|
| 全局 `~/.gienx` | `cli/Cargo.toml` `[[bin]] name`（1 行） |
| 项目级 `.gienx/` | `gienx/scripts/download-codex-binaries.sh` 映射表（4 行） |
| 沙箱保护路径 | `gienx/packaging/DOWNLOAD.md` 文案 |
| | catalog JSON 的 `instructions_template`/`base_instructions` 文本（用户数据，见 §4.2） |
| | 测试源码 `.join(".codex")` 字面量（机械替换） |

未来把 `.gienx` 改成 `.foo` 的真实成本：改 1 个常量值 + Cargo.toml 1 行 + 脚本 4 行 + 文案 + catalog 文本。源码提示词常量在 catalog 覆盖方案下不动。

---

## 4. 改动清单（file:line × 优先级）

### 4.1 生产逻辑（CRITICAL 必改，原子同批提交）

| 优先级 | 文件 | 行 | 改动 |
|---|---|---|---|
| 🔴🔴 | `protocol/src/permissions.rs` | 2 | `:25` 常量 + `:616` RO 规则 → 引用 `BRAND_HOME_DIR_SEGMENT` |
| 🔴🔴 | `windows-sandbox-rs/src/workspace_acl.rs` + 5 文件 | ~6 | `:14`/`allow.rs:323`/`spawn_prep.rs:646`/`setup.rs:1813`/`bin/setup_main/win.rs:1171`/`cwd_junction.rs:19` |
| 🔴🔴 | `linux-sandbox/src/bwrap.rs` | 2 | `:416`/`:1938` |
| 🔴 | `state/src/bin/logs_client.rs` | 2 | `:144`/`:146` 改调 `find_codex_home()`，删除独立 `default_codex_home()` |
| 🔴 | `utils/home-dir/src/lib.rs` | 1+1 | 新增常量引用 + `:59` push |
| 🟡 | `config/src/loader/mod.rs` | 2 | `:915`/`:1224` |
| 🟡 | `config/Cargo.toml` | 1 | 引入常量所在 utils crate 依赖（若需要） |
| 🟡 | `app-server/src/config/external_agent_config.rs` | 7 | `:453,:540,:623,:990,:1045,:1096,:1115` |
| 🟡 | `external-agent-migration/src/lib.rs` | ~23 | 逐处区分 prod/test，prod 引用常量 |
| **小计** | **~10 crate** | **≈ 45 行** | |

### 4.2 提示词品牌：用 `model_catalog_json` 覆盖（D3，不改源码）

**前提（你已确认全部满足）**：
1. catalog **穷举**客户端能选/能请求的每个 slug；
2. catalog **打包进客户端**且必定加载成功；
3. 客户端**不用 realtime 语音模式**（catalog 结构上无法覆盖 realtime，见 §2.4 技术债）；
4. `config.toml` **不设** `base_instructions`（一旦设置，会置空 `model_messages`，见下文优先级）。

#### 4.2.1 运行时优先级（高→低）

| 层 | 来源 | 代码 | 说明 |
|---|---|---|---|
| ① 最高 | `config.toml` 的 `base_instructions` | `session/mod.rs:602` + `model_info.rs:55-57` | **不要设**——它会同时把 catalog 的 `model_messages` 置 None |
| ② | rollout/history 里保存的提示词（resume） | `session/mod.rs:604` | 正常首启不触发 |
| ③ | **catalog 条目的 `model_messages.instructions_template`** | `get_model_instructions` (`openai_models.rs:456`) | **本次品牌文本放这里**；有 template 则覆盖 ④ |
| ④ 最低 | catalog 条目的 `base_instructions` | `get_model_instructions:466` | 无 model_messages 时回退到此 |

> 即：只要 catalog 条目里设了 `model_messages.instructions_template`，它就是该模型实际下发的系统提示词，源码 `models.json`/`prompt.md` 不可达。

#### 4.2.2 catalog 字段语义

catalog 文件就是 `config.toml` 里 `model_catalog_json` 指向的 JSON，结构 = `ModelsResponse`（`openai_models.rs:552`）：

```json
{ "models": [ <ModelInfo>, ... ] }
```

每个 `<ModelInfo>` 里与提示词相关的字段：

| 字段 | 类型 | 含义 | 是否必填 |
|---|---|---|---|
| `slug` | String | 模型 ID（如 `gpt-5.2-codex`），**必须与客户端请求的 slug 完全一致**，否则覆盖不到 | 必填 |
| `base_instructions` | String | **回退提示词**。仅当本条目没有 `model_messages.instructions_template` 时才用它。若设了 model_messages，此字段被遮蔽（可留旧值或同步改，不影响运行） | 可选 |
| `model_messages` | Object | **高优先级提示词**。若 `instructions_template` 有值，则**覆盖** `base_instructions` 成为下发提示词 | 推荐 |
| `model_messages.instructions_template` | String | 提示词模板。可含占位符 `{{ personality }}`，运行时按当前 personality 替换为对应变量文本；不含占位符则原样下发 | 推荐 |
| `model_messages.instructions_variables` | Object | personality 变量表。要让 `{{ personality }}` 生效，需三者**全部**为 Some（`is_complete`，`openai_models.rs:516`） | 用占位符时必填 |
| `instructions_variables.personality_default` | String | **无 personality 选择时**填入 `{{ personality }}` 的文本（最常见路径）。可空串 `""` | 必填（若用占位符） |
| `instructions_variables.personality_friendly` | String | 用户选 **Friendly** personality 时填入占位符的文本（`openai_models.rs:526`） | 必填（若用占位符） |
| `instructions_variables.personality_pragmatic` | String | 用户选 **Pragmatic** personality 时填入占位符的文本（`:527`） | 必填（若用占位符） |

> Personality 枚举只有 3 个变体：`None`/`Friendly`/`Pragmatic`（`config_types.rs:293`）。`None` → 占位符替换为**空串**（不从三个变量取，`:525`）；无 personality 选择 → 取 `personality_default`（`:530`）。
> 三个变量是**风格修饰文本**，本身不含品牌名；品牌名（Gienx/GienTech）放在 `instructions_template`/`base_instructions` 主体里。

#### 4.2.3 catalog JSON 模板（gienx 品牌示例）

```json
{
  "models": [
    {
      "slug": "gpt-5.2-codex",
      "base_instructions": "You are Gienx, a coding agent based on GPT-5. ...GienTech... (回退用，model_messages 缺失时才走)",
      "model_messages": {
        "instructions_template": "You are Gienx, a coding agent based on GPT-5. You and the user share the same workspace and collaborate to achieve the user's goals.\n\n{{ personality }}\n\n<把原 BASE_INSTRUCTIONS 正文放这里，把 'Codex CLI'→'Gienx CLI'、'led by OpenAI'→'led by GienTech'、'built by OpenAI'→'built by GienTech'>",
        "instructions_variables": {
          "personality_default": "",
          "personality_friendly": "You optimize for team morale and being a supportive teammate as much as code quality.",
          "personality_pragmatic": "You are a deeply pragmatic, effective software engineer."
        }
      }
    },
    {
      "slug": "<其它客户端可选的每个 slug>",
      "model_messages": { "...同上结构..." }
    }
  ]
}
```

**操作要点**：
- `instructions_template` 正文 = 把源码 `prompt.md`（`models-manager/src/model_info.rs:16` `BASE_INSTRUCTIONS`）的内容拷过来，替换品牌词后放入。`{{ personality }}` 占位符位置保持与源码一致（`DEFAULT_PERSONALITY_HEADER` 后、`BASE_INSTRUCTIONS` 前，见 `model_info.rs:112-115`）。
- `personality_default/friendly/pragmatic` 三个变量的原文见 `model_info.rs:18-20`（`LOCAL_FRIENDLY_TEMPLATE`/`LOCAL_PRAGMATIC_TEMPLATE`，`default` 为空串）——直接拷，它们不含品牌词。
- **每个客户端可选的 slug 都要有一条**（前提 1），漏一个就回退源码 "Codex/OpenAI"。
- catalog 文件随客户端打包（前提 2），路径写进 `config.toml` 的 `model_catalog_json`（目录改 `.gienx` 后，建议放 `~/.gienx/gienx-model-catalog.json`）。

#### 4.2.4 DoD（catalog 方案专属）

- [ ] catalog 含客户端每个可选 slug 的条目（穷举校验）
- [ ] 每条 `model_messages.instructions_template` 含 Gienx/GienTech，不含 Codex/OpenAI
- [ ] `config.toml` 未设 `base_instructions`
- [ ] 运行时下发验证（§6.3）：实际提示词含 Gienx/GienTech，无 Codex/OpenAI 残留
- [ ] 技术债登记：源码提示词未改（§2.4），realtime 路径未覆盖

### 4.3 进程名 + 打包（D2 级联）

| 文件 | 行 | 改动 |
|---|---|---|
| `codex-rs/cli/Cargo.toml:10` | 1 | `[[bin]] name = "codex"` → `"gienx"` |
| `gienx/scripts/download-codex-binaries.sh` | ~9 | `:3-4` 注释 + `:69-72` 映射表 `inner_binary` 列 `codex`→`gienx`、`codex.exe`→`gienx.exe`（tarball 名 `codex-cli-*` 保留） |
| `gienx/packaging/DOWNLOAD.md` | ~26 | `./codex`→`./gienx`、`mv codex`→`mv gienx`、`xattr ... codex`→`gienx`、`codex.exe`→`gienx.exe`、Electron `Resources/codex`→`Resources/gienx`、`spawn(codexPath...)` |
| `gienx/packaging/DESIGN.md` | 若干 | 产物内含二进制名描述 |
| **小计** | **~36 行** | |

### 4.4 测试 + 注释（机械替换）

| 类别 | 规模 |
|---|---|
| 测试源码 `.join(".codex")` → `.gienx` | 162 行 / 40 文件 |
| doc-comment `~/.codex` → `~/.gienx` | ~40 行 |

### 4.5 总计

| 维度 | 数量 |
|---|---|
| 涉及 crate（Rust） | ~14 |
| 生产逻辑（配置目录常量化 + 沙箱） | ≈ 45 行 |
| 提示词品牌 | **源码 0 行；catalog 1 文件（用户数据，不进仓库）** |
| 进程名 + 打包 | ≈ 36 行 |
| 测试 | ≈ 162 行 |
| 注释 | ≈ 40 行 |
| **合计（仓库内）** | **≈ 283 行 / ~43 文件 + 1 份 catalog（用户数据）** |

---

## 5. 风险矩阵

| # | 风险 | 等级 | 触发 | 缓解 |
|---|---|---|---|---|
| 1 | 沙箱保护路径名与配置目录名不一致 → 静默安全回退 | 🔴🔴 | `protocol/permissions.rs:25`/Windows/Linux 沙箱未同步改 | §4.1 CRITICAL 站点与配置目录常量**原子同提交、同验证**，不分批错峰 |
| 2 | `state/logs_client` 绕过 `CODEX_HOME` → logs 读错目录 | 🔴 | 独立 `default_codex_home()` 残留 `.codex` | 改调 `find_codex_home()` 根治 |
| 3 | `app-server`/`external-agent-migration` 独立项目发现 → 迁移写错目录 | 🟡 | 7+23 处未同步 | 引用常量，逐处区分 prod/test |
| 4 | 测试 `.join(".codex")` 错位 → CI 红 | 🟡 | 测试漏改一处 | §6.1 grep 残留兜底 + 全量 `cargo test` |
| 5 | 用户 `~/.codex` 旧配置不可见 | 🟡 | 升级后默认读 `.gienx` | 预期行为，发布说明给 `mv ~/.codex ~/.gienx`；不自动迁移 |
| 6 | prompt 品牌改用 catalog 覆盖 → 源码未改是潜在泄漏面 | 🟡 | catalog 漏覆盖某 slug / 加载失败 / 用了 realtime | §4.2 四前提 + §6.3 运行时 grep 兜底；技术债登记，后续补源码 |
| 6.5 | `config.toml` 设了 `base_instructions` → 置空 catalog 的 `model_messages` | 🔴 | 配置误设 | §4.2 前提 4 禁设 + §6.3 运行时验证 |
| 7 | 误改 `.codex-plugin` / `/etc/codex` / `package.name` / `CODEX_HOME` / 源码提示词 | 🔴 | 改名热情蔓延 | §2.6 不变量 + §6.1 grep 白名单校验 |

---

## 6. 验证

### 6.1 静态校验

```bash
# 配置目录字面量零残留（白名单：.codex-plugin、codex_home 等变量名、/etc/codex）
grep -rnE '"\.codex"|/\.codex|~/.codex|push\("\.codex' codex-rs --include='*.rs' \
  | grep -v '/target/' \
  | grep -vE 'codex_home|codex_turn|codex_self|codex_linux|codex_apps|codex_hooks|codex_exe|\.codex-plugin|/etc/codex'
# 期望：0 行

# 提示词源码**保持不动**（catalog 覆盖方案）——下列 grep 用于确认未误改源码提示词
grep -rn 'You are Codex' codex-rs
# 期望：>0 行（源码未改，仍含 Codex；若 0 说明被误改，回滚）

# 环境变量名未被误改
grep -rn 'GIENX_HOME' codex-rs gienx
# 期望：0 行

# 品牌常量已被所有 CRITICAL 站点引用
grep -rn 'BRAND_HOME_DIR_SEGMENT' codex-rs
# 期望：覆盖 home-dir / config / protocol / state / app-server / windows-sandbox / linux-sandbox
```

### 6.2 单元/集成测试

```bash
cd codex-rs
cargo test -p codex-utils-home-dir
cargo test -p codex-config
cargo test -p codex-protocol        # 沙箱保护路径
cargo test -p codex-windows-sandbox # 若平台支持
cargo test -p codex-linux-sandbox
cargo test -p codex-state
cargo test -p codex-core --lib
cargo test -p codex-core --test '*' # config_loader_tests / agents_md_tests / safety_tests / exec_policy_tests
cargo test -p codex-models-manager
cargo test -p codex-app-server --test '*'
cargo test -p codex-external-agent-migration
```
重点：`find_codex_home_without_env_uses_default_home_dir`（默认目录 = `.gienx`）、`realtime_prompt` 断言、`thread_resume` 模板默认值、沙箱保护路径测试。

### 6.3 运行时端到端

```bash
# 产物名
cargo build -p codex-cli --release
ls codex-rs/target/release/gienx   # 期望 gienx 存在，codex 不存在

# 默认目录解析
./gienx --version                   # 首次运行在 ~/.gienx 产生配置

# 项目级仓内配置
mkdir -p /tmp/ws/.gienx && echo 'model="..."' > /tmp/ws/.gienx/config.toml
cd /tmp/ws && gienx exec --help     # 期望加载 .gienx/config.toml

# CODEX_HOME 覆盖仍有效
CODEX_HOME=/tmp/customhome gienx ... # 期望读 /tmp/customhome

# 全局 AGENTS.md 从 .gienx 读取
echo '...' > ~/.gienx/AGENTS.md      # 期望注入上下文

# logs 命令读对目录（验证 #2 风险已根治）
gienx logs list                     # 期望读 ~/.gienx/sessions

# 运行时下发提示词验证（catalog 覆盖是否真正生效——本方案的核心 DoD）
# 用客户端每个可选 slug 各跑一次，确认实际下发提示词
gienx --prompt-debug <slug> 2>&1 | grep -E 'You are|led by|built by|OpenAI|Codex'
# 期望：含 Gienx/GienTech，不含 "You are Codex"/"led by OpenAI"/"built by OpenAI"
# 若出现 Codex/OpenAI → 该 slug 漏进 catalog 或 config 误设 base_instructions（见 §4.2.4）
```

### 6.4 打包/下载端到端

```bash
bash gienx/scripts/download-codex-binaries.sh
ls "$OUT_DIR"/gienx                 # 期望解压出 gienx / gienx.exe
```

### 6.5 提示词行为回归

相同 model + 相同输入，对比改前/改后首轮回复，确认 `You are Gienx` 无明显行为漂移（人工抽检）。

---

## 7. 回滚

- 仓库改动集中在：1 个常量 + `[[bin]]` + 沙箱/解析/loader/迁移若干站点 + 脚本/文案；**源码提示词不动**。
- 提示词品牌在 catalog 文件（用户数据，随客户端打包），不进仓库提交，单独回滚 = 换回旧 catalog 文件。
- 仓库回滚 = `git revert` 该提交，无数据迁移、无不可逆副作用。
- 唯一外部副作用：用户若已 `mv ~/.codex ~/.gienx`，回滚后需 `mv ~/.gienx ~/.codex`。发布说明写清迁移与回滚命令。
- 不自动迁移用户数据（避免 copy 错误、权限问题、双份残留）。

---

## 8. 实施顺序（每阶段独立可验证、可单独提交）

> 阶段 1 的 CRITICAL 站点**必须同批**，不可拆分。

1. **常量 + 全部 CRITICAL 站点**（§4.1 全部）→ 跑 §6.2 沙箱/protocol/state/core 测试。提交。
2. **进程名 + 打包**（§4.3）→ `cargo build -p codex-cli` + §6.4。提交。
3. **测试 + 注释机械替换**（§4.4）→ §6.1 grep + 全量 `cargo test`。提交。
4. **提示词品牌：catalog 覆盖**（§4.2，不碰源码）→ 制作 catalog JSON（穷举所有 slug），随客户端打包，`config.toml` 设 `model_catalog_json` 指向、**不设** `base_instructions`；§6.3 逐 slug 运行时 grep + §6.5 行为回归。catalog 文件不进仓库，进发布物。
5. **发布说明**（`mv ~/.codex ~/.gienx` 迁移指引 + 回滚指引 + 技术债说明：源码提示词未改、realtime 未覆盖）。

---

## 9. 质量门禁（DoD）

- [ ] §6.1 grep：`.codex` 路径段 0 残留、`GIENX_HOME` 0、`You are Codex` 源码**保留**（未被误改）、`BRAND_HOME_DIR_SEGMENT` 覆盖所有 CRITICAL 站点
- [ ] §6.2 列出的 `cargo test` 全绿
- [ ] §6.3 运行时用例符合预期，**含逐 slug 提示词 grep**（Gienx/GienTech 在、Codex/OpenAI 无）
- [ ] §6.4 下载脚本产出 `gienx` 二进制
- [ ] §4.2.4 catalog DoD：穷举所有 slug、`config.toml` 未设 `base_instructions`、catalog 随客户端打包
- [ ] §2.6 不变量逐项复核未触碰（含源码提示词未改）
- [ ] 提交按 Conventional Commits：`feat(codex-rs): rebrand to gienx (config dir, process name)`
- [ ] 发布说明含迁移指引、回滚指引、技术债说明（源码提示词未改/realtime 未覆盖）

---

## 10. 未来再改名检查清单（兑现"一个变量"）

当 `.gienx` 需改为 `.foo`：

1. `codex-rs/utils/absolute-path/src/lib.rs` 改 `BRAND_HOME_DIR_SEGMENT` 值
2. `codex-rs/cli/Cargo.toml` 改 `[[bin]] name`
3. `gienx/scripts/download-codex-binaries.sh` 映射表 `inner_binary` 列
4. `gienx/packaging/DOWNLOAD.md` 文案
5. catalog JSON 里 `instructions_template`/`base_instructions` 的 `Gienx`→`Foo`、`GienTech`→`<新组织名>`（catalog 是用户数据，单独维护）
6. 跑 §6 全套验证（重点 §6.3 逐 slug 运行时 grep）

> 1 是 Rust 常量级改动，2-4 是跨 Cargo.toml / bash / markdown 的人工同步点，5 是 catalog 文件。源码提示词常量（`prompt.md`/`DEFAULT_PERSONALITY_HEADER`/`BACKEND_PROMPT`）在 catalog 覆盖方案下不动；若日后改为源码方案，需额外同步这些常量。

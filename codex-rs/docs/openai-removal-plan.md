# OpenAI / ChatGPT 模块剥离计划

## 背景与目标

目标是将 codex-rs 改造为可对接自有 LLM API 的独立系统。要求：

- 保留所有通用能力（TUI、CLI、MCP、工具、沙箱、配置解析、插件、技能、Hooks、文件操作等）
- 移除所有与 OpenAI / ChatGPT / AWS Bedrock 强绑定的代码
- 保留 OpenAI 兼容协议层（`codex-api`、`codex-client`），因为目标 API 兼容 OpenAI 协议格式

最终效果：用户通过配置文件提供自己的 `api_url` 和 `api_key`，无需 OpenAI 账号，不上传任何数据到 OpenAI 服务器。

---

## 模块分类

### 第一梯队：整个 crate 删除

共 **12 个 crate**。这些 crate 的核心功能就是对接 OpenAI/ChatGPT 认证体系或云端服务，无法通过简单改造复用。

#### A. 登录认证（3 个）

| crate | 路径 | 说明 | 为什么不能复用 |
|---|---|---|---|
| `login` | `login/` | OpenAI OAuth/PKCE + Device Code + API Key 登录全流程 | 硬编码 `https://auth.openai.com/oauth/token`、`https://auth.openai.com/oauth/revoke`、`https://chatgpt.com/backend-api`、`OPENAI_API_KEY` 环境变量、`CodexAuth` 枚举含 `Chatgpt`/`ChatgptAuthTokens` 变体。**注意：被 20 个 crate 引用，需特殊处理（见 Phase 3）** |
| `keyring-store` | `keyring-store/` | 系统钥匙串抽象（macOS Keychain / Linux Secret Service / Windows Credential Manager） | 唯一用途是给 `login` 存 OpenAI 的 access_token / refresh_token |
| `secrets` | `secrets/` | 基于 age 加密 + keyring-store 的密钥管理 | 依赖 `keyring-store`，无人引用（孤立 crate） |

#### B. ChatGPT / OpenAI 平台集成（4 个）

| crate | 路径 | 说明 | 为什么不能复用 |
|---|---|---|---|
| `chatgpt` | `chatgpt/` | ChatGPT 平台集成：`workspace_settings`、`connectors`、`apply_command`、`get_task` | 整个 crate 围绕 ChatGPT 后端 API 设计 |
| `backend-client` | `backend-client/` | 直连 `https://chatgpt.com/backend-api` 的 HTTP 客户端 | 硬编码 `chatgpt.com` / `chat.openai.com` 域名判断，含 `chatgpt_account_id`、`chatgpt_account_is_fedramp`、Cloudflare cookie |
| `codex-backend-openapi-models` | `codex-backend-openapi-models/` | backend-client 的 OpenAPI 自动生成模型 | backend-client 的专属依赖 |
| `responses-api-proxy` | `responses-api-proxy/` | `api.openai.com/v1/responses` 代理调试工具 | 硬编码 `https://api.openai.com/v1/responses`，开发调试工具 |

#### C. 云端服务（4 个）

| crate | 路径 | 说明 | 为什么不能复用 |
|---|---|---|---|
| `cloud-tasks` | `cloud-tasks/` | `codex cloud` 子命令，对接 ChatGPT 云任务 | 硬编码 `https://chatgpt.com/backend-api`，"Not signed in. Please run 'codex login' to sign in with ChatGPT" |
| `cloud-tasks-client` | `cloud-tasks-client/` | cloud-tasks 的 HTTP 客户端 | cloud-tasks 的专属依赖 |
| `cloud-tasks-mock-client` | `cloud-tasks-mock-client/` | cloud-tasks 的测试 Mock | cloud-tasks 的专属依赖 |
| `cloud-requirements` | `cloud-requirements/` | 从 ChatGPT 后端拉取企业策略 `requirements.toml`（仅 Business/Enterprise 客户） | 硬编码 HMAC 缓存签名 key、依赖 `backend-client` + `login` |

#### D. AWS Bedrock（1 个）

| crate | 路径 | 说明 | 为什么不能复用 |
|---|---|---|---|
| `aws-auth` | `aws-auth/` | AWS SigV4 签名，专门为 Bedrock 通道使用 | 仅被 `model-provider` 中 Bedrock 实现引用 |

---

### 第二梯队：保留但需要清理 OpenAI 特有内容

共 **11 个 crate**。这些 crate 的主体框架是通用的，但含有 OpenAI/ChatGPT 的专属代码需要剔除。

#### 基础设施层（8 个）

| # | crate | 保留什么 | 清理什么 | 依赖渗透度 |
|---|---|---|---|---|
| 1 | `codex-client`<br/>`codex-client/` | HTTP 传输层、SSE 流解析、重试策略、自定义 CA 证书 | 删除 `chatgpt_hosts.rs`（chatgpt.com 域名白名单）、`chatgpt_cloudflare_cookies.rs`（Cloudflare cookie 处理） | core, login, exec-server, rmcp-client |
| 2 | `codex-api`<br/>`codex-api/` | `AuthProvider` trait、`Provider` 结构体（base_url + headers + retry）、Responses/Images/Models/Search 端点客户端、SSE、请求构建、限流、错误类型 | 删除 `files.rs`（OpenAI 三步文件上传：`/files` → Azure Blob PUT → `/files/{id}/uploaded`）；可选清理 `provider.rs` 的 `is_azure_responses_provider()` | core（58 处引用）, cli, model-provider, otel, rmcp-client |
| 3 | `model-provider`<br/>`model-provider/` | `ModelProvider` trait 抽象 | 删除 `amazon_bedrock/` 目录（整个 Bedrock 实现）、清理 `auth.rs` 中 `ChatGPT-Account-ID` / `X-OpenAI-Fedramp` header 注入、清理 `models_endpoint.rs` 中 OpenAI 专属模型列表获取逻辑 | core（20 处引用）, cli, tui, app-server |
| 4 | `model-provider-info`<br/>`model-provider-info/` | `ModelProviderInfo` 结构体、`WireApi` 枚举、用户自定义 provider 配置解析、`create_oss_provider()` | 删除 `create_openai_provider()`（硬编码 `api.openai.com`）、`create_amazon_bedrock_provider()`、常量 `OPENAI_PROVIDER_ID`、`CHATGPT_CODEX_BASE_URL`；从 `built_in_model_providers()` 移除 OpenAI + Bedrock 条目；清理 `requires_openai_auth` 字段 | core, config, exec, tui 等 11 个 crate |
| 5 | `models-manager`<br/>`models-manager/` | `ModelsManager` trait、缓存机制 | 删除 `bundled_models_response()`（`include_str!("../models.json")` 加载 OpenAI 内置模型列表）、清理 `collaboration_mode_presets.rs` 中 OpenAI 模型预设 | core, cli, tui, app-server 等 7 个 crate |
| 6 | `protocol`<br/>`protocol/` | 核心协议 / 事件类型 | `openai_models` 模块需要重命名为 `model_types`；清除 OpenAI 专属常量 | 全局使用，~10 个 crate 引用 |
| 7 | `config`<br/>`config/` | 配置解析框架（TOML） | 删除 `cloud_requirements.rs`；清理 `config_toml.rs` 的 `forced_chatgpt_workspace_id`、`chatgpt_base_url`、`openai_base_url`、`OPENAI_PROVIDER_ID` 引用 | 全局使用 |
| 8 | `otel`<br/>`otel/` | OpenTelemetry 集成框架（tracing、OTLP 导出器） | 删除 `config.rs` 的 `STATSIG_OTLP_HTTP_ENDPOINT = "https://ab.chatgpt.com/otlp/v1/metrics"`、`STATSIG_API_KEY`、`StatsigMetricsSettings`、`global_statsig_metrics_settings()`；清理 `session_telemetry.rs` 中 `openai_api_key_env_present` 字段 | login, core, app-server |

#### 会话存储 / 遥测层（3 个，从第一梯队移回）

| # | crate | 实际情况 | OpenAI 代码量 | 清理方式 |
|---|---|---|---|---|
| 9 | `rollout`<br/>`rollout/` | **会话存储层**（非灰度发布）。提供：会话录制（`RolloutRecorder`）、线程列表（`ThreadItem`/`ThreadsPage`）、状态数据库（`state_db`）、会话索引、全文搜索。9047 行代码 | **仅 1 行**：`SessionSource::Custom("chatgpt".to_string())` | 删除该行。保留所有会话持久化功能 |
| 10 | `rollout-trace`<br/>`rollout-trace/` | **会话追踪/录制**。提供：trace bundle 格式、writer、reducer、推理追踪、工具调度追踪、compaction 追踪。12026 行代码 | **0 行 OpenAI 代码** | 无需清理，完全保留。被 core 深度使用（client.rs、session/mod.rs、thread_manager.rs、tool_dispatch_trace.rs） |
| 11 | `analytics`<br/>`analytics/` | 遥测事件数据类型 + HTTP 客户端。数据类型（`CompactionEvent`、`AppInvocation`、`SkillInvocation` 等）被 core 大量使用。HTTP 客户端将事件发往 `{base_url}/codex/analytics-events/events` | 数据发送依赖 `AuthManager`（login） | 保留数据类型定义，删除或空实现 HTTP 发送客户端 |

#### 日志 / 诊断层（1 个，从第一梯队移回）

| # | crate | 实际情况 | OpenAI 代码量 | 清理方式 |
|---|---|---|---|---|
| 12 | `feedback`<br/>`feedback/` | **日志收集层** + Sentry 上报。提供：`logger_layer`（tracing 日志格式化）、`metadata_layer`（会话元数据收集）、`FeedbackDiagnostics`（诊断附件）、`FeedbackRequestTags`（请求标签）。被 core、exec、tui、app-server 使用 | 硬编码 Sentry DSN（OpenAI 项目）、依赖 `login` | 保留日志收集/格式化功能，删除 Sentry 上传代码 |

---

### 第三梯队：核心 crate 的 OpenAI 污染点清理

这些 crate 是系统核心，整体保留，但内部散布 OpenAI 专属代码需要逐个清除。

| crate | 污染文件 / 位置 | 清理内容 |
|---|---|---|
| `core` | `src/client.rs` | 删除 `OPENAI_BETA_HEADER`、`X_OPENAI_MEMGEN_REQUEST_HEADER`、`X_OPENAI_SUBAGENT_HEADER`、`provider.info().is_openai()` 判断 |
| `core` | `src/mcp_openai_file.rs` | 整个文件都是 OpenAI 文件上传桥接逻辑（`_meta["openai/fileParams"]`、`openai/outputTemplate`），删除 |
| `core` | `src/mcp_tool_call.rs` | 删除 `rewrite_mcp_tool_arguments_for_openai_files` 调用、`openai_file_input_params` 参数、`MCP_TOOL_OPENAI_OUTPUT_TEMPLATE_META_KEY` |
| `cli` | `src/login.rs` | 删除 `login_with_chatgpt()`、`run_login_with_chatgpt()`、`login_with_api_key()` 等全部登录命令实现 |
| `cli` | `src/lib.rs` | 删除 `pub use login::run_login_with_chatgpt;` |
| `cli` | `src/doctor.rs` | 删除 `OPENAI_BETA_HEADER`、`OPENAI_API_KEY_ENV_VAR`、`@openai/codex` npm 包路径检测 |
| `tui` | `src/local_chatgpt_auth.rs` | 整个文件都是 ChatGPT 本地认证状态加载，删除 |
| `tui` | `src/session_state.rs` | `openai_models::ReasoningEffort` 路径替换为 `model_types::ReasoningEffort`（在 protocol crate 重命名后） |
| `exec` | `src/lib.rs` | 删除 `chatgpt_base_url` 硬编码 `"https://chatgpt.com/backend-api/"`、`forced_chatgpt_workspace_id`、"chatgpt auth token refresh is not supported in exec mode" 分支 |
| `app-server` | `src/config_manager.rs` | 删除 `chatgpt_base_url` 参数 |
| `app-server` | `src/lib.rs` | 删除 `replace_cloud_requirements_loader`、`remote_control_url: config.chatgpt_base_url` |
| `app-server` | `src/analytics_utils.rs` | 删除基于 `chatgpt_base_url` 的 analytics 初始化 |
| `app-server` | `src/request_processors.rs` | 删除 `use codex_chatgpt::{connectors, workspace_settings}`、`use codex_login::auth::login_with_chatgpt_auth_tokens`、`OPENAI_CURATED_MARKETPLACE_NAME` |
| `app-server` | `src/message_processor.rs` | 删除 `use codex_chatgpt::workspace_settings`、`ExternalAuthTokens::chatgpt(...)` 调用 |
| `app-server` | `src/request_processors/account_processor.rs` | 删除 `login_chatgpt_v2`、`login_chatgpt_device_code_v2`、`login_chatgpt_auth_tokens` |
| `app-server` | `src/bespoke_event_handling.rs` | 删除 `"openai"` model_provider、`"api.openai.com"` target/host 字面量 |
| `exec-server` | `src/fs_sandbox.rs` | 删除测试中的 `OPENAI_API_KEY` 环境变量注入 |

---

### 不属于 OpenAI 相关（保留）

| crate | 理由 |
|---|---|
| `external-agent-migration` | 通用配置迁移工具，与 OpenAI 无关 |
| `external-agent-sessions` | 通用多 Agent 会话管理 |
| `agent-graph-store` | 通用工作流图存储（当前无人依赖，但作为基础设施保留） |
| `agent-identity` | 通用 Agent 身份标识 / 加密签名 |
| `realtime-webrtc` | 通用 WebRTC 通信能力 |
| `ollama` | Ollama 本地模型 Provider，**低优先级可删**（非 OpenAI 强相关，但暂不保留） |
| `lmstudio` | LM Studio Provider，**低优先级可删**（非 OpenAI 强相关，但暂不保留） |
| `collaboration-mode-templates` | 通用协作模式模板 |
| `v8-poc` | V8 实验代码，与 OpenAI 无关（可视情况保留或删除） |
| `thread-manager-sample` | 示例代码，与 OpenAI 无关 |

---

## 执行计划

### Phase 0：环境准备

1. 创建专用分支（如 `refactor/strip-openai`）
2. 跑一次 `cargo check --workspace` 确认基线能编译
3. 备份当前 `Cargo.lock`

### Phase 1：删除第一梯队叶子节点（低风险）

先删除没有被核心 crate 依赖的孤立 crate：

```
secrets, codex-backend-openapi-models, cloud-tasks-mock-client,
responses-api-proxy
```

操作：
- 从 `Cargo.toml` workspace.members 移除
- 删除对应目录
- `cargo check` 确认无影响

### Phase 2：删除第一梯队中间节点

按依赖链从下游往上游删：

```
chatgpt, cloud-tasks, cloud-tasks-client, cloud-requirements,
aws-auth, backend-client
```

操作：
- 从 `Cargo.toml` workspace.members 移除
- 删除对应目录
- 清理所有上游 crate 的 `Cargo.toml` 依赖声明
- 清理上游 crate 源码中的 `use` 语句和相关逻辑（先注释或 `#[cfg]` 隔离）
- `cargo check` 确认

### Phase 3：删除登录认证（高风险，需仔细处理）

```
login, keyring-store
```

这是影响面最大的操作，`login` 被 20 个 crate 引用。需要：

1. 梳理 `login` 暴露的所有 public API（见下表）
2. 在每个引用 crate 中：
   - 删除 `use codex_login::...` 语句
   - 用空实现、trait 抽象、或直接删除替代
3. 特别处理 `codex-client` 和 `codex-api` 中依赖 `login::default_client` 的部分（替换为不依赖 login 的 reqwest client 构建）

`login` 暴露的关键 API 及其替代方案：

| API | 当前用途 | 替代方案 |
|---|---|---|
| `AuthManager` | 全局认证状态管理 | 简化为只读 API Key 持有者，或直接从 config 读取 |
| `CodexAuth` | 认证类型枚举（ApiKey / Chatgpt / ChatgptAuthTokens / AgentIdentity） | 简化为只有 `ApiKey(String)` 一个变体 |
| `default_client::CodexHttpClient` | HTTP 客户端构建 | 移入 `codex-client`，去掉 ChatGPT originator 逻辑 |
| `default_client::get_codex_user_agent()` | User-Agent 字符串 | 移入 `codex-client` |
| `default_client::default_headers()` | 默认请求头 | 移入 `codex-client` |
| `default_client::originator()` | 请求来源标识 | 移入 `codex-client` |
| `run_login_with_chatgpt` | CLI login 命令 | 直接删除 CLI login 子命令 |
| `OPENAI_API_KEY_ENV_VAR` | 环境变量名 | 改名为通用名或硬编码 `API_KEY` |
| `AuthConfig`, `AuthDotJson` | 认证持久化 | 简化为 API Key 存储 |
| `RefreshTokenError` | token 刷新错误 | 删除（不再需要 token 刷新） |
| `UnauthorizedRecovery` | 未授权恢复逻辑 | 简化或删除 |

### Phase 4：清理第二梯队

按 crate 逐个清理：

#### 4.1 `codex-client`
- [ ] 删除 `chatgpt_hosts.rs`
- [ ] 删除 `chatgpt_cloudflare_cookies.rs`
- [ ] 从 `lib.rs` 移除 `pub use` 导出
- [ ] 删除 `default_client.rs` 中 `with_chatgpt_cloudflare_cookie_store` 调用

#### 4.2 `codex-api`
- [ ] 删除 `files.rs`
- [ ] 清理 `lib.rs` 中 `upload_local_file` 等导出
- [ ] 清理 `provider.rs` 中 `is_azure_responses_provider`（可选）
- [ ] 清理上游引用（`core::mcp_openai_file.rs` 等）

#### 4.3 `model-provider`
- [ ] 删除 `amazon_bedrock/` 目录
- [ ] 清理 `auth.rs` 中 ChatGPT header 注入
- [ ] 清理 `models_endpoint.rs` 中 OpenAI 模型列表获取

#### 4.4 `model-provider-info`
- [ ] 删除 `create_openai_provider()`、`create_amazon_bedrock_provider()`
- [ ] 从 `built_in_model_providers()` 只保留 OSS/Ollama/LMStudio
- [ ] 清理 `OPENAI_PROVIDER_ID`、`CHATGPT_CODEX_BASE_URL` 常量
- [ ] 清理 `requires_openai_auth` 字段
- [ ] 更新 config crate 中所有 `OPENAI_PROVIDER_ID` 引用

#### 4.5 `models-manager`
- [ ] 删除 `bundled_models_response()` 和 `models.json` 文件
- [ ] 清理 OpenAI 模型预设

#### 4.6 `protocol`
- [ ] 重命名 `openai_models` 模块为 `model_types`
- [ ] 全文替换 `openai_models::` → `model_types::`
- [ ] 清理 OpenAI 专属常量

#### 4.7 `config`
- [ ] 删除 `cloud_requirements.rs`
- [ ] 清理 `config_toml.rs`：`forced_chatgpt_workspace_id`、`chatgpt_base_url`、`openai_base_url`
- [ ] 清理 `profile_toml.rs`：`chatgpt_base_url`

#### 4.8 `otel`
- [ ] 删除 Statsig 端点和 API Key
- [ ] 删除 `StatsigMetricsSettings`
- [ ] 清理 `session_telemetry.rs` 中 `openai_api_key_env_present`

#### 4.9 `rollout`
- [ ] 删除 `SessionSource::Custom("chatgpt".to_string())` 一行
- [ ] 保留所有会话持久化功能不变

#### 4.10 `rollout-trace`
- [ ] 无需修改，完全保留（0 行 OpenAI 代码）

#### 4.11 `analytics`
- [ ] 保留所有数据类型定义（`CompactionEvent`、`AppInvocation`、`SkillInvocation` 等）
- [ ] 删除 `client.rs` 中 HTTP 发送逻辑，或改为空实现 / 本地日志输出
- [ ] 清理对 `login` 的 `AuthManager` / `CodexAuth` 依赖

#### 4.12 `feedback`
- [ ] 保留 `logger_layer`、`metadata_layer`、`FeedbackDiagnostics`、`FeedbackRequestTags`
- [ ] 删除 Sentry DSN 和上传代码
- [ ] 清理对 `login` 的依赖

### Phase 5：清理第三梯队核心 crate

按 crate 逐个处理污染点（详见上方"第三梯队"表格）。

### Phase 6：验证

1. `cargo check --workspace` 编译通过
2. `cargo test --workspace` 测试通过（需要调整/删除引用了已删 crate 的测试）
3. `cargo clippy --workspace` 无警告
4. 手动验证 CLI 基本功能：`codex --help`、`codex "hello"`（使用自定义 API）

---

## 风险点与注意事项

### 1. `login` crate 的依赖渗透极深（最高风险）

`login` 被 20 个 crate 依赖，其中很多是核心 crate（`core`、`cli`、`tui`、`exec`、`app-server`）。不能简单删除，需要逐层替换。建议采用"接口替换"策略：

- 先创建一个新的轻量 `auth` crate（或在 `codex-client` 中新增模块），只包含：
  - 简化的 `AuthManager`（只读 API Key）
  - 简化的 `CodexAuth`（只有 `ApiKey` 变体）
  - `default_client` 中的通用能力（`CodexHttpClient`、`get_codex_user_agent()`、`default_headers()`、`originator()`）
- 然后逐步将 20 个 crate 的 `use codex_login::...` 替换为新 crate
- 最后删除 `login` crate

### 2. `rollout` + `rollout-trace` 是核心基础设施（不要删！）

经过源码深度分析发现：

- `rollout`（9047 行）是**会话存储层**，不是灰度发布。提供会话录制、线程列表、状态数据库。删除会导致会话历史功能完全失效
- `rollout-trace`（12026 行）是**会话追踪系统**，0 行 OpenAI 代码。被 core 深度使用

两者合计 21073 行代码，是系统最重要的基础设施之一。只需删除 `rollout` 中 1 行 `SessionSource::Chatgpt` 即可。

### 3. `analytics` 和 `feedback` 的数据类型被核心大量使用（不能删！）

- `analytics` 的 `CompactionEvent`、`AppInvocation`、`SkillInvocation` 等类型被 core 的 `compact.rs`、`mcp_tool_call.rs`、`thread_manager.rs` 等使用。删除会导致核心功能编译失败
- `feedback` 的 `logger_layer`、`metadata_layer` 是日志基础设施。删除会导致日志系统失效

正确做法：保留数据类型和日志层，只删除 HTTP 发送 / Sentry 上传部分。

### 4. `codex-client` 的 `default_client.rs` 被多方引用

`login::default_client` 模块导出了 `CodexHttpClient`、`get_codex_user_agent()`、`default_headers()`、`originator()` 等被 `rollout`、`cloud-tasks`、`rmcp-client` 等多个 crate 使用。需要在删除 `login` 前，先把这些通用能力迁移到 `codex-client` crate 自身。

### 5. `protocol::openai_models` 的模块名被广泛使用

`core`、`tui`、`exec`、`config`、`otel`、`analytics`、`models-manager`、`model-provider-info` 等 crate 都使用了 `codex_protocol::openai_models::*`。重命名时需要同步更新所有引用。

### 6. 测试代码中的 OpenAI 字面量

很多 crate 的测试代码中硬编码了 OpenAI URL、API Key 占位符、ChatGPT JWT claims。需要清理或用环境变量替代。

### 7. `app-server` 清理工作量最大

`app-server` 引用了 `chatgpt`、`login`、`cloud-requirements`、`analytics`、`feedback`、`backend-client` 等大量已删 crate，需要大量代码删改。建议优先保证 `app-server` 能在精简模式下编译通过，再逐步恢复功能。

---

## 文件变更清单汇总

| 操作 | crate / 文件 | 数量 |
|---|---|---|
| **整个目录删除** | 第一梯队 12 个 crate | 12 |
| **Cargo.toml 修改** | workspace `Cargo.toml` + 所有引用已删 crate 的上游 `Cargo.toml` | ~30+ |
| **源码文件删除** | `codex-client/chatgpt_hosts.rs`、`chatgpt_cloudflare_cookies.rs`、`codex-api/files.rs`、`core/mcp_openai_file.rs`、`tui/local_chatgpt_auth.rs` | 5 |
| **源码文件修改** | 第三梯队列出的所有污染文件 | ~20+ |
| **模块重命名** | `protocol::openai_models` → `protocol::model_types` + 所有引用更新 | 1（影响 ~10 个 crate） |

---

## 附录：深度分析纠错记录

| 原始判断 | 修正后 | 原因 |
|---|---|---|
| `rollout` = 灰度发布，删除 | **会话存储层，保留** | 9047 行代码仅 1 行 OpenAI 代码，提供会话录制、线程列表、状态数据库等核心功能 |
| `rollout-trace` = rollout 追踪，删除 | **会话追踪系统，保留** | 12026 行代码中 0 行 OpenAI 代码，被 core 深度使用 |
| `analytics` = 遥测上报，删除 | **保留数据类型，删 HTTP 客户端** | 数据类型被 core 大量使用，HTTP 发送依赖 login |
| `feedback` = Sentry 上报，删除 | **保留日志层，删 Sentry** | 日志收集/格式化是基础设施，Sentry 只是上报通道 |
| `ollama`/`lmstudio` = 保留 | **低优先级可删** | 非 OpenAI 强相关，但暂不保留 |

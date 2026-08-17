 # Windows 7 编译适配 - Cargo Patch 方案
 
 > 文档维护: win7-compatable 分支  
 > 最后更新: 2026-08-17  
 > 适用产品: GienX Desktop (Windows 7 SP1 x64)
 
 ---
 
 ## 一、目标
 
 让其他开发者 clone 代码后，安装好 Rust 环境即可直接编译，**无需手动修改 cargo registry 文件**。
 
 ---
 
 ## 二、当前问题
 
 当前 GienX 在 Windows 7 上编译时，需要手动修改 cargo registry 中的 6 个文件：
 
 ```
 C:\Users\<username>\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\
 ├── windows-core-0.62.2\src\imp\bindings.rs
 ├── windows-core-0.62.2\src\imp\factory_cache.rs
 ├── windows-core-0.62.2\src\imp\com_bindings.rs
 ├── windows-0.62.2\src\Windows\Win32\System\Com\mod.rs
 ├── windows-0.62.2\src\Windows\Win32\System\WinRT\mod.rs
 └── windows-sys-0.61.2\src\Windows\Win32\System\Com\mod.rs
 ```
 
 这些修改是为了解决 Windows 7 兼容性问题：
 - `combase.dll` 在 Win7 不存在 → 改为 `ole32.dll`
 - `RoGetActivationFactory` 在 Win7 不存在 → 改为动态加载
 - `CoIncrementMTAUsage` 在 Win7 的 ole32.dll 中不存在 → 改为 `CoInitializeEx`
 
 **问题**：其他开发者拉取代码后，需要手动修改这些文件才能编译，不符合"开箱即用"原则。
 
 ---
 
 ## 三、解决方案
 
 使用 Cargo 的 `[patch.crates-io]` 机制，将修改后的 crate 放在项目仓库内，通过路径引用。
 
 ### 3.1 目录结构
 
 ```
 codex-rs/
 ├── patches/                          ← 新增，提交到 Git
 │   ├── windows-0.62.2/               ← 完整的 crate 源码（已修改）
 │   │   ├── Cargo.toml
 │   │   └── src/
 │   │       └── Windows/
 │   │           └── Win32/
 │   │               └── System/
 │   │                   └── Com/
 │   │                       └── mod.rs
 │   ├── windows-core-0.62.2/          ← 完整的 crate 源码（已修改）
 │   │   ├── Cargo.toml
 │   │   └── src/
 │   │       └── imp/
 │   │           ├── bindings.rs
 │   │           ├── factory_cache.rs
 │   │           └── com_bindings.rs
 │   └── windows-sys-0.61.2/           ← 完整的 crate 源码（已修改）
 │       ├── Cargo.toml
 │       └── src/
 │           └── Windows/
 │               └── Win32/
 │                   └── System/
 │                       └── Com/
 │                           └── mod.rs
 ├── Cargo.toml                        ← 添加 [patch.crates-io]
 └── ...
 ```
 
 ### 3.2 Cargo.toml 修改
 
 在 `codex-rs/Cargo.toml` 的 `[patch.crates-io]` 部分添加：
 
 ```toml
 [patch.crates-io]
 # Windows 7 兼容性 patch
 windows = { path = "patches/windows-0.62.2" }
 windows-core = { path = "patches/windows-core-0.62.2" }
 windows-sys = { path = "patches/windows-sys-0.61.2" }
 
 # 已有的 patch
 crossterm = { git = "https://github.com/nornagon/crossterm", rev = "..." }
 ratatui = { git = "https://github.com/nornagon/ratatui", rev = "..." }
 ```
 
 ### 3.3 工作原理
 
 1. Cargo 解析依赖时，发现 `patches/` 目录下的 crate 版本与 crates.io 上的一致（都是 0.62.2 / 0.61.2）
 2. 自动使用 `patches/` 目录的源码，而不是从 crates.io 下载
 3. 编译时使用已修改的源码，无需手动修改 cargo registry
 
 ---
 
 ## 四、实施步骤
 
 ### 步骤 1：创建 patches 目录
 
 ```powershell
 cd D:\客户端\gienx\gienx\codex-rs
 New-Item -ItemType Directory -Path "patches\windows-0.62.2" -Force
 New-Item -ItemType Directory -Path "patches\windows-core-0.62.2" -Force
 New-Item -ItemType Directory -Path "patches\windows-sys-0.61.2" -Force
 ```
 
 ### 步骤 2：复制修改后的 crate 源码
 
 从 cargo registry 复制已修改的文件到 patches 目录：
 
 ```powershell
 $regDir = "$env:USERPROFILE\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f"
 
 # 复制 windows-0.62.2
 Copy-Item "$regDir\windows-0.62.2\*" -Destination "patches\windows-0.62.2\" -Recurse -Force
 
 # 复制 windows-core-0.62.2
 Copy-Item "$regDir\windows-core-0.62.2\*" -Destination "patches\windows-core-0.62.2\" -Recurse -Force
 
 # 复制 windows-sys-0.61.2
 Copy-Item "$regDir\windows-sys-0.61.2\*" -Destination "patches\windows-sys-0.61.2\" -Recurse -Force
 ```
 
 ### 步骤 3：验证 patches 目录结构
 
 确保以下文件存在且已修改：
 
 ```
 patches/
 ├── windows-0.62.2/
 │   ├── Cargo.toml
 │   └── src/Windows/Win32/System/Com/mod.rs          ← 已修改
 ├── windows-core-0.62.2/
 │   ├── Cargo.toml
 │   └── src/imp/
 │       ├── bindings.rs                               ← 已修改
 │       ├── factory_cache.rs                          ← 已修改
 │       └── com_bindings.rs                           ← 已修改
 └── windows-sys-0.61.2/
     ├── Cargo.toml
     └── src/Windows/Win32/System/Com/mod.rs          ← 已修改
 ```
 
 ### 步骤 4：修改 Cargo.toml
 
 在 `codex-rs/Cargo.toml` 的 `[patch.crates-io]` 部分添加：
 
 ```toml
 [patch.crates-io]
 # Windows 7 兼容性 patch
 windows = { path = "patches/windows-0.62.2" }
 windows-core = { path = "patches/windows-core-0.62.2" }
 windows-sys = { path = "patches/windows-sys-0.61.2" }
 ```
 
 ### 步骤 5：测试编译
 
 在新的环境中测试：
 
 ```powershell
 # 清理 cargo cache（模拟新环境）
 cargo clean
 
 # 编译
 $env:RUSTC_BOOTSTRAP = "1"
 $env:RUSTFLAGS = "-L native=C:\Users\kabuda\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\windows_x86_64_msvc-0.48.5\lib"
 cargo build --bin gienx --target x86_64-win7-windows-msvc -Z build-std
 ```
 
 如果编译成功，说明 patch 生效。
 
 ### 步骤 6：提交到 Git
 
 ```bash
 git add patches/
 git add Cargo.toml
 git commit -m "Add Windows 7 compatibility patches for windows crates"
 git push
 ```
 
 ---
 
 ## 五、预期效果
 
 ### 5.1 其他开发者的体验
 
 1. Clone 代码：
    ```bash
    git clone <repo-url>
    cd gienx/codex-rs
    ```
 
 2. 安装 Rust 环境（参考 `win7-installation-requirements.md`）：
    ```powershell
    rustup install 1.95.0
    rustup component add rust-src
    ```
 
 3. 直接编译：
    ```powershell
    $env:RUSTC_BOOTSTRAP = "1"
    cargo build --bin gienx --target x86_64-win7-windows-msvc -Z build-std
    ```
 
 **无需手动修改任何 cargo registry 文件**。
 
 ### 5.2 维护成本
 
 - **版本更新**：如果上游 `windows` crate 发布新版本，需要更新 `patches/` 目录
 - **同步修改**：如果项目代码需要新的 Windows API，需要在 `patches/` 中添加相应的兼容处理
 
 ---
 
 ## 六、注意事项
 
 ### 6.1 仓库体积
 
 `patches/` 目录包含 3 个 crate 的完整源码，大约 5-10 MB。提交到 Git 仓库会增加仓库体积，但可以接受。
 
 如果担心体积，可以考虑：
 - 只提交修改过的文件，使用脚本从 cargo registry 复制未修改的文件
 - 使用 Git LFS 管理大文件
 
 但这样会增加复杂度，建议先使用完整提交的方式。
 
 ### 6.2 版本锁定
 
 建议在 `Cargo.toml` 中锁定 `windows` 相关 crate 的版本，避免意外升级：
 
 ```toml
 [workspace.dependencies]
 windows = "=0.62.2"
 windows-core = "=0.62.2"
 windows-sys = "=0.61.2"
 ```
 
 ### 6.3 文档更新
 
 需要更新以下文档，移除手动修改 cargo registry 的步骤：
 
 - `docs/win7-installation-requirements.md`
 - `docs/win7-compile-patch.md`（如果存在）
 
 ### 6.4 CI/CD
 
 确保 CI 环境也能正确应用 patch。由于 patch 目录在仓库内，CI 应该自动生效。
 
 ---
 
 ## 七、回滚方案
 
 如果需要回滚到修改 cargo registry 的方式：
 
 1. 删除 `patches/` 目录
 2. 从 `Cargo.toml` 中移除 `[patch.crates-io]` 中的 windows 相关条目
 3. 恢复手动修改 cargo registry 的流程
 
 ---
 
 ## 八、变更日志
 
 | 日期 | 变更 |
 |------|------|
 | 2026-08-17 | 初始方案文档 |

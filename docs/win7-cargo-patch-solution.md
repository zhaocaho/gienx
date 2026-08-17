 # Windows 7 编译适配 - Cargo Registry Patch 方案
 
 > 文档维护: win7-compatable 分支  
 > 最后更新: 2026-08-17  
 > 适用产品: GienX Desktop (Windows 7 SP1 x64)
 
 ---
 
 ## 一、目标
 
 让其他开发者 clone 代码后，只需运行一个脚本即可编译，**无需手动修改 cargo registry 文件**。
 
 ---
 
 ## 二、问题背景
 
 GienX 在 Windows 7 上编译时，需要修改 cargo registry 中 `windows`/`windows-core`/`windows-sys` crate 的源码（`combase.dll` → `ole32.dll`，`RoGetActivationFactory` 改动态加载等）。
 
 完整 crate 源码约 126MB，不适合提交到 Git 仓库。因此采用**轻量 patch 方案**：只存储修改的 6 个文件（约 1MB），配合 setup 脚本自动应用。
 
 ---
 
 ## 三、方案说明
 
 ### 3.1 目录结构
 
 ```
 codex-rs/patches/win7/
 ├── apply-patches.ps1                                    ← 自动 patch 脚本
 ├── windows-core-0.62.2/src/imp/
 │   ├── bindings.rs                                      ← 已修改
 │   ├── factory_cache.rs                                 ← 已修改
 │   └── com_bindings.rs                                  ← 已修改
 ├── windows-0.62.2/src/Windows/Win32/System/
 │   ├── Com/mod.rs                                       ← 已修改
 │   └── WinRT/mod.rs                                     ← 已修改
 └── windows-sys-0.61.2/src/Windows/Win32/System/
     └── Com/mod.rs                                       ← 已修改
 ```
 
 ### 3.2 工作原理
 
 1. `apply-patches.ps1` 脚本将 `patches/win7/` 中的 6 个文件复制到 cargo registry 对应位置
 2. 自动备份原文件（`.bak`），支持重复执行（已 patch 的文件会跳过）
 3. 编译时使用已修改的源码
 
 ---
 
 ## 四、使用方式
 
 ### 4.1 新开发者首次设置
 
 ```powershell
 # 1. Clone 代码
 git clone <repo-url>
 cd gienx/codex-rs
 
 # 2. 安装 Rust 环境（参考 win7-installation-requirements.md）
 rustup install 1.95.0
 rustup component add rust-src
 
 # 3. 下载依赖（确保 cargo registry 中有对应 crate）
 cargo fetch
 
 # 4. 应用 Win7 兼容性 patch
 powershell -ExecutionPolicy Bypass -File patches\win7\apply-patches.ps1
 
 # 5. 编译
 $env:RUSTC_BOOTSTRAP = "1"
 $env:RUSTFLAGS = "-L native=$env:USERPROFILE\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\windows_x86_64_msvc-0.48.5\lib"
 cargo build --bin gienx --target x86_64-win7-windows-msvc -Z build-std
 ```
 
 ### 4.2 脚本输出示例
 
 ```
 Cargo registry 目录: C:\Users\kabuda\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f
 [OK]   已应用: windows-core-0.62.2\src\imp\bindings.rs
 [OK]   已应用: windows-core-0.62.2\src\imp\factory_cache.rs
 [OK]   已应用: windows-core-0.62.2\src\imp\com_bindings.rs
 [OK]   已应用: windows-0.62.2\src\Windows\Win32\System\Com\mod.rs
 [OK]   已应用: windows-0.62.2\src\Windows\Win32\System\WinRT\mod.rs
 [OK]   已应用: windows-sys-0.61.2\src\Windows\Win32\System\Com\mod.rs
 
 Patch 完成: 应用 6 个, 跳过 0 个, 失败 0 个
 ```
 
 ---
 
 ## 五、注意事项
 
 1. **`cargo fetch` 必须先于 patch 脚本运行**：脚本需要 cargo registry 中已有对应版本的 crate 源码
 2. **`cargo clean` 不影响 patch**：`cargo clean` 只清理 target 目录，不清理 cargo registry
 3. **`cargo update` 后需重新 patch**：如果 `cargo update` 更新了 windows crate 版本，patch 会失效，需要重新运行脚本
 4. **原文件自动备份**：首次 patch 时，原文件会备份为 `.bak`，如需恢复可手动还原
 
 ---
 
 ## 六、变更日志
 
 | 日期 | 变更 |
 |------|------|
 | 2026-08-17 | 初始方案文档 |
 | 2026-08-17 | 改为轻量 patch 方案（只存储修改文件 + setup 脚本） |

 # GienX Windows 7 - Cargo Registry Patch Script
 #
 # Usage: Run from codex-rs directory
 #   powershell -ExecutionPolicy Bypass -File patches\win7\apply-patches.ps1
 #
 # Prerequisites:
 #   1. Rust toolchain installed (rustup)
 #   2. Run 'cargo fetch' first to download dependencies
 #
# This script patches the following files:
#   - windows-core-0.62.2/src/imp/bindings.rs
#   - windows-core-0.62.2/src/imp/factory_cache.rs
#   - windows-core-0.62.2/src/imp/com_bindings.rs
#   - windows-0.62.2/src/Windows/Win32/System/Com/mod.rs
#   - windows-0.62.2/src/Windows/Win32/System/WinRT/mod.rs
#   - windows-sys-0.61.2/src/Windows/Win32/System/Com/mod.rs
#   - windows_x86_64_msvc-0.48.5/build.rs
 
 $ErrorActionPreference = "Stop"
 
 # Locate cargo registry source directory
 $registryBase = Join-Path $env:USERPROFILE ".cargo\registry\src"
 $registryDirs = Get-ChildItem $registryBase -Directory -ErrorAction SilentlyContinue |
     Where-Object { $_.Name -like "index.crates.io-*" }
 
 if (-not $registryDirs) {
     Write-Error "Cargo registry source directory not found. Please run 'cargo fetch' first."
     exit 1
 }
 
 $regDir = $registryDirs[0].FullName
 Write-Host "Cargo registry: $regDir"
 
 # Patch source files directory
 $patchBase = $PSScriptRoot
 
 # Define file mappings
 $patches = @(
     @{
         Source = "windows-core-0.62.2\src\imp\bindings.rs"
         Target = "windows-core-0.62.2\src\imp\bindings.rs"
     },
     @{
         Source = "windows-core-0.62.2\src\imp\factory_cache.rs"
         Target = "windows-core-0.62.2\src\imp\factory_cache.rs"
     },
     @{
         Source = "windows-core-0.62.2\src\imp\com_bindings.rs"
         Target = "windows-core-0.62.2\src\imp\com_bindings.rs"
     },
     @{
         Source = "windows-0.62.2\src\Windows\Win32\System\Com\mod.rs"
         Target = "windows-0.62.2\src\Windows\Win32\System\Com\mod.rs"
     },
     @{
         Source = "windows-0.62.2\src\Windows\Win32\System\WinRT\mod.rs"
         Target = "windows-0.62.2\src\Windows\Win32\System\WinRT\mod.rs"
     },
    @{
        Source = "windows-sys-0.61.2\src\Windows\Win32\System\Com\mod.rs"
        Target = "windows-sys-0.61.2\src\Windows\Win32\System\Com\mod.rs"
    },
    @{
        Source = "windows_x86_64_msvc-0.48.5\build.rs"
        Target = "windows_x86_64_msvc-0.48.5\build.rs"
    }
)
 
 $applied = 0
 $skipped = 0
 $failed = 0
 
 foreach ($patch in $patches) {
     $sourceFile = Join-Path $patchBase $patch.Source
     $targetFile = Join-Path $regDir $patch.Target
 
     if (-not (Test-Path $sourceFile)) {
         Write-Warning "Patch source file missing: $sourceFile"
         $failed++
         continue
     }
 
     if (-not (Test-Path $targetFile)) {
         Write-Warning "Target file missing (not downloaded yet): $targetFile"
         Write-Warning "Please run 'cargo fetch' first, then re-run this script."
         $skipped++
         continue
     }
 
     # Check if already patched (compare file content)
     $targetContent = Get-Content $targetFile -Raw -Encoding UTF8
     $sourceContent = Get-Content $sourceFile -Raw -Encoding UTF8
 
     if ($targetContent -eq $sourceContent) {
         Write-Host "[SKIP] Already patched: $($patch.Target)" -ForegroundColor Yellow
         $skipped++
         continue
     }
 
     # Backup original file
     $backupFile = "$targetFile.bak"
     if (-not (Test-Path $backupFile)) {
         Copy-Item $targetFile $backupFile
     }
 
     # Apply patch
     Copy-Item $sourceFile $targetFile -Force
     Write-Host "[OK]   Applied: $($patch.Target)" -ForegroundColor Green
     $applied++
 }
 
 Write-Host ""
 Write-Host "Patch complete: applied=$applied, skipped=$skipped, failed=$failed"
 
 if ($failed -gt 0) {
     exit 1
 }
 
 if ($applied -gt 0) {
     Write-Host ""
     Write-Host "Ready to build:" -ForegroundColor Cyan
     Write-Host "  `$env:RUSTC_BOOTSTRAP = 1"
     Write-Host "  cargo build --bin gienx --target x86_64-win7-windows-msvc -Z build-std"
 }

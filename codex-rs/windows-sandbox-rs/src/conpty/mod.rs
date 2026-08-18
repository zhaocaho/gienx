//! ConPTY helpers for spawning sandboxed processes with a PTY on Windows.
//!
//! This module encapsulates ConPTY creation and process spawn with the required
//! `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` plumbing. It is shared by both the legacy
//! restricted‑token path and the elevated runner path when unified_exec runs with
//! `tty=true`. The helpers are not tied to the IPC layer and can be reused by other
//! Windows sandbox flows that need a PTY.

use crate::desktop::LaunchDesktop;
use crate::proc_thread_attr::ProcThreadAttributeList;
use crate::winutil::format_last_error;
use crate::winutil::quote_windows_arg;
use crate::winutil::to_wide;
use anyhow::Result;
use codex_utils_pty::PsuedoCon;
use codex_utils_pty::RawConPty;
use std::collections::HashMap;
use std::ffi::CString;
use std::ffi::c_void;
use std::os::windows::io::IntoRawHandle;
use std::path::Path;
use std::sync::OnceLock;
use windows_sys::Win32::Foundation::CloseHandle;
use windows_sys::Win32::Foundation::GetLastError;
use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
use windows_sys::Win32::System::Console::COORD;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::LibraryLoader::GetProcAddress;
use windows_sys::Win32::System::Threading::CREATE_UNICODE_ENVIRONMENT;
use windows_sys::Win32::System::Threading::CreateProcessAsUserW;
use windows_sys::Win32::System::Threading::EXTENDED_STARTUPINFO_PRESENT;
use windows_sys::Win32::System::Threading::PROCESS_INFORMATION;
use windows_sys::Win32::System::Threading::STARTF_USESTDHANDLES;
use windows_sys::Win32::System::Threading::STARTUPINFOEXW;

use crate::process::make_env_block;

/// Owns a ConPTY handle and its backing pipe handles.
pub struct ConptyInstance {
    pseudoconsole: Option<PsuedoCon>,
    input_write: HANDLE,
    output_read: HANDLE,
    _desktop: Option<LaunchDesktop>,
}

impl Drop for ConptyInstance {
    fn drop(&mut self) {
        unsafe {
            if self.input_write != 0 && self.input_write != INVALID_HANDLE_VALUE {
                CloseHandle(self.input_write);
            }
            if self.output_read != 0 && self.output_read != INVALID_HANDLE_VALUE {
                CloseHandle(self.output_read);
            }
        }
        let _ = self.pseudoconsole.take();
    }
}

impl ConptyInstance {
    pub fn raw_handle(&self) -> Option<HANDLE> {
        self.pseudoconsole
            .as_ref()
            .map(|pseudoconsole| pseudoconsole.raw_handle() as HANDLE)
    }

    pub fn take_input_write(&mut self) -> HANDLE {
        std::mem::replace(&mut self.input_write, 0)
    }

    pub fn take_output_read(&mut self) -> HANDLE {
        std::mem::replace(&mut self.output_read, 0)
    }
}

/// Create a ConPTY with backing pipes.
///
/// This is public so callers that need lower-level PTY setup can build on the same
/// primitive, although the common entry point is `spawn_conpty_process_as_user`.
#[allow(dead_code)]
pub fn create_conpty(cols: i16, rows: i16) -> Result<ConptyInstance> {
    anyhow::ensure!(
        codex_utils_pty::conpty_supported(),
        "ConPTY is not available on this Windows version"
    );
    let raw = RawConPty::new(cols, rows)?;
    let (pseudoconsole, input_write, output_read) = raw.into_handles();

    Ok(ConptyInstance {
        pseudoconsole: Some(pseudoconsole),
        input_write: input_write.into_raw_handle() as HANDLE,
        output_read: output_read.into_raw_handle() as HANDLE,
        _desktop: None,
    })
}

/// Spawn a process under `h_token` with ConPTY attached.
///
/// This is the main shared ConPTY entry point and is used by both the legacy/direct path
/// and the elevated runner path whenever a PTY-backed sandboxed process is needed.
pub fn spawn_conpty_process_as_user(
    h_token: HANDLE,
    argv: &[String],
    cwd: &Path,
    env_map: &HashMap<String, String>,
    use_private_desktop: bool,
    logs_base_dir: Option<&Path>,
) -> Result<(PROCESS_INFORMATION, ConptyInstance)> {
    anyhow::ensure!(
        codex_utils_pty::conpty_supported(),
        "ConPTY is not available on this Windows version"
    );
    let cmdline_str = argv
        .iter()
        .map(|arg| quote_windows_arg(arg))
        .collect::<Vec<_>>()
        .join(" ");
    let mut cmdline: Vec<u16> = to_wide(&cmdline_str);
    let env_block = make_env_block(env_map);
    let mut si: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
    si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
    si.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
    si.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
    let desktop = LaunchDesktop::prepare(use_private_desktop, logs_base_dir)?;
    si.StartupInfo.lpDesktop = desktop.startup_info_desktop();

    let raw = RawConPty::new(/*cols*/ 80, /*rows*/ 24)?;
    let (pseudoconsole, input_write, output_read) = raw.into_handles();
    let hpc = pseudoconsole.raw_handle() as HANDLE;
    let conpty = ConptyInstance {
        pseudoconsole: Some(pseudoconsole),
        input_write: input_write.into_raw_handle() as HANDLE,
        output_read: output_read.into_raw_handle() as HANDLE,
        _desktop: Some(desktop),
    };
    let mut attrs = ProcThreadAttributeList::new(/*attr_count*/ 1)?;
    attrs.set_pseudoconsole(hpc)?;
    si.lpAttributeList = attrs.as_mut_ptr();

    let mut pi: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    let ok = unsafe {
        CreateProcessAsUserW(
            h_token,
            std::ptr::null(),
            cmdline.as_mut_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            env_block.as_ptr() as *mut c_void,
            to_wide(cwd).as_ptr(),
            &si.StartupInfo,
            &mut pi,
        )
    };
    if ok == 0 {
        let err = unsafe { GetLastError() } as i32;
        return Err(anyhow::anyhow!(
            "CreateProcessAsUserW failed: {} ({}) | cwd={} | cmd={} | env_u16_len={}",
            err,
            format_last_error(err),
            cwd.display(),
            cmdline_str,
            env_block.len()
        ));
    }
    Ok((pi, conpty))
}

// ── ResizePseudoConsole dynamic loading ──────────────────────────────────
//
// `ResizePseudoConsole` is exported by kernel32.dll only on Windows 10 1809+.
// A static `#[link(name = "kernel32")]` import would write the symbol into the
// PE import table and cause the Windows loader to refuse the binary entirely on
// Windows 7 ("The procedure entry point could not be found").
//
// We resolve the function via `GetProcAddress` at runtime. On systems where
// ConPTY is unavailable the lookup returns `None`, and the resize becomes a
// quiet no‑op (the caller is expected to have already avoided the TTY path via
// `conpty_supported()`).

type FnResizePseudoConsole = unsafe extern "system" fn(HANDLE, COORD) -> i32;

static RESIZE_PSEUDO_CONSOLE_FN: OnceLock<Option<FnResizePseudoConsole>> = OnceLock::new();

/// Dynamically resolve and call `ResizePseudoConsole`.
///
/// Returns `S_OK` (0) when ConPTY is not available, so callers that already
/// guard with `conpty_supported()` or use a pipe fallback can call this
/// unconditionally.
pub fn try_resize_pseudoconsole(hpc: HANDLE, size: COORD) -> i32 {
    let func = RESIZE_PSEUDO_CONSOLE_FN.get_or_init(|| unsafe {
        let kernel32 = to_wide("kernel32.dll");
        let h_module = GetModuleHandleW(kernel32.as_ptr());
        if h_module == 0 {
            return None;
        }
        let proc_name = match CString::new("ResizePseudoConsole") {
            Ok(n) => n,
            Err(_) => return None,
        };
        let farproc = GetProcAddress(h_module, proc_name.as_ptr() as *const u8);
        farproc.map(|p| {
            std::mem::transmute::<unsafe extern "system" fn() -> isize, FnResizePseudoConsole>(p)
        })
    });

    match func {
        Some(f) => unsafe { f(hpc, size) },
        None => 0, // S_OK — ConPTY not present, resize is a no-op
    }
}

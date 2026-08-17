use super::*;
use crate::Interface;
use core::ffi::c_void;
use core::marker::PhantomData;
use core::mem::{forget, transmute, transmute_copy};
use core::ptr::null_mut;
use core::sync::atomic::{AtomicPtr, Ordering};

type FnRoGetActivationFactory = unsafe extern "system" fn(
    activatableclassid: *mut core::ffi::c_void,
    iid: *const GUID,
    factory: *mut *mut core::ffi::c_void,
) -> HRESULT;

static RO_GET_ACTIVATION_FACTORY: std::sync::OnceLock<Option<FnRoGetActivationFactory>> =
    std::sync::OnceLock::new();

fn get_ro_activation_factory() -> Option<FnRoGetActivationFactory> {
    *RO_GET_ACTIVATION_FACTORY.get_or_init(|| {
        unsafe fn load_proc(lib: &str, name: &str) -> Option<FnRoGetActivationFactory> {
            let mut lib_buf = alloc::vec::Vec::<u8>::new();
            lib_buf.extend_from_slice(lib.as_bytes());
            lib_buf.push(0);
            let lib_ptr = lib_buf.as_ptr() as *const u8;

            let mut name_buf = alloc::vec::Vec::<u8>::new();
            name_buf.extend_from_slice(name.as_bytes());
            name_buf.push(0);
            let name_ptr = name_buf.as_ptr() as *const u8;

            let module = unsafe {
                LoadLibraryExA(
                    core::mem::transmute(lib_ptr),
                    core::ptr::null_mut(),
                    LOAD_LIBRARY_SEARCH_DEFAULT_DIRS,
                )
            };
            if module.is_null() {
                return None;
            }
            let proc_addr = unsafe {
                GetProcAddress(core::mem::transmute(module), core::mem::transmute(name_ptr))
            };
            if proc_addr.is_none() {
                return None;
            }
            Some(unsafe { core::mem::transmute(proc_addr.unwrap()) })
        }

        unsafe { load_proc("ole32.dll", "RoGetActivationFactory") }
            .or_else(|| unsafe { load_proc("combase.dll", "RoGetActivationFactory") })
    })
}

pub struct FactoryCache<C, I> {
    shared: AtomicPtr<c_void>,
    _c: PhantomData<C>,
    _i: PhantomData<I>,
}

impl<C, I> FactoryCache<C, I> {
    pub const fn new() -> Self {
        Self {
            shared: AtomicPtr::new(null_mut()),
            _c: PhantomData,
            _i: PhantomData,
        }
    }
}

impl<C, I> Default for FactoryCache<C, I> {
    fn default() -> Self {
        Self::new()
    }
}

impl<C: crate::RuntimeName, I: Interface> FactoryCache<C, I> {
    pub fn call<R, F: FnOnce(&I) -> crate::Result<R>>(&self, callback: F) -> crate::Result<R> {
        loop {
            // Attempt to load a previously cached factory pointer.
            let ptr = self.shared.load(Ordering::Relaxed);

            // If a pointer is found, the cache is primed and we're good to go.
            if !ptr.is_null() {
                return callback(unsafe { transmute::<&*mut c_void, &I>(&ptr) });
            }

            // Otherwise, we load the factory the usual way.
            let factory = load_factory::<C, I>()?;

            // If the factory is agile, we can safely cache it.
            if factory.cast::<IAgileObject>().is_ok() {
                if self
                    .shared
                    .compare_exchange_weak(
                        null_mut(),
                        factory.as_raw(),
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    )
                    .is_ok()
                {
                    forget(factory);
                }
            } else {
                // Otherwise, for non-agile factories we simply use the factory
                // and discard after use as it is not safe to cache.
                return callback(&factory);
            }
        }
    }
}

// This is safe because `FactoryCache` only holds agile factory pointers, which are safe to cache and share between threads.
unsafe impl<C, I> Sync for FactoryCache<C, I> {}

/// Attempts to load the factory object for the given WinRT class.
/// This can be used to access COM interfaces implemented on a Windows Runtime class factory.
pub fn load_factory<C: crate::RuntimeName, I: Interface>() -> crate::Result<I> {
    let mut factory: Option<I> = None;
    let name = crate::HSTRING::from(C::NAME);

    let ro_get_activation_factory = match get_ro_activation_factory() {
        Some(f) => f,
        None => {
            return Err(crate::Error::from_hresult(REGDB_E_CLASSNOTREG));
        }
    };

    let code = unsafe {
        let mut get_com_factory = || {
            crate::HRESULT(ro_get_activation_factory(
                transmute_copy(&name),
                &I::IID as *const _ as _,
                &mut factory as *mut _ as *mut _,
            ))
        };
        let mut code = get_com_factory();

        // If RoGetActivationFactory fails because combase hasn't been loaded yet then load combase
        // automatically so that it "just works" for apartment-agnostic code.
        if code == CO_E_NOTINITIALIZED {
            // Win7 兼容性：使用 CoInitializeEx 替代 CoIncrementMTAUsage
            unsafe { CoInitializeEx(core::ptr::null(), 0u32) };

            // Now try a second time to get the activation factory via the OS.
            code = get_com_factory();
        }

        code
    };

    // If this succeeded then return the resulting factory interface.
    if let Some(factory) = factory {
        return Ok(factory);
    }

    // Reg-free activation should only be attempted if the class is not registered.
    // It should not be attempted if the class is registered but fails to activate.
    if code == REGDB_E_CLASSNOTREG {
        // Now attempt to find the factory's implementation heuristically.
        if let Some(i) = search_path(C::NAME, |library| unsafe {
            get_activation_factory(library, &name)
        }) {
            return i.cast();
        }
    }

    Err(crate::Error::from_hresult(code))
}

// Remove the suffix until a match is found appending `.dll\0` at the end
///
/// For example, if the class name is
/// "A.B.TypeName" then the attempted load order will be:
///   1. A.B.dll
///   2. A.dll
fn search_path<F, R>(mut path: &str, mut callback: F) -> Option<R>
where
    F: FnMut(crate::PCSTR) -> crate::Result<R>,
{
    let suffix = b".dll\0";
    let mut library = alloc::vec![0; path.len() + suffix.len()];
    while let Some(pos) = path.rfind('.') {
        path = &path[..pos];
        library.truncate(path.len() + suffix.len());
        library[..path.len()].copy_from_slice(path.as_bytes());
        library[path.len()..].copy_from_slice(suffix);

        if let Ok(r) = callback(crate::PCSTR::from_raw(library.as_ptr())) {
            return Some(r);
        }
    }

    None
}

unsafe fn get_activation_factory(
    library: crate::PCSTR,
    name: &crate::HSTRING,
) -> crate::Result<IGenericFactory> {
    unsafe {
        let function =
            delay_load::<DllGetActivationFactory>(library, crate::s!("DllGetActivationFactory"))
                .ok_or_else(crate::Error::from_thread)?;
        let mut abi = null_mut();
        function(transmute_copy(name), &mut abi).and_then(|| crate::Type::from_abi(abi))
    }
}

unsafe fn delay_load<T>(library: crate::PCSTR, function: crate::PCSTR) -> Option<T> {
    unsafe {
        let library = LoadLibraryExA(
            library.0,
            core::ptr::null_mut(),
            LOAD_LIBRARY_SEARCH_DEFAULT_DIRS,
        );

        if library.is_null() {
            return None;
        }

        let address = GetProcAddress(library, function.0);

        if address.is_some() {
            return Some(core::mem::transmute_copy(&address));
        }

        FreeLibrary(library);
        None
    }
}

type DllGetActivationFactory =
    extern "system" fn(name: *mut c_void, factory: *mut *mut c_void) -> crate::HRESULT;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dll_search() {
        let path = "A.B.TypeName";

        // Test library successfully found
        let mut results = Vec::new();
        let end_result = search_path(path, |library| {
            results.push(unsafe { library.to_string().unwrap() });
            if unsafe { library.as_bytes() } == &b"A.dll"[..] {
                Ok(42)
            } else {
                Err(crate::Error::empty())
            }
        });
        assert!(matches!(end_result, Some(42)));
        assert_eq!(results, vec!["A.B.dll", "A.dll"]);

        // Test library never successfully found
        let mut results = Vec::new();
        let end_result = search_path(path, |library| {
            results.push(unsafe { library.to_string().unwrap() });
            crate::Result::<()>::Err(crate::Error::empty())
        });
        assert!(end_result.is_none());
        assert_eq!(results, vec!["A.B.dll", "A.dll"]);
    }
}

//! C ABI exposed to the Swift host app. See `include/markdown_core.h`.

use core::ffi::{c_char, c_uchar};
use std::ffi::{CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

/// Borrowed view of an embedded web asset. The memory is static; never free it.
#[repr(C)]
pub struct MdAsset {
    pub data: *const c_uchar,
    pub len: usize,
    pub mime: *const c_char,
}

impl MdAsset {
    fn empty() -> Self {
        Self {
            data: core::ptr::null(),
            len: 0,
            mime: core::ptr::null(),
        }
    }
}

/// Looks up a file of the embedded Vue app, falling back to `index.html`.
///
/// # Safety
/// `path` must be a valid NUL terminated string and `out` a valid, writable `MdAsset`.
#[no_mangle]
pub unsafe extern "C" fn md_asset_lookup(path: *const c_char, out: *mut MdAsset) -> bool {
    if out.is_null() {
        return false;
    }
    out.write(MdAsset::empty());

    let Some(path) = (unsafe { borrow_str(path) }) else {
        return false;
    };

    let found = catch_unwind(AssertUnwindSafe(|| crate::assets::lookup(path))).unwrap_or(None);
    let Some(asset) = found else {
        return false;
    };

    out.write(MdAsset {
        data: asset.bytes.as_ptr(),
        len: asset.bytes.len(),
        mime: asset.mime_ptr(),
    });
    true
}

/// Number of files baked into the library. Useful for start-up diagnostics.
#[no_mangle]
pub extern "C" fn md_asset_count() -> usize {
    crate::assets::all().len()
}

/// Renders Markdown to an HTML fragment.
///
/// Returns a newly allocated UTF-8 string that must be released with
/// [`md_string_free`], or NULL if `markdown` is not valid UTF-8.
///
/// # Safety
/// `markdown` must be a valid NUL terminated string.
#[no_mangle]
pub unsafe extern "C" fn md_render(markdown: *const c_char) -> *mut c_char {
    let Some(markdown) = (unsafe { borrow_str(markdown) }) else {
        return core::ptr::null_mut();
    };

    match catch_unwind(AssertUnwindSafe(|| crate::render_markdown(markdown))) {
        Ok(html) => into_c_string(html),
        Err(_) => core::ptr::null_mut(),
    }
}

/// Version string of the core library. Static storage; do not free.
#[no_mangle]
pub extern "C" fn md_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

/// Frees a string returned by [`md_render`].
///
/// # Safety
/// `value` must come from [`md_render`] and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn md_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

pub(crate) unsafe fn borrow_str<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value) }.to_str().ok()
}

pub(crate) fn into_c_string(value: String) -> *mut c_char {
    // Interior NULs cannot survive the C boundary, so drop them rather than fail.
    let sanitized = if value.as_bytes().contains(&0) {
        value.replace('\0', "")
    } else {
        value
    };
    match CString::new(sanitized) {
        Ok(value) => value.into_raw(),
        Err(_) => core::ptr::null_mut(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_through_ffi() {
        let input = CString::new("# hi").unwrap();
        let raw = unsafe { md_render(input.as_ptr()) };
        assert!(!raw.is_null());
        let html = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        unsafe { md_string_free(raw) };
        assert!(html.contains("<h1>hi</h1>"));
    }

    #[test]
    fn render_rejects_null() {
        assert!(unsafe { md_render(core::ptr::null()) }.is_null());
    }

    #[test]
    fn looks_up_index_through_ffi() {
        let path = CString::new("/").unwrap();
        let mut asset = MdAsset::empty();
        assert!(unsafe { md_asset_lookup(path.as_ptr(), &mut asset) });
        assert!(asset.len > 0);
        let mime = unsafe { CStr::from_ptr(asset.mime) }.to_str().unwrap();
        assert_eq!(mime, "text/html; charset=utf-8");
    }

    #[test]
    fn lookup_rejects_null_output() {
        let path = CString::new("/").unwrap();
        assert!(!unsafe { md_asset_lookup(path.as_ptr(), core::ptr::null_mut()) });
    }

    #[test]
    fn exposes_version_and_count() {
        let version = unsafe { CStr::from_ptr(md_version()) }.to_str().unwrap();
        assert_eq!(version, crate::VERSION);
        assert!(md_asset_count() > 0);
    }

    #[test]
    fn string_free_tolerates_null() {
        unsafe { md_string_free(core::ptr::null_mut()) };
    }
}

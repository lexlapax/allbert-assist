pub use allbert_kernel_core::rag::*;

type SqliteExtensionInit = unsafe extern "C" fn(
    *mut rusqlite::ffi::sqlite3,
    *mut *mut std::ffi::c_char,
    *const rusqlite::ffi::sqlite3_api_routines,
) -> std::ffi::c_int;

pub fn sqlite_vec_dependency_probe() -> Result<String, rusqlite::Error> {
    register_sqlite_vec();
    let db = rusqlite::Connection::open_in_memory()?;
    db.query_row("select vec_version()", [], |row| row.get(0))
}

fn register_sqlite_vec() {
    unsafe {
        // SAFETY: sqlite-vec documents registration through sqlite3_auto_extension
        // with its C entrypoint. The function pointer is process-global and
        // rusqlite owns later connection lifetimes.
        let entrypoint = std::mem::transmute::<*const (), SqliteExtensionInit>(
            sqlite_vec::sqlite3_vec_init as *const (),
        );
        rusqlite::ffi::sqlite3_auto_extension(Some(entrypoint));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sqlite_vec_registers_with_bundled_rusqlite() {
        let version = sqlite_vec_dependency_probe().expect("sqlite-vec should register");
        assert!(
            version.starts_with("v0.") || version.starts_with("0."),
            "unexpected sqlite-vec version {version}"
        );
    }
}

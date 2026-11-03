//! Keeps the shim alive when the console delivers a control event.

#[cfg(windows)]
mod imp {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn SetConsoleCtrlHandler(
            handler: Option<unsafe extern "system" fn(u32) -> i32>,
            add: i32,
        ) -> i32;
    }

    // The event also reaches the child, which shares this console. Returning
    // TRUE only prevents this process from terminating before the child exits.
    unsafe extern "system" fn swallow(_: u32) -> i32 {
        1
    }

    pub fn ignore() {
        unsafe { SetConsoleCtrlHandler(Some(swallow), 1) };
    }
}

#[cfg(not(windows))]
mod imp {
    pub fn ignore() {}
}

pub use imp::ignore;

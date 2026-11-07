//! A minimal Windows launcher. It resolves `_ref\<its own file name>` as a
//! symbolic link and runs the link target.

use std::env;
use std::fs;
use std::process::{self, Command};

mod ctrl;

/// Runs the shim. Never returns.
pub fn run() -> ! {
    // Failures must stay silent, including panic messages.
    std::panic::set_hook(Box::new(|_| {}));
    ctrl::ignore();

    let exe = env::current_exe().unwrap();
    let link = exe
        .parent()
        .unwrap()
        .join("_ref")
        .join(exe.file_name().unwrap());
    let target = fs::read_link(link).unwrap();

    assert!(target.is_absolute());

    let status = Command::new(&target)
        .args(env::args_os().skip(1))
        .status()
        .unwrap();

    process::exit(status.code().unwrap());
}

//! A transparent launcher for Windows.
//!
//! The executable resolves `<its own directory>\.ref\<its own file name>` as a
//! symbolic link and launches the link target with the same arguments,
//! environment, standard handles, and working directory. It then exits with
//! the child's exit code.

use std::env;
use std::fs;
use std::process::{self, Command};

mod ctrl;

/// Runs the shim. Never returns.
///
/// Errors are contract violations or launch failures and surface as panics:
/// the program has no output of its own.
pub fn run() -> ! {
    ctrl::ignore();

    let exe = env::current_exe().unwrap();
    let link = exe
        .parent()
        .unwrap()
        .join(".ref")
        .join(exe.file_name().unwrap());
    let target = fs::read_link(link).unwrap();

    assert!(target.is_absolute());

    let status = Command::new(&target)
        .args(env::args_os().skip(1))
        .status()
        .unwrap();

    process::exit(status.code().unwrap());
}

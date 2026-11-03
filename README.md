# wshim

A minimal Windows launcher that keeps one directory on `PATH` while each
command resolves to an absolute target outside that directory.

```
C:\bin\
  python.exe          hard link to wshim-c.exe
  node.exe            hard link to wshim-c.exe
  code.exe            hard link to wshim-w.exe
  .ref\
    python.exe        symbolic link -> C:\Python312\python.exe
    node.exe          symbolic link -> C:\Program Files\nodejs\node.exe
    code.exe          symbolic link -> C:\Program Files\Microsoft VS Code\Code.exe
```

`<dir>\<name>.exe` is the shim. It reads `<dir>\.ref\<name>.exe`, requires a
symbolic link, and launches the link target. The reference name is the shim's
file name including its extension.

## Contract

- The `.ref` entry must be a symbolic link. A copy or hard link there is a
  contract violation and fails when the link is read.
- The link target must be absolute (`Path::is_absolute`), otherwise the shim
  panics. The target is not checked for existence; `CreateProcess` reports that.
- Arguments, environment, standard handles and the caller's working directory
  are inherited. Arguments are rebuilt with the standard CRT-compatible
  quoting, so the child sees the same argument values.
- The child's `argv[0]`, `GetModuleFileName`, DLL application directory and
  relative resource lookup all refer to the target path.
- The shim waits and exits with the child's exit code, including negative and
  crash codes.
- The shim produces no output of its own. Failures panic.

## Console and GUI variants

`wshim-c` is a console-subsystem image and `wshim-w` is a GUI-subsystem image.
They share the same library; the entry points differ only in the subsystem
attribute.

Use `wshim-c` for console programs. When the caller has a console, the child
inherits it, `cmd` waits for the child, and Ctrl+C reaches both processes.

Use `wshim-w` for GUI programs. No console is attached. From an interactive
command prompt, `cmd` does not wait for a GUI-subsystem image. Inside a batch
script or a `cmd /c` command line, `cmd` waits for GUI applications, so it also
waits for `wshim-w`; that matches launching the GUI target directly. Do not launch a console program
through `wshim-w`: the child will allocate its own console window.

## Ctrl+C

The shim installs a console control handler before creating the child and
returns TRUE for every event. The console delivers Ctrl+C and Ctrl+Break to
every process attached to it, so the child still receives them; returning TRUE
only keeps the shim alive until the child exits.

`SetConsoleCtrlHandler(NULL, TRUE)` is deliberately not used: the "ignore
Ctrl+C" attribute is inherited by child processes, which would disable Ctrl+C
for the program being launched.

Closing the console terminates both processes. The shim does not use a job
object, so a child can outlive a shim that was killed externally.

## Build

```
cargo build --release
```

This produces `target\release\wshim-c.exe` and `target\release\wshim-w.exe`.
Cross-compiling from Linux with the GNU target works with
`x86_64-w64-mingw32-gcc`.

The release profile uses `panic = "abort"`, speed optimization, fat LTO and one
codegen unit. The crate has no dependencies. The shim's latency is dominated by
process creation and filesystem calls, so the optimization level is not
expected to be measurable end to end.

The profile leaves `strip` at Cargo's default (`debuginfo`), so debug sections
are removed without a post-link tool. The symbol table remains; strip the PE
after linking if distribution size matters.

`.cargo/config.toml` enables the static CRT (`+crt-static`) for the Windows
targets. With MSVC this removes the `VCRUNTIME140.dll` / UCRT dependency, so the
shim does not require the Visual C++ Redistributable. With GNU the imports stay
`msvcrt.dll` plus system DLLs; `msvcrt.dll` ships with Windows. Static CRT has a
negligible effect on launch latency; its value is removing a startup
dependency. The trade-offs are a slightly larger image and CRT security fixes
that arrive only on rebuild. The crate has no dependencies, proc macros, or
dylibs, so `+crt-static` has no known conflict.

## Managing a shim directory

- Create the shim as a hard link to the matching variant when both paths are on
  one volume; otherwise copy. Hard links share one image, so updating the
  variant requires recreating every link.
- Create `.ref\<name>.exe` as a file symbolic link with an absolute target.
  Creating symbolic links requires Developer Mode or
  `SeCreateSymbolicLinkPrivilege`, and `.ref` must be on a filesystem that
  supports reparse points, normally NTFS.
- Choose the variant from the target's PE subsystem: `3` is console, `2` is
  GUI.
- Validate the link when creating it; the shim intentionally has no fallback.

## Limits

- `CreateProcess` does not elevate. A target whose manifest requests
  administrator rights fails with error 740. Use a shell-level elevation path,
  or do not shim such targets.
- `.ref` links are absolute by contract, so moving the shim directory requires
  recreating them.
- The child sees the target path as `argv[0]`. Programs that dispatch on the
  invoked name (busybox-style) are not supported.
- A target ending in `.bat` or `.cmd` is launched through `cmd.exe` by Rust's
  standard library, which re-parses its arguments. Prefer executable targets.
- Each invocation adds one process creation. The measured latency is dominated
  by `CreateProcess`; the shim itself only calls `GetModuleFileName`, reads one
  reparse point, and forwards arguments.

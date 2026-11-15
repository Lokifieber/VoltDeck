use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;
use std::process::Command;

#[link(name = "kernel32")]
extern "system" {
    fn GetSystemDirectoryW(buffer: *mut u16, length: u32) -> u32;
}

pub fn powershell() -> Result<Command, String> {
    let mut buffer = vec![0; 32768];
    // Windows writes at most the supplied number of UTF-16 code units.
    let length = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if length == 0 || length >= buffer.len() {
        return Err("Windows-Systemordner konnte nicht ermittelt werden.".into());
    }
    let system = PathBuf::from(OsString::from_wide(&buffer[..length]));
    let root = system.parent().ok_or("Windows-Systemordner fehlt.")?;
    let shell_home = system.join(r"WindowsPowerShell\v1.0");
    let mut command = Command::new(shell_home.join("powershell.exe"));
    command
        .current_dir(&system)
        .env("PATH", &system)
        .env("SystemRoot", root)
        .env("windir", root)
        .env("PSModulePath", shell_home.join("Modules"))
        .env_remove("COR_ENABLE_PROFILING")
        .env_remove("COR_PROFILER")
        .env_remove("COR_PROFILER_PATH")
        .env_remove("COR_PROFILER_PATH_32")
        .env_remove("COR_PROFILER_PATH_64")
        .env_remove("DEVPATH")
        .env_remove("VOLTDECK_ONLINE")
        .env_remove("VOLTDECK_PORTABLE_DATA")
        .env_remove("VOLTDECK_RESTORE_POINT")
        .env_remove("VOLTDECK_REQUIRE_CACHE")
        .env_remove("VOLTDECK_PROTECT_CRITICAL")
        .env_remove("VOLTDECK_VERIFIED_BACKUP")
        .args(["-NoLogo", "-NoProfile", "-NonInteractive"]);
    Ok(command)
}

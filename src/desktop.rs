#![windows_subsystem = "windows"]

use std::env;
use std::io::Write;
use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

fn main() {
    if let Err(error) = launch() {
        let message: Vec<u16> = error.encode_utf16().chain(Some(0)).collect();
        let title: Vec<u16> = "VoltDeck".encode_utf16().chain(Some(0)).collect();
        // Both buffers are null terminated and live until the dialog closes.
        unsafe { MessageBoxW(0, message.as_ptr(), title.as_ptr(), 0x10) };
    }
}

#[link(name = "user32")]
extern "system" {
    fn MessageBoxW(window: isize, text: *const u16, caption: *const u16, flags: u32) -> i32;
}

fn launch() -> Result<(), String> {
    let root = env::var_os("SystemRoot").ok_or("Windows-Systemordner fehlt.")?;
    let exe = env::current_exe().map_err(|error| error.to_string())?;
    let app_directory = exe.parent().ok_or("Programmordner fehlt.")?;
    let shell = Path::new(&root).join(r"System32\WindowsPowerShell\v1.0\powershell.exe");
    let script = concat!(
        "$backend = {\n",
        include_str!("windows.ps1"),
        "\n}\n[xml] $layout = @'\n",
        include_str!("desktop.xaml"),
        "\n'@\n$english = @'\n",
        include_str!("locales/en.json"),
        "\n'@\n$additionalLocales = @'\n",
        include_str!("locales/additional.json"),
        "\n'@\n$taskbarSource = @'\n",
        include_str!("taskbar.cs"),
        "\n'@\n",
        include_str!("settings.ps1"),
        "\n",
        include_str!("gaming.ps1"),
        "\n",
        include_str!("history-ui.ps1"),
        "\n",
        include_str!("desktop.ps1")
    );
    let open_boost = env::args_os().nth(1).is_some_and(|arg| arg == "--boost");
    let mut command = Command::new(shell);
    command.env_remove("VOLTDECK_PORTABLE_DATA");
    if app_directory.join("portable.flag").is_file() {
        command.env("VOLTDECK_PORTABLE_DATA", app_directory.join("data"));
    }
    let mut child = command
        .args([
            "-NoLogo", "-NoProfile", "-NonInteractive", "-STA", "-Command",
            "[Console]::InputEncoding = [Text.Encoding]::UTF8; [Console]::OutputEncoding = [Text.Encoding]::UTF8; & ([scriptblock]::Create([Console]::In.ReadToEnd()))",
        ])
        .env("DRIVER_TOOL_EXE", exe)
        .env("DRIVER_TOOL_OPEN_BOOST", if open_boost { "1" } else { "0" })
        .creation_flags(0x08000000) // CREATE_NO_WINDOW
        .stdin(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Die Oberfläche konnte nicht gestartet werden. {error}"))?;
    let write_result = child.stdin.take().expect("piped stdin").write_all(script.as_bytes());
    let output = child.wait_with_output().map_err(|error| error.to_string())?;
    write_result.map_err(|error| error.to_string())?;
    if output.status.success() {
        return Ok(());
    }
    Err(format!(
        "Fehler beim Starten der Oberfläche.\n{}",
        String::from_utf8_lossy(&output.stderr).trim()
    ))
}

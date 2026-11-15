use std::env;
use std::ffi::OsStr;
use std::io::Write;
use std::process::{ExitCode, Stdio};

#[cfg(windows)]
mod windows_shell;

const HELP: &str = "VoltDeck für Windows

  driver-tool inventory                          Installierte Treiber anzeigen
  driver-tool problems                           Geräte mit Fehlercode anzeigen
  driver-tool scan --online                      Verfügbare Treiberupdates suchen
  driver-tool prepare <ID> <Revision> --accept-eula --online
                                                 Update herunterladen und prüfen (Admin)
  driver-tool install <ID> <Revision> --accept-eula [--restore-point] [--require-cache] --online
                                                 Gewähltes Update installieren (Admin)
  driver-tool backup <neuer Ordner>               Drittanbieter-Treiber exportieren (Admin)
  driver-tool verify-backup <Ordner>              SHA-256-Manifest prüfen
  driver-tool diagnostics <Ordner>               Offline-Diagnose exportieren

ID und Revision stehen in der Ausgabe von scan. --accept-eula akzeptiert
die Lizenzbedingungen des gewählten Updates. --online erlaubt Windows Update
für diesen Befehl. Der konfigurierte Dienst kann Geräte- und Konfigurationsdaten verarbeiten.";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let mut args: Vec<_> = env::args_os().skip(1).collect();
    let online = args.last().is_some_and(|arg| arg == "--online");
    if online {
        args.pop();
    }
    let action = args.first().and_then(|arg| arg.to_str());
    if args.is_empty() || matches!((action, args.len()), (Some("--help" | "-h"), 1)) {
        println!("{HELP}");
        return Ok(());
    }
    let uses_windows_update = matches!(action, Some("scan" | "prepare" | "install"));
    if uses_windows_update && !online {
        return Err("Windows-Update-Zugriff ist aus. Hänge bei Bedarf --online an.".into());
    }

    #[cfg(not(windows))]
    let mut command = Err::<std::process::Command, _>("Dieses Tool benötigt Windows.")?;
    #[cfg(windows)]
    let mut command = windows_shell::powershell()?;

    match (action, args.len()) {
        (Some("inventory" | "problems" | "scan"), 1) => {}
        (Some("backup" | "verify-backup" | "diagnostics"), 2) if !args[1].is_empty() => {
            let path = std::path::absolute(&args[1]).map_err(|error| error.to_string())?;
            command.env("DRIVER_TOOL_BACKUP", path);
            command.env("VOLTDECK_VERIFIED_BACKUP", "1");
        }
        (Some("prepare" | "install"), len @ 4..=6)
            if args[3] == OsStr::new("--accept-eula")
                && (action == Some("install") || len == 4) =>
        {
            let id = args[1].to_str().filter(|id| is_update_id(id));
            let id = id.ok_or("Ungültige Update-ID. Übernimm die ID aus scan.")?;
            let revision = args[2]
                .to_str()
                .and_then(|revision| revision.parse::<u32>().ok())
                .filter(|revision| *revision > 0 && *revision <= i32::MAX as u32)
                .ok_or("Ungültige Revision. Übernimm die Revision aus scan.")?;
            command.env("DRIVER_TOOL_ID", id);
            command.env("DRIVER_TOOL_REVISION", revision.to_string());
            for flag in &args[4..] {
                match flag.to_str() {
                    Some("--restore-point") => command.env("VOLTDECK_RESTORE_POINT", "1"),
                    Some("--require-cache") => command.env("VOLTDECK_REQUIRE_CACHE", "1"),
                    _ => return Err(format!("Ungültiger Aufruf.\n\n{HELP}")),
                };
            }
        }
        _ => return Err(format!("Ungültiger Aufruf.\n\n{HELP}")),
    }

    if uses_windows_update {
        command.env("VOLTDECK_ONLINE", "1");
    }
    let mut child = command
        .env("DRIVER_TOOL_ACTION", &args[0])
        .args([
            "-Command",
            "$env:PSModulePath = Join-Path $PSHOME 'Modules'; [Console]::InputEncoding = [Text.Encoding]::UTF8; & ([scriptblock]::Create([Console]::In.ReadToEnd()))",
        ])
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Windows PowerShell konnte nicht gestartet werden. {error}"))?;
    let write_result = child.stdin.take().expect("piped stdin").write_all(
        concat!(include_str!("local-paths.ps1"), "\n", include_str!("windows.ps1")).as_bytes(),
    );
    let status = child.wait().map_err(|error| error.to_string())?;
    write_result.map_err(|error| error.to_string())?;
    if !status.success() {
        return Err(format!("Vorgang fehlgeschlagen ({status})."));
    }
    Ok(())
}

fn is_update_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

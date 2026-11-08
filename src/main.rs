use std::env;
use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, ExitCode};

const HELP: &str = "VoltDeck für Windows

  driver-tool inventory                          Installierte Treiber anzeigen
  driver-tool problems                           Geräte mit Fehlercode anzeigen
  driver-tool scan                               Verfügbare Treiberupdates suchen
  driver-tool install <ID> <Revision> --accept-eula
                                                 Gewähltes Update installieren (Admin)
  driver-tool backup <neuer Ordner>               Drittanbieter-Treiber exportieren (Admin)

ID und Revision stehen in der Ausgabe von scan. --accept-eula akzeptiert
die Lizenzbedingungen des gewählten Updates. Windows kann einen Neustart anfordern.";

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
    let args: Vec<_> = env::args_os().skip(1).collect();
    let action = args.first().and_then(|arg| arg.to_str());
    if args.is_empty() || matches!((action, args.len()), (Some("--help" | "-h"), 1)) {
        println!("{HELP}");
        return Ok(());
    }

    let system_root = env::var_os("SystemRoot").ok_or("Dieses Tool benötigt Windows.")?;
    let powershell = Path::new(&system_root).join(r"System32\WindowsPowerShell\v1.0\powershell.exe");
    let mut command = Command::new(powershell);
    command.args(["-NoLogo", "-NoProfile", "-NonInteractive", "-Command"]);
    command.arg(include_str!("windows.ps1"));

    match (action, args.len()) {
        (Some("inventory" | "problems" | "scan"), 1) => {}
        (Some("backup"), 2) if !args[1].is_empty() => {
            let path = std::path::absolute(&args[1]).map_err(|error| error.to_string())?;
            command.env("DRIVER_TOOL_BACKUP", path);
        }
        (Some("install"), 4) if args[3] == OsStr::new("--accept-eula") => {
            let id = args[1].to_str().filter(|id| is_update_id(id));
            let id = id.ok_or("Ungültige Update-ID. Übernimm die ID aus scan.")?;
            let revision = args[2]
                .to_str()
                .and_then(|revision| revision.parse::<u32>().ok())
                .filter(|revision| *revision > 0 && *revision <= i32::MAX as u32)
                .ok_or("Ungültige Revision. Übernimm die Revision aus scan.")?;
            command.env("DRIVER_TOOL_ID", id);
            command.env("DRIVER_TOOL_REVISION", revision.to_string());
        }
        _ => return Err(format!("Ungültiger Aufruf.\n\n{HELP}")),
    }

    let status = command
        .env("DRIVER_TOOL_ACTION", &args[0])
        .status()
        .map_err(|error| format!("Windows PowerShell konnte nicht gestartet werden. {error}"))?;
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

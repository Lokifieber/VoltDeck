$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Bitte das Terminal als Administrator starten.'
    }
}

function Find-DriverUpdates($session, [string] $filter) {
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'$filter")
    if ($result.ResultCode -ne 2) {
        throw "Die Updatesuche wurde nicht vollstaendig abgeschlossen (Status $($result.ResultCode))."
    }
    return $result
}

function Format-DriverDate($date) {
    if ($date -is [datetime] -and $date.Year -ge 1990) { return $date.ToString('dd.MM.yyyy') }
    return '—'
}

function Get-DriverCategory([string] $class) {
    switch -Regex ($class) {
        '^Display$' { 'Graphics' }
        '^(Media|AudioEndpoint|AudioProcessingObject)$' { 'Audio' }
        '^(Net|NetService|NetTrans|NetClient|Bluetooth)$' { 'Network' }
        '^(System|Processor|Firmware)$' { 'Chipset' }
        '^(DiskDrive|SCSIAdapter|HDC|Volume|Storage|StorageController)$' { 'Storage' }
        '^(Printer|PrintQueue|Image)$' { 'Print / Imaging' }
        '^USB' { 'USB' }
        default { 'Other' }
    }
}

function Get-DeviceInventory {
    $drivers = @{}
    foreach ($driver in Get-CimInstance Win32_PnPSignedDriver) {
        if ($driver.DeviceID) { $drivers[$driver.DeviceID] = $driver }
    }
    foreach ($device in Get-CimInstance Win32_PnPEntity -Filter 'Present = TRUE') {
        if (-not $device.DeviceID) { continue }
        $driver = $drivers[$device.DeviceID]
        $code = $device.ConfigManagerErrorCode
        $problem = switch ($code) {
            22 { 'Deaktiviert' }
            28 { 'Treiber fehlt' }
            0 { '' }
            default { if ($null -ne $code) { "Windows-Code $code" } }
        }
        $inf = $driver.InfName
        $class = if ($driver.DeviceClass) { $driver.DeviceClass } else { $device.PNPClass }
        [pscustomobject] @{
            Treiber = $(if ($device.Name) { $device.Name } else { $device.DeviceID })
            Klasse = $class
            Category = Get-DriverCategory $class
            DeviceId = $device.DeviceID
            HardwareIds = @($device.HardwareID | Where-Object { $_ })
            CompatibleIds = @($device.CompatibleID | Where-Object { $_ })
            Manufacturer = $device.Manufacturer
            Provider = $driver.DriverProviderName
            Version = $driver.DriverVersion
            Datum = Format-DriverDate $driver.DriverDate
            Datumsart = 'Installierter Treiber'
            Inf = $inf
            Signer = $driver.Signer
            Signed = $driver.IsSigned
            Inbox = [bool] ($inf -and $inf -notmatch '^oem\d+\.inf$')
            Problem = $problem
            ProblemCode = $code
            Source = $(if ($inf) { if ($inf -match '^oem\d+\.inf$') { 'Driver Store · OEM-Paket' } else { 'Driver Store · In-Box' } })
            Details = (@($driver.DriverProviderName, $driver.DriverVersion, $inf, $problem) | Where-Object { $_ }) -join ' · '
        }
    }
}

function Get-BackupHashes([string] $root) {
    $directory = Get-Item -LiteralPath $root -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Bitte einen regulären Sicherungsordner auswählen.'
    }
    if (Get-ChildItem -LiteralPath $directory.FullName -Directory -Recurse -Force -Attributes ReparsePoint | Select-Object -First 1) {
        throw 'Die Sicherung enthält einen verknüpften Ordner.'
    }
    $prefix = $directory.FullName.TrimEnd('\') + '\'
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -Force) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $file.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Die Sicherung enthält einen Verknüpfungspunkt.'
            }
            $relative = $file.FullName.Substring($prefix.Length)
            if ($relative -eq 'voltdeck-sha256.json') { continue }
            $stream = [IO.File]::OpenRead($file.FullName)
            try { $hash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '') }
            finally { $stream.Dispose() }
            [pscustomobject] @{ Path = $relative; SHA256 = $hash }
        }
    } finally { $sha256.Dispose() }
}

function Write-BackupManifest($root) {
    $hashes = @(Get-BackupHashes $root)
    if (-not ($hashes.Path -match '\.inf$')) { throw 'Im Export wurde kein Treiberpaket gefunden.' }
    $manifest = Join-Path $root 'voltdeck-sha256.json'
    ConvertTo-Json -InputObject $hashes -Depth 3 | Set-Content -LiteralPath $manifest -Encoding UTF8
    Test-BackupManifest $root
}

function Test-BackupManifest($root) {
    $manifest = Join-Path $root 'voltdeck-sha256.json'
    $manifestFile = Get-Item -LiteralPath $manifest
    if ($manifestFile.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Das Manifest ist ein Verknüpfungspunkt.' }
    $parsed = Get-Content -LiteralPath $manifest -Encoding UTF8 -Raw | ConvertFrom-Json
    $expected = @($parsed | Where-Object { $null -ne $_ })
    $actual = @{}
    foreach ($entry in Get-BackupHashes $root) { $actual.Add($entry.Path, $entry.SHA256) }
    $seen = @{}
    foreach ($entry in $expected) {
        if (-not $entry.Path -or $seen.ContainsKey($entry.Path) -or $entry.SHA256 -notmatch '^[0-9a-fA-F]{64}$' -or
            -not $actual.ContainsKey($entry.Path) -or $actual[$entry.Path] -ne $entry.SHA256) {
            throw "Integritätsprüfung fehlgeschlagen: $($entry.Path)"
        }
        $seen.Add($entry.Path, $true)
    }
    if (-not $expected.Count -or $expected.Count -ne $actual.Count) { throw 'Das Manifest stimmt nicht mit dem Sicherungsordner überein.' }
    Write-Host "$($actual.Count) Dateien per SHA-256 geprüft."
}

function Export-DriverDiagnostics($destination) {
    Assert-LocalPath $destination
    $devices = @(Get-DeviceInventory)
    $os = Get-CimInstance Win32_OperatingSystem
    $historyRoot = if ($env:VOLTDECK_PORTABLE_DATA) { Join-Path $env:VOLTDECK_PORTABLE_DATA 'history' } else {
        Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DriverTool\history'
    }
    try { Assert-LocalPath $historyRoot } catch { $historyRoot = $null }
    $activity = @(if ($historyRoot -and (Test-Path -LiteralPath $historyRoot)) {
        Get-ChildItem -LiteralPath $historyRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 100 |
            ForEach-Object {
                try {
                    $recordPath = Join-Path $_.FullName 'entry.json'
                    Assert-LocalPath $recordPath
                    $record = Get-Content -LiteralPath $recordPath -Encoding UTF8 -Raw | ConvertFrom-Json
                    $record | Select-Object Name, Kind, Time, Result, RestorePoint, Error
                } catch { Write-Verbose $_.Exception.Message }
            }
    })
    $report = [ordered] @{
        ExportedAt = [datetimeoffset]::Now.ToString('o')
        Windows = [ordered] @{ Edition = $os.Caption; Version = $os.Version; Build = $os.BuildNumber; Architecture = $os.OSArchitecture }
        Drivers = $devices
        Problems = @($devices | Where-Object Problem)
        VoltDeckHistory = $activity
    }
    $json = ConvertTo-Json -InputObject $report -Depth 10
    $safe = [Net.WebUtility]::HtmlEncode($json)
    $html = '<!doctype html><html lang="en"><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''"><title>VoltDeck diagnostics</title><style>body{font:16px system-ui;margin:2rem;max-width:100rem}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#eef2f7;padding:1rem;border-radius:12px}</style><h1>VoltDeck diagnostics</h1><pre>' + $safe + '</pre></html>'
    New-Item -Path $destination -ItemType Directory -ErrorAction Stop | Out-Null
    foreach ($reportFile in @(@('diagnostics.json', $json), @('diagnostics.html', $html))) {
        $stream = [IO.File]::Open((Join-Path $destination $reportFile[0]), [IO.FileMode]::CreateNew)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        try { $writer.Write($reportFile[1]) } finally { $writer.Dispose() }
    }
    Write-Host "Diagnosepaket: $destination"
}

function Get-InstalledDriverIndex {
    $byDevice = @{}
    foreach ($driver in Get-CimInstance Win32_PnPSignedDriver) {
        if ($driver.DeviceID) { $byDevice[$driver.DeviceID] = $driver }
    }
    $byHardware = @{}
    foreach ($device in Get-CimInstance Win32_PnPEntity -Filter 'Present = TRUE') {
        if (-not $device.DeviceID -or -not $byDevice.ContainsKey($device.DeviceID)) { continue }
        $driver = $byDevice[$device.DeviceID]
        $match = [pscustomobject] @{
            Name = $driver.DeviceName; Provider = $driver.DriverProviderName; Version = $driver.DriverVersion
            Date = Format-DriverDate $driver.DriverDate; Inf = $driver.InfName; DeviceId = $device.DeviceID
            Signer = $driver.Signer; Signed = $driver.IsSigned; Manufacturer = $device.Manufacturer
            HardwareIds = @($device.HardwareID | Where-Object { $_ }); CompatibleIds = @($device.CompatibleID | Where-Object { $_ })
            ProblemCode = $device.ConfigManagerErrorCode
        }
        foreach ($id in (@($device.HardwareID) + @($device.CompatibleID) | Where-Object { $_ } | Select-Object -Unique)) {
            if (-not $byHardware.ContainsKey($id)) { $byHardware[$id] = [Collections.Generic.List[object]]::new() }
            $byHardware[$id].Add($match)
        }
    }
    return $byHardware
}

function Get-DriverComparison($update, $index) {
    $installed = @()
    $hardware = $null
    try { $hardware = $update.DriverHardwareID } catch { Write-Verbose $_.Exception.Message }
    if ($hardware -and $index.ContainsKey($hardware)) { $installed = $index[$hardware].ToArray() }
    $version = [regex]::Match($update.Title, '(?:^|\s)(\d+(?:\.\d+){2,})\s*$').Groups[1].Value
    $date = '—'
    try { $date = Format-DriverDate $update.DriverVerDate } catch { Write-Verbose $_.Exception.Message }
    $provider = $null
    try { $provider = $update.DriverProvider } catch { Write-Verbose $_.Exception.Message }
    return @{ Installed = $installed; TargetVersion = $version; TargetDate = $date; TargetProvider = $provider }
}

function New-DriverHistory($name, $kind, $comparison) {
    $root = if ($env:VOLTDECK_PORTABLE_DATA) { Join-Path $env:VOLTDECK_PORTABLE_DATA 'history' } else {
        Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DriverTool\history'
    }
    $directory = Join-Path $root ([guid]::NewGuid().ToString('N'))
    Assert-LocalPath $directory
    [void] [IO.Directory]::CreateDirectory($directory)
    $record = @{ Name = $name; Kind = $kind; Time = [datetimeoffset]::Now.ToString('o'); Result = 'running'; Comparison = $comparison; Backups = @(); Error = ''; Source = '' }
    Write-DriverHistory $directory $record
    return @{ Directory = $directory; Record = $record }
}

function Write-DriverHistory($directory, $record) {
    $file = Join-Path $directory 'entry.json'
    $temporary = Join-Path $directory 'entry.tmp'
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $record -Depth 8), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $file) { [IO.File]::Replace($temporary, $file, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $file) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function New-VerifiedRestorePoint {
    $description = 'VoltDeck ' + [guid]::NewGuid().ToString('N')
    Checkpoint-Computer -Description $description -RestorePointType DEVICE_DRIVER_INSTALL -ErrorAction Stop
    $point = Get-ComputerRestorePoint -ErrorAction Stop | Where-Object Description -EQ $description | Select-Object -First 1
    if (-not $point) { throw 'Windows hat keinen neuen Wiederherstellungspunkt bestätigt. Die Installation wurde angehalten.' }
    Write-Host "Wiederherstellungspunkt: $($point.SequenceNumber)"
    return $point.SequenceNumber
}

function Invoke-LoggedUpdate($session, $update, [bool] $acceptLicense) {
    $index = @{}
    try { $index = Get-InstalledDriverIndex } catch { Write-Verbose $_.Exception.Message }
    $comparison = Get-DriverComparison $update $index
    $history = New-DriverHistory $update.Title 'update' $comparison
    try {
        $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
        foreach ($inf in @($comparison.Installed | ForEach-Object Inf | Where-Object { $_ -match '^oem\d+\.inf$' } | Select-Object -Unique)) {
            $backup = Join-Path $history.Directory $inf
            try {
                [void] [IO.Directory]::CreateDirectory($backup)
                & $pnputil /export-driver $inf $backup | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $history.Record.Backups += @(Get-ChildItem -LiteralPath $backup -Filter '*.inf' -File -Recurse | ForEach-Object {
                        Join-Path $inf $_.FullName.Substring($backup.Length + 1)
                    })
                }
            } catch { Write-Warning $_.Exception.Message }
        }
        Write-DriverHistory $history.Directory $history.Record
        $reboot = Invoke-DriverInstallation $session $update $acceptLicense $history
        $history.Record.Result = if ($reboot) { 'reboot' } else { 'success' }
        return $reboot
    } catch {
        $history.Record.Result = 'failed'
        $history.Record.Error = $_.Exception.Message
        throw
    } finally {
        try { Write-DriverHistory $history.Directory $history.Record } catch { Write-Warning $_.Exception.Message }
    }
}

function Restore-DriverPackage {
    Assert-Administrator
    Assert-LocalPath $env:DRIVER_TOOL_BACKUP
    $file = Get-Item -LiteralPath $env:DRIVER_TOOL_BACKUP
    if ($file.PSIsContainer -or $file.Extension -ne '.inf') { throw 'Bitte eine INF-Datei aus der Sicherung auswählen.' }
    $history = New-DriverHistory $file.Name 'restore' $null
    $history.Record.Source = $file.FullName
    try {
        $backupRoot = $file.Directory
        while ($backupRoot) {
            if (Test-Path -LiteralPath (Join-Path $backupRoot.FullName 'voltdeck-sha256.json') -PathType Leaf) {
                Test-BackupManifest $backupRoot.FullName
                break
            }
            $backupRoot = $backupRoot.Parent
        }
        if ($env:VOLTDECK_RESTORE_POINT -eq '1') {
            $history.Record.RestorePoint = New-VerifiedRestorePoint
            Write-DriverHistory $history.Directory $history.Record
        }
        $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
        & $pnputil /add-driver $file.FullName /install
        if ($LASTEXITCODE -notin 0, 3010) { throw "Wiederherstellung fehlgeschlagen (Code $LASTEXITCODE)." }
        $history.Record.Result = if ($LASTEXITCODE -eq 3010) { 'reboot' } else { 'imported' }
        if ($LASTEXITCODE -eq 3010) { Write-Host 'Windows meldet, dass ein Neustart erforderlich ist.' }
    } catch {
        $history.Record.Result = 'failed'
        $history.Record.Error = $_.Exception.Message
        throw
    } finally {
        try { Write-DriverHistory $history.Directory $history.Record } catch { Write-Warning $_.Exception.Message }
    }
}

function Install-DriverUpdate {
    Assert-Administrator
    $id = ([guid] $env:DRIVER_TOOL_ID).ToString('D')
    $revision = [int] $env:DRIVER_TOOL_REVISION
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'VoltDeck'
    $result = Find-DriverUpdates $session " and UpdateID='$id' and RevisionNumber=$revision"
    if ($result.Updates.Count -ne 1) {
        throw 'Das gewaehlte Update ist nicht mehr verfuegbar. Bitte erneut scan ausfuehren.'
    }

    $update = $result.Updates.Item(0)
    if ($env:DRIVER_TOOL_ACTION -eq 'prepare') {
        $packages = Get-UpdateDownload $session $update $true
        Write-Host 'Windows Update bestätigt den vollständigen Download. Installation steht aus.'
        return
    }
    Invoke-LoggedUpdate $session $update $true
}

function Get-UpdateDownload($session, $update, [bool] $acceptLicense) {
    if ($update.InstallationBehavior.CanRequestUserInput) {
        throw 'Das Update erfordert Interaktion. Bitte ueber die Windows-Einstellungen installieren.'
    }
    Write-Host "Update: $($update.Title)"
    if (-not $update.EulaAccepted) {
        if (-not $acceptLicense) { throw 'Dieses Update erfordert eine Lizenzbestätigung.' }
        $update.AcceptEula()
    }
    $updates = New-Object -ComObject Microsoft.Update.UpdateColl
    [void] $updates.Add($update)

    if (-not $update.IsDownloaded) {
        Write-Host 'Treiber wird heruntergeladen ...'
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $updates
        $download = $downloader.Download()
        if ($download.ResultCode -ne 2 -or -not $update.IsDownloaded) {
            $detail = $download.GetUpdateResult(0)
            throw ('Download fehlgeschlagen (Status {0}, HRESULT 0x{1:X8}).' -f $detail.ResultCode, $detail.HResult)
        }
    }
    return ,$updates
}

function Invoke-DriverInstallation($session, $update, [bool] $acceptLicense, $history) {
    if ($env:VOLTDECK_REQUIRE_CACHE -eq '1' -and -not $update.IsDownloaded) {
        throw 'Der Download ist nicht mehr vollständig im Windows-Update-Cache. Bitte erneut vorbereiten.'
    }
    $updates = Get-UpdateDownload $session $update $acceptLicense
    Write-Host 'Treiber wird installiert ...'
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $updates
    $installer.AllowSourcePrompts = $false
    if ($installer.RebootRequiredBeforeInstallation) {
        throw 'Windows muss vor der Installation neu gestartet werden.'
    }
    if ($env:VOLTDECK_RESTORE_POINT -eq '1') {
        $history.Record.RestorePoint = New-VerifiedRestorePoint
        Write-DriverHistory $history.Directory $history.Record
    }
    $installation = $installer.Install()
    $detail = $installation.GetUpdateResult(0)
    if ($installation.RebootRequired -or $detail.RebootRequired) {
        Write-Host 'Windows meldet, dass ein Neustart erforderlich ist.'
    }
    if ($installation.ResultCode -ne 2 -or $detail.ResultCode -ne 2) {
        throw ('Installation nicht vollstaendig erfolgreich (Status {0}, HRESULT 0x{1:X8}).' -f $detail.ResultCode, $detail.HResult)
    }
    Write-Host 'Treiberupdate installiert.'
    return [bool] ($installation.RebootRequired -or $detail.RebootRequired)
}

try {
    if ($env:DRIVER_TOOL_ACTION -in 'scan','scan-ui','prepare','install','game-auto' -and $env:VOLTDECK_ONLINE -ne '1') {
        throw 'Windows-Update-Zugriff ist für diese Sitzung ausgeschaltet.'
    }
    switch ($env:DRIVER_TOOL_ACTION) {
        'inventory' {
            Get-CimInstance Win32_PnPSignedDriver | Sort-Object DeviceName |
                Format-Table -Wrap DeviceName, DriverProviderName, DriverVersion, InfName
        }
        { $_ -in 'inventory-ui','problems-ui' } {
            $items = @(Get-DeviceInventory | Sort-Object Treiber)
            ConvertTo-Json -InputObject $items -Compress -Depth 8
        }
        'problems' {
            $devices = @(Get-CimInstance Win32_PnPEntity -Filter 'Present = TRUE AND ConfigManagerErrorCode <> 0')
            if ($devices.Count -eq 0) { Write-Host 'Keine anwesenden Geraete mit Fehlercode gefunden.' }
            $devices | Sort-Object ConfigManagerErrorCode, Name |
                Format-List Name, ConfigManagerErrorCode, DeviceID
        }
        { $_ -in 'scan', 'scan-ui' } {
            if ($_ -eq 'scan') { Write-Host 'Suche nach Treiberupdates ...' }
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = 'VoltDeck'
            $result = Find-DriverUpdates $session ''
            $index = @{}
            if ($_ -eq 'scan-ui' -and $result.Updates.Count) {
                try { $index = Get-InstalledDriverIndex } catch { Write-Verbose $_.Exception.Message }
            }
            $items = @(for ($i = 0; $i -lt $result.Updates.Count; $i++) {
                $update = $result.Updates.Item($i)
                $date = '—'
                $dateLabel = 'Treiberdatum'
                $driverClass = $null
                $hardwareId = $null
                $recommended = $false
                $reboot = $null
                $interactive = $null
                $support = $null
                if ($_ -eq 'scan-ui') {
                    try { $driverClass = $update.DriverClass } catch { Write-Verbose $_.Exception.Message }
                    try { $date = Format-DriverDate $update.DriverVerDate } catch { Write-Verbose $_.Exception.Message }
                    if ($date -eq '—') {
                        $date = Format-DriverDate $update.LastDeploymentChangeTime
                        $dateLabel = if ($date -eq '—') { 'Datum unbekannt' } else { 'Katalogdatum' }
                    }
                    try { $hardwareId = $update.DriverHardwareID } catch { Write-Verbose $_.Exception.Message }
                    try { $recommended = $update.AutoSelectOnWebSites -and -not $update.BrowseOnly } catch { Write-Verbose $_.Exception.Message }
                    try {
                        $reboot = [int] $update.InstallationBehavior.RebootBehavior
                        $interactive = [bool] $update.InstallationBehavior.CanRequestUserInput
                    } catch { Write-Verbose $_.Exception.Message }
                    try {
                        $support = $update.SupportUrl
                        if ($update.MoreInfoUrls.Count) { $support = $update.MoreInfoUrls.Item(0) }
                    } catch { Write-Verbose $_.Exception.Message }
                }
                [pscustomobject] @{
                    Treiber = $update.Title
                    ID = $update.Identity.UpdateID
                    Revision = $update.Identity.RevisionNumber
                    Lizenz = $(if ($_ -eq 'scan-ui' -and -not $update.EulaAccepted) { $update.EulaText })
                    Klasse = $driverClass
                    Details = $(if ($update.Title -match '\bGame[ -]Ready\b') { 'Game Ready · Windows Update' } else { 'Verfügbar über Windows Update' })
                    Datum = $date
                    Datumsart = $dateLabel
                    Comparison = $(if ($_ -eq 'scan-ui') { Get-DriverComparison $update $index })
                    Category = Get-DriverCategory $driverClass
                    HardwareIds = @($hardwareId | Where-Object { $_ })
                    Recommended = $recommended
                    Downloaded = $update.IsDownloaded
                    RebootBehavior = $reboot
                    Interactive = $interactive
                    SupportUrl = $support
                    Source = 'Windows Update'
                }
            })
            if ($_ -eq 'scan-ui') {
                ConvertTo-Json -InputObject $items -Compress -Depth 8
            } else {
                if ($items.Count -eq 0) { Write-Host 'Keine passenden Treiberupdates gefunden.' }
                $items | Format-List Treiber, ID, Revision
            }
        }
        { $_ -in 'install','prepare' } { [void] (Install-DriverUpdate) }
        'game-auto' {
            Assert-Administrator
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = 'VoltDeck'
            $result = Find-DriverUpdates $session ''
            $count = 0
            for ($i = 0; $i -lt $result.Updates.Count; $i++) {
                $update = $result.Updates.Item($i)
                if ($env:VOLTDECK_PROTECT_CRITICAL -ne '0') {
                    try { $category = Get-DriverCategory $update.DriverClass } catch { $category = 'Other' }
                    if ($category -in 'Graphics','Network','Storage','Chipset','Audio','Other') { continue }
                }
                if ($update.Title -notmatch '\b(?:NVIDIA|GeForce)\b' -or $update.Title -notmatch '\bGame[ -]Ready\b' -or
                    -not $update.EulaAccepted -or $update.InstallationBehavior.CanRequestUserInput) { continue }
                $count++
                if (Invoke-LoggedUpdate $session $update $false) { break }
            }
            if ($count -eq 0) { Write-Host 'Kein eindeutig gekennzeichnetes Game-Ready-Update mit akzeptierter Lizenz verfügbar.' }
        }
        'restore' { Restore-DriverPackage }
        'backup' {
            Assert-Administrator
            $destination = $env:DRIVER_TOOL_BACKUP
            Assert-LocalPath $destination
            New-Item -ItemType Directory -Path $destination | Out-Null
            $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
            & $pnputil /export-driver '*' $destination
            if ($LASTEXITCODE -ne 0) {
                throw "Export fehlgeschlagen (Code $LASTEXITCODE). Der Zielordner kann Teildaten enthalten."
            }
            if ($env:VOLTDECK_VERIFIED_BACKUP -eq '1') { Write-BackupManifest $destination }
            Write-Host "Treiberpakete exportiert: $destination"
        }
        'verify-backup' {
            Assert-LocalPath $env:DRIVER_TOOL_BACKUP
            Test-BackupManifest $env:DRIVER_TOOL_BACKUP
        }
        'diagnostics' { Export-DriverDiagnostics $env:DRIVER_TOOL_BACKUP }
        default { throw 'Unbekannter Befehl.' }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

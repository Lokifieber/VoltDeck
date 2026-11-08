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

function Get-InstalledDriverIndex {
    $byDevice = @{}
    foreach ($driver in Get-CimInstance Win32_PnPSignedDriver) {
        if ($driver.DeviceID) { $byDevice[$driver.DeviceID] = $driver }
    }
    $byHardware = @{}
    foreach ($device in Get-CimInstance Win32_PnPEntity -Filter 'Present = TRUE') {
        if (-not $device.DeviceID -or -not $byDevice.ContainsKey($device.DeviceID)) { continue }
        foreach ($id in (@($device.HardwareID) + @($device.CompatibleID) | Where-Object { $_ } | Select-Object -Unique)) {
            if (-not $byHardware.ContainsKey($id)) { $byHardware[$id] = [Collections.Generic.List[object]]::new() }
            $byHardware[$id].Add($byDevice[$device.DeviceID])
        }
    }
    return $byHardware
}

function Get-DriverComparison($update, $index) {
    $installed = @()
    $hardware = $null
    try { $hardware = $update.DriverHardwareID } catch { Write-Verbose $_.Exception.Message }
    if ($hardware -and $index.ContainsKey($hardware)) {
        $installed = @(foreach ($driver in $index[$hardware]) {
            [pscustomobject] @{
                Name = $driver.DeviceName
                Provider = $driver.DriverProviderName
                Version = $driver.DriverVersion
                Date = Format-DriverDate $driver.DriverDate
                Inf = $driver.InfName
            }
        })
    }
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
        $reboot = Invoke-DriverInstallation $session $update $acceptLicense
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
    $file = Get-Item -LiteralPath $env:DRIVER_TOOL_BACKUP
    if ($file.PSIsContainer -or $file.Extension -ne '.inf') { throw 'Bitte eine INF-Datei aus der Sicherung auswählen.' }
    $history = New-DriverHistory $file.Name 'restore' $null
    $history.Record.Source = $file.FullName
    try {
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

    Invoke-LoggedUpdate $session ($result.Updates.Item(0)) $true
}

function Invoke-DriverInstallation($session, $update, [bool] $acceptLicense) {
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

    Write-Host 'Treiber wird installiert ...'
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $updates
    $installer.AllowSourcePrompts = $false
    if ($installer.RebootRequiredBeforeInstallation) {
        throw 'Windows muss vor der Installation neu gestartet werden.'
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
    switch ($env:DRIVER_TOOL_ACTION) {
        'inventory' {
            Get-CimInstance Win32_PnPSignedDriver | Sort-Object DeviceName |
                Format-Table -Wrap DeviceName, DriverProviderName, DriverVersion, InfName
        }
        'inventory-ui' {
            $items = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceName | Sort-Object DeviceName | ForEach-Object {
                [pscustomobject] @{
                    Treiber = $_.DeviceName
                    Klasse = $_.DeviceClass
                    Details = (@($_.DriverProviderName, $_.DriverVersion) | Where-Object { $_ }) -join ' · '
                    Datum = Format-DriverDate $_.DriverDate
                    Datumsart = 'Installierter Treiber'
                }
            })
            ConvertTo-Json -InputObject $items -Compress
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
                if ($_ -eq 'scan-ui') {
                    try { $driverClass = $update.DriverClass } catch { Write-Verbose $_.Exception.Message }
                    try { $date = Format-DriverDate $update.DriverVerDate } catch { Write-Verbose $_.Exception.Message }
                    if ($date -eq '—') {
                        $date = Format-DriverDate $update.LastDeploymentChangeTime
                        $dateLabel = if ($date -eq '—') { 'Datum unbekannt' } else { 'Katalogdatum' }
                    }
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
                }
            })
            if ($_ -eq 'scan-ui') {
                ConvertTo-Json -InputObject $items -Compress -Depth 8
            } else {
                if ($items.Count -eq 0) { Write-Host 'Keine passenden Treiberupdates gefunden.' }
                $items | Format-List Treiber, ID, Revision
            }
        }
        'install' { [void] (Install-DriverUpdate) }
        'game-auto' {
            Assert-Administrator
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = 'VoltDeck'
            $result = Find-DriverUpdates $session ''
            $count = 0
            for ($i = 0; $i -lt $result.Updates.Count; $i++) {
                $update = $result.Updates.Item($i)
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
            New-Item -ItemType Directory -Path $destination | Out-Null
            $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
            & $pnputil /export-driver '*' $destination
            if ($LASTEXITCODE -ne 0) {
                throw "Export fehlgeschlagen (Code $LASTEXITCODE). Der Zielordner kann Teildaten enthalten."
            }
            Write-Host "Treiberpakete exportiert: $destination"
        }
        default { throw 'Unbekannter Befehl.' }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

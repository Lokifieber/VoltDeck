function Set-OnlineAccess {
    if ($onlineAccess) {
        $script:onlineAccess = $false
        $onlineButton.Content = Get-Text 'Online-Zugriff: Aus'
    } else {
        [void] (Request-OnlineAccess)
    }
}

function Request-OnlineAccess {
    $prompt = Get-Text 'Wenn du Online-Zugriff erlaubst, nutzt VoltDeck den in Windows konfigurierten Update-Dienst. Der Dienst kann Geräte- und Konfigurationsdaten für die Suche und den Download verarbeiten. Die Freigabe gilt bis zum Schließen dieses Fensters und umfasst geplante Prüfungen.'
    if (Confirm-DriverInstall $window $prompt 'Für diese Sitzung erlauben' 'Windows Update online verwenden') {
        $script:onlineAccess = $true
        $onlineButton.Content = Get-Text 'Online-Zugriff: An'
    }
    return $onlineAccess
}

function Show-VoltDeckAbout($owner) {
    $dialog = New-ToolDialog $owner 'Über VoltDeck'
    $dialog.Width = 640
    $panel = $dialog.FindName('Content')
    if ($env:DRIVER_TOOL_EXE) {
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($env:DRIVER_TOOL_EXE).ProductVersion
        if ($version) {
            $displayVersion = $version -replace '-alpha$', ' Alpha'
            $headline = Add-ToolText $panel "$displayVersion  ·  Early Access"
            $headline.FontSize = 17
            $headline.FontWeight = 'SemiBold'
            $headline.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'ThemeHeading')
        }
    }
    $privacy = Add-SettingsCard $panel 'Datenschutz'
    [void] (Add-ToolText $privacy 'VoltDeck hat keine Telemetrie, keinen eigenen Server und keine automatische Upload-Funktion. Einstellungen, Favoriten, Sicherungen und Diagnoseberichte werden lokal gespeichert.')
    [void] (Add-ToolText $privacy 'VoltDeck startet offline. Erst nach Freigabe nutzt es Windows Update. Der in Windows konfigurierte Dienst verarbeitet dabei eigene Dienstdaten. Externe Links öffnen nach Bestätigung deinen Browser.')
    [void] (Add-ToolText $privacy 'Diagnoseberichte können Hardware-IDs, Treiberversionen und Protokolle enthalten. Wenn du eine Datei selbst teilst oder in einen synchronisierten Ordner speicherst, gelten die Einstellungen des verwendeten Dienstes.')
    $security = Add-SettingsCard $panel 'Sicherheit'
    [void] (Add-ToolText $security 'Treiberinstallation und Wiederherstellung benötigen Administratorrechte. VoltDeck verwendet dazu Windows Update und PnPUtil. Die Alpha-Downloads sind unsigniert.')
    [void] (Add-ToolText $panel 'Lokicraft · Projekt von LokiFieber mit OpenAI Codex')
    [void] $dialog.ShowDialog()
}

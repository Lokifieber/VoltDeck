function Get-DriverKey($item) {
    if ($item.DeviceId) { return $item.DeviceId }
    return [string] $item.ID
}

function Get-CategoryLabel([string] $category) {
    $labels = @{ Graphics = 'Grafik'; Audio = 'Audio'; Network = 'Netzwerk'; Chipset = 'Chipsatz'
        Storage = 'Speicher'; 'Print / Imaging' = 'Druck / Bild'; USB = 'USB'; Other = 'Sonstige' }
    if ($labels.ContainsKey($category)) { return Get-Text $labels[$category] }
    return Get-Text 'Sonstige'
}

function Update-DriverList {
    if (-not $script:rows) { return }
    $query = $searchBox.Text.Trim()
    $matching = @(foreach ($row in $script:rows) {
        $pinned = (Get-DriverKey $row) -in $settings.pins -and [bool] (Get-DriverKey $row)
        $row.Pinned = $pinned
        $row.Badge = $(if ($pinned) { '★ ' }) + (Get-CategoryLabel $row.Category)
        if ($row.Problem) { $row.Badge += ' · ' + (Get-Text 'Geräteprobleme') }
        elseif ($row.Downloaded) { $row.Badge += ' · ' + (Get-Text 'Heruntergeladen') }
        if ($settings.hideInbox -and $row.Inbox -and -not $row.Problem -and -not $pinned) { continue }
        if ($filters.category -and $row.Category -ne $filters.category) { continue }
        if ($filters.status -eq 'updates' -and -not $row.ID) { continue }
        if ($filters.status -eq 'downloaded' -and -not ($row.ID -and $row.Downloaded)) { continue }
        if ($filters.status -eq 'installed' -and $row.ID) { continue }
        if ($filters.recommended -and -not $row.Recommended) { continue }
        if (($filters.problems -or $script:problemView) -and -not $row.Problem) { continue }
        $manufacturer = "$($row.Manufacturer) $($row.Provider) $($row.Comparison.TargetProvider)"
        if ($filters.manufacturer -and $manufacturer.IndexOf($filters.manufacturer, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($filters.since) {
            $date = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($row.Datum, 'dd.MM.yyyy', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref] $date) -or $date -lt $filters.since) { continue }
        }
        $haystack = "$($row.Treiber) $manufacturer $($row.Inf) $($row.Version) $($row.Comparison.TargetVersion) $($row.Comparison.Installed.Inf -join ' ')"
        if ($query -and $haystack.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $row
    })
    $selectedKey = Get-DriverKey $updates.SelectedItem
    $updates.ItemsSource = @($matching | Sort-Object @{Expression='Pinned';Descending=$true}, @{Expression={ [bool] $_.Problem };Descending=$true}, Treiber)
    if ($selectedKey) { $updates.SelectedItem = $matching | Where-Object { (Get-DriverKey $_) -eq $selectedKey } | Select-Object -First 1 }
    $updates.Visibility = if ($matching.Count) { 'Visible' } else { 'Collapsed' }
    $emptyState.Visibility = if ($matching.Count) { 'Collapsed' } else { 'Visible' }
    $emptyTitle.Text = Get-Text 'Keine Treffer'
    $emptyDescription.Text = Get-Text 'Ändere die Suche oder die Filter.'
    $status.Text = (Get-Text '{0} von {1} Einträgen · {2} Problemgeräte') -f $matching.Count, $rows.Count, @($rows | Where-Object Problem).Count
}

function Add-VoltCheck($panel, $owner, $label, [bool] $value) {
    $check = [Windows.Controls.CheckBox]::new()
    $check.Style = $owner.FindResource('SettingsToggle')
    $check.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'ThemeText')
    $check.Content = Get-Text $label
    $check.IsChecked = $value
    $check.Margin = '0,4,0,7'
    [void] $panel.Children.Add($check)
    return $check
}

function Show-DriverFilters($owner) {
    $dialog = New-ToolDialog $owner 'Filter'
    $panel = $dialog.FindName('Content')
    [void] (Add-ToolText $panel 'Hersteller oder Anbieter')
    $maker = [Windows.Controls.TextBox]::new()
    $maker.Text = $filters.manufacturer
    $maker.Padding = '8'
    [void] $panel.Children.Add($maker)
    [void] (Add-ToolText $panel 'Kategorie')
    $category = New-SettingsPicker $panel $owner
    $category.ItemsSource = @([pscustomobject] @{ Key = ''; Label = Get-Text 'Alle' }) + @(foreach ($name in 'Graphics','Audio','Network','Chipset','Storage','Print / Imaging','USB','Other') {
        [pscustomobject] @{ Key = $name; Label = Get-CategoryLabel $name }
    })
    $category.SelectedValue = $filters.category
    [void] (Add-ToolText $panel 'Update-Status')
    $state = New-SettingsPicker $panel $owner
    $state.ItemsSource = @(
        [pscustomobject] @{ Key = ''; Label = Get-Text 'Alle' }
        [pscustomobject] @{ Key = 'updates'; Label = Get-Text 'Updates verfügbar' }
        [pscustomobject] @{ Key = 'downloaded'; Label = Get-Text 'Heruntergeladen' }
        [pscustomobject] @{ Key = 'installed'; Label = Get-Text 'Installiert' }
    )
    $state.SelectedValue = $filters.status
    [void] (Add-ToolText $panel 'Treiber- oder Katalogdatum ab')
    $date = [Windows.Controls.DatePicker]::new()
    $date.SelectedDate = $filters.since
    [void] $panel.Children.Add($date)
    $relevant = Add-VoltCheck $panel $owner 'Nur relevante Treiber (In-Box ausblenden)' $settings.hideInbox
    $recommended = Add-VoltCheck $panel $owner 'Nur von Windows Update automatisch ausgewählte Angebote' $filters.recommended
    $problems = Add-VoltCheck $panel $owner 'Nur Problemgeräte' $filters.problems
    $apply = Add-ToolButton $panel $owner 'Anwenden'
    $apply.Tag = $dialog
    $apply.Add_Click({ param($sender) $sender.Tag.DialogResult = $true })
    if ($dialog.ShowDialog() -eq $true) {
        $script:filters = @{
            manufacturer = $maker.Text.Trim(); category = [string] $category.SelectedValue; status = [string] $state.SelectedValue
            since = $date.SelectedDate; recommended = [bool] $recommended.IsChecked; problems = [bool] $problems.IsChecked
        }
        $new = $settings.Clone()
        $new.hideInbox = [bool] $relevant.IsChecked
        try { Save-ToolSettings $new } catch { $status.Text = $_.Exception.Message; return }
        Update-DriverList
    }
}

function Get-SignerText($device) {
    if ($null -eq $device.Signed) { return Get-Text 'Signatur nicht gemeldet' }
    if (-not $device.Signed) { return Get-Text 'Windows meldet das Paket als unsigniert' }
    return ((Get-Text 'Von Windows als signiert gemeldet') + $(if ($device.Signer) { ' · ' + $device.Signer }))
}

function Get-DetailText($item) {
    $lines = @($item.Treiber, (Get-CategoryLabel $item.Category), $item.Details, (Get-Text $item.Source))
    if ($item.ID) {
        $lines += @('Windows Update', "$($item.Datumsart): $($item.Datum)", "$($item.ID) / $($item.Revision)")
        if ($item.Downloaded) { $lines += Get-Text 'Windows Update bestätigt den vollständigen Download.' }
        if ($item.RebootBehavior -eq 1) { $lines += Get-Text 'Neustart erforderlich' }
        elseif ($item.RebootBehavior -eq 2) { $lines += Get-Text 'Neustart möglicherweise erforderlich' }
        if ($item.Interactive) { $lines += Get-Text 'Windows-Interaktion erforderlich. Installation über Windows Update öffnen.' }
        if (-not $item.Recommended) { $lines += Get-Text 'Optionales Angebot oder Empfehlung unbekannt' }
        $lines += Get-Text 'Der Paketsignierer des Angebots wird von Windows Update nicht angezeigt.'
        $lines += $item.HardwareIds
        $devices = @($item.Comparison.Installed | Where-Object DeviceId)
        if (-not $devices.Count) { $lines += Get-Text 'Kein installiertes Gerät zugeordnet.' }
    } else {
        $devices = @($script:rows | Where-Object { $_.DeviceId -and $item.Inf -and $_.Inf -eq $item.Inf })
        if (-not $devices.Count) { $devices = @($item) }
    }
    foreach ($device in $devices) {
        $name = if ($device.Name) { $device.Name } else { $device.Treiber }
        $lines += @('', $name, $device.DeviceId, $device.Manufacturer, $device.Provider,
            $device.Version, $device.Date, $device.Datum, $device.Inf, $device.Problem, (Get-SignerText $device))
        $lines += @($device.HardwareIds) + @($device.CompatibleIds)
        if ($device.ProblemCode) { $lines += "Windows: $($device.ProblemCode)" }
        if ($device.Inf -match '^[a-zA-Z0-9_.-]+\.inf$' -and ('VoltDeckDriverStore' -as [type])) {
            $lines += [VoltDeckDriverStore]::Find((Join-Path $env:SystemRoot ('INF\' + $device.Inf)))
        }
    }
    return ($lines | Where-Object { $null -ne $_ -and ($_ -is [string]) }) -join [Environment]::NewLine
}

function Open-SystemTool([string] $name) {
    try {
        if ($name -eq 'devmgmt.msc') {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\mmc.exe') -ArgumentList ('"' + (Join-Path $env:SystemRoot 'System32\devmgmt.msc') + '"')
        } elseif ($name -eq 'rstrui.exe') {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\rstrui.exe')
        }
    }
    catch { $status.Text = $_.Exception.Message }
}

function Open-DeviceProperties([string] $deviceId) {
    if ($deviceId -notmatch '^[A-Za-z0-9\\&_.#{}+\-]+$') { Open-SystemTool 'devmgmt.msc'; return }
    $tool = Join-Path $env:SystemRoot 'System32\rundll32.exe'
    $module = Join-Path $env:SystemRoot 'System32\devmgr.dll'
    try { Start-Process -FilePath $tool -ArgumentList ('"{0}",DeviceProperties_RunDLL /DeviceID "{1}"' -f $module, $deviceId) }
    catch { $status.Text = $_.Exception.Message }
}

function Show-DeviceDetails($owner, $item) {
    if (-not $item) { return }
    $dialog = New-ToolDialog $owner 'Gerätedetails'
    $panel = $dialog.FindName('Content')
    $field = [Windows.Controls.TextBox]::new()
    $field.Text = Get-DetailText $item
    $field.IsReadOnly = $true
    $field.TextWrapping = 'Wrap'
    $field.VerticalScrollBarVisibility = 'Auto'
    $field.Height = 260
    $field.Padding = '10'
    $field.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'ThemeBase')
    $field.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'ThemeText')
    [void] $panel.Children.Add($field)
    [void] (Add-ToolText $panel 'Windows zeigt den gerätespezifischen Rollback-Status im Geräte-Manager unter Treiber → Vorheriger Treiber.')
    $buttons = [Windows.Controls.WrapPanel]::new()
    [void] $panel.Children.Add($buttons)
    $copy = Add-ToolButton $buttons $owner 'Details kopieren'
    $copy.Tag = $field.Text
    $copy.Add_Click({ param($sender) Copy-DriverDetails $sender.Tag })
    $manager = Add-ToolButton $buttons $owner 'Geräte-Manager'
    $manager.Add_Click({ Open-SystemTool 'devmgmt.msc' })
    $deviceIds = if ($item.DeviceId) { @($item.DeviceId) } else { @($item.Comparison.Installed | ForEach-Object DeviceId | Where-Object { $_ } | Select-Object -Unique) }
    if (@($deviceIds).Count -eq 1) {
        $properties = Add-ToolButton $buttons $owner 'Windows-Rollback prüfen'
        $properties.Tag = @($deviceIds)[0]
        $properties.Add_Click({ param($sender) Open-DeviceProperties $sender.Tag })
    }
    [uri] $uri = $null
    if ($item.SupportUrl -and [uri]::TryCreate([string] $item.SupportUrl, [UriKind]::Absolute, [ref] $uri) -and $uri.Scheme -eq 'https' -and
        $uri.Host -match '(^|\.)(microsoft\.com|nvidia\.com|amd\.com|intel\.com|dell\.com|hp\.com|lenovo\.com|asus\.com|msi\.com)$') {
        $official = Add-ToolButton $buttons $owner 'Offizielle Supportseite'
        $official.Tag = $uri.AbsoluteUri
        $official.Add_Click({ param($sender) Open-ExternalPage $sender.Tag })
    }
    [void] $dialog.ShowDialog()
}

function Copy-DriverDetails([string] $value) {
    if (-not $value) { return }
    try { [Windows.Clipboard]::SetText($value) } catch { $status.Text = $_.Exception.Message }
}

function Select-DriverFolder($action) {
    if ($action -eq 'backup' -and -not $isAdmin) { Request-Admin; return }
    $picker = [Windows.Forms.FolderBrowserDialog]::new()
    try {
        $picker.Description = Get-Text 'Wähle den Ordner, in dem die Sicherung angelegt werden soll.'
        $selection = $picker.ShowDialog()
        if ($selection -ne 'OK') { return }
        $root = $picker.SelectedPath
    } finally { $picker.Dispose() }
    switch ($action) {
        'backup' {
            $destination = Join-Path $root ('VoltDeck-Backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            if (Confirm-DriverInstall $window ('pnputil.exe /export-driver * "' + $destination + '"') 'Treiber sichern' 'Vollständige Treibersicherung') {
                Start-Operation $action (Get-Text 'Treiberpakete werden exportiert …') $null $destination
            }
        }
        'verify-backup' { Start-Operation $action (Get-Text 'Sicherung wird geprüft …') $null $root }
        'diagnostics' {
            $destination = Join-Path $root ('VoltDeck-Diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            if (Confirm-DriverInstall $window (Get-Text 'Der lokale Bericht enthält Hardware-IDs und Treiberprotokolle. Prüfe ihn, bevor du ihn weitergibst.') 'Diagnose exportieren' 'Diagnose exportieren') {
                Start-Operation $action (Get-Text 'Diagnose wird erstellt …') $null $destination
            }
        }
    }
}

function Show-SafetyTools($owner) {
    $dialog = New-ToolDialog $owner 'Schutz & Diagnose'
    $panel = $dialog.FindName('Content')
    $restore = Add-VoltCheck $panel $owner 'Wiederherstellungspunkt vor jeder Installation prüfen' $settings.restorePoint
    $safe = Add-VoltCheck $panel $owner 'Testmodus: Erst herunterladen, danach separat installieren' $settings.safeMode
    $critical = Add-VoltCheck $panel $owner 'Kritische Treiber für automatische Installation sperren' $settings.protectCritical
    [void] (Add-ToolText $panel 'Update-Plan (nur prüfen und benachrichtigen, solange VoltDeck läuft)')
    $plan = New-SettingsPicker $panel $owner
    $plan.ItemsSource = @(
        [pscustomobject] @{ Key = 0; Label = Get-Text 'Aus' }
        [pscustomobject] @{ Key = 24; Label = Get-Text 'Täglich' }
        [pscustomobject] @{ Key = 168; Label = Get-Text 'Wöchentlich' }
    )
    $plan.SelectedValue = $settings.planHours
    $buttons = [Windows.Controls.WrapPanel]::new()
    [void] $panel.Children.Add($buttons)
    $save = Add-ToolButton $buttons $owner 'Speichern'
    $save.Tag = $dialog
    $save.Add_Click({ param($sender) $sender.Tag.DialogResult = $true })
    foreach ($pair in @(@('Diagnose exportieren','diagnostics'), @('Sicherung prüfen','verify-backup'), @('Erste Hilfe','help'))) {
        $button = Add-ToolButton $buttons $owner $pair[0]
        $button.Tag = @{ Action = $pair[1]; Dialog = $dialog }
        $button.Add_Click({
            param($sender)
            $action = $sender.Tag.Action
            $sender.Tag.Dialog.Close()
            if ($action -eq 'help') { Show-DriverHelp $window } else { Select-DriverFolder $action }
        })
    }
    if ($dialog.ShowDialog() -eq $true) {
        $new = $settings.Clone()
        $new.restorePoint = [bool] $restore.IsChecked
        $new.safeMode = [bool] $safe.IsChecked
        $new.protectCritical = [bool] $critical.IsChecked
        if ($new.planHours -ne [int] $plan.SelectedValue) { $new.lastPlanCheck = '' }
        $new.planHours = [int] $plan.SelectedValue
        try { Save-ToolSettings $new } catch { $status.Text = $_.Exception.Message }
    }
}

function Show-DriverHelp($owner) {
    $dialog = New-ToolDialog $owner 'Erste Hilfe'
    $panel = $dialog.FindName('Content')
    $picker = New-SettingsPicker $panel $owner
    $picker.ItemsSource = @(
        [pscustomobject] @{ Key = 'net'; Label = Get-Text 'WLAN weg'; Guide = 'Netzwerkadapter im Geräte-Manager öffnen. Prüfe, ob das Gerät deaktiviert ist oder einen Fehlercode meldet.' }
        [pscustomobject] @{ Key = 'audio'; Label = Get-Text 'Audio fehlt'; Guide = 'Prüfe das ausgewählte Ausgabegerät und dann den Audiotreiber im Geräte-Manager.' }
        [pscustomobject] @{ Key = 'display'; Label = Get-Text 'Bildschirm schwarz'; Guide = 'Wenn Windows noch reagiert, versuche Win+Ctrl+Shift+B. Bei dauerhaft schwarzem Bildschirm nutze die Windows-Wiederherstellungsumgebung.' }
    )
    $guide = Add-ToolText $panel ''
    $picker.Tag = $guide
    $picker.Add_SelectionChanged({ param($sender) $sender.Tag.Text = Get-Text $sender.SelectedItem.Guide })
    $picker.SelectedIndex = 0
    [void] (Add-ToolText $panel 'Nach einem Update: Prüfe den vorherigen Treiber im Geräte-Manager. Starte nach einer Rücksetzung bei Bedarf neu und exportiere bei anhaltenden Problemen die Diagnose.')
    $buttons = [Windows.Controls.WrapPanel]::new()
    [void] $panel.Children.Add($buttons)
    $manager = Add-ToolButton $buttons $owner 'Geräte-Manager'
    $manager.Add_Click({ Open-SystemTool 'devmgmt.msc' })
    $restore = Add-ToolButton $buttons $owner 'Systemwiederherstellung'
    $restore.Add_Click({ Open-SystemTool 'rstrui.exe' })
    $problems = Add-ToolButton $buttons $owner 'Geräteprobleme'
    $problems.Tag = $dialog
    $problems.Add_Click({
        param($sender)
        $sender.Tag.Close()
        Start-Operation 'problems-ui' (Get-Text 'Geräte werden geprüft …')
    })
    $report = Add-ToolButton $buttons $owner 'Diagnose exportieren'
    $report.Tag = $dialog
    $report.Add_Click({ param($sender) $sender.Tag.Close(); Select-DriverFolder 'diagnostics' })
    [void] $dialog.ShowDialog()
}

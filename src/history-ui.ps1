function Get-ComparisonText($comparison, [bool] $installed) {
    if ($installed) {
        if (-not $comparison.Installed) { return (Get-Text 'Kein installierter Treiber eindeutig zugeordnet.') }
        return (@(foreach ($driver in @($comparison.Installed)) {
            (@($driver.Name, $driver.Provider, $driver.Version, $driver.Date, $driver.Inf) | Where-Object { $_ }) -join "`n"
        }) -join "`n`n")
    }
    $version = if ($comparison.TargetVersion) { $comparison.TargetVersion } else { Get-Text 'Version nicht gemeldet' }
    return ((@($comparison.TargetProvider, $version, $comparison.TargetDate) | Where-Object { $_ }) -join "`n")
}

function Show-DriverComparison($owner, [string] $name, $comparison) {
    if (-not $comparison) { return }
    $dialog = New-ToolDialog $owner 'Treiber vergleichen'
    $dialog.Width = 690
    $panel = $dialog.FindName('Content')
    $heading = Add-ToolText $panel $name
    $heading.FontSize = 17
    $heading.FontWeight = 'SemiBold'
    $grid = [Windows.Controls.Grid]::new()
    [void] $panel.Children.Add($grid)
    foreach ($i in 0, 1) {
        $grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
        $column = [Windows.Controls.StackPanel]::new()
        $column.Margin = if ($i -eq 0) { '0,0,7,0' } else { '7,0,0,0' }
        [Windows.Controls.Grid]::SetColumn($column, $i)
        [void] $grid.Children.Add($column)
        $card = Add-SettingsCard $column $(if ($i -eq 0) { 'Installierter Treiber' } else { 'Angebotenes Update' })
        $scroll = [Windows.Controls.ScrollViewer]::new()
        $scroll.MaxHeight = 240
        $scroll.VerticalScrollBarVisibility = 'Auto'
        $content = [Windows.Controls.StackPanel]::new()
        $scroll.Content = $content
        [void] $card.Children.Add($scroll)
        $text = Add-ToolText $content (Get-ComparisonText $comparison ($i -eq 0))
        $text.Margin = '0'
    }
    [void] $dialog.ShowDialog()
}

function Show-DriverHistory($owner) {
    $dialog = New-ToolDialog $owner 'Treiberverlauf'
    $dialog.Width = 720
    $panel = $dialog.FindName('Content')
    $entries = [Windows.Controls.ListBox]::new()
    $entries.Height = 235
    $entries.ItemContainerStyle = $owner.FindResource([Windows.Controls.ListBoxItem])
    $entries.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'ThemeBase')
    $entries.DisplayMemberPath = 'Label'
    $entries.Margin = '0,0,0,12'
    [void] $panel.Children.Add($entries)

    $historyRoot = Join-Path $settingsDirectory 'history'
    $resultLabels = @{ running = 'Ergebnis offen'; success = 'Installiert'; reboot = 'Neustart erforderlich'; failed = 'Fehlgeschlagen'; imported = 'Paket importiert' }
    if (Test-Path -LiteralPath $historyRoot) {
        $entries.ItemsSource = @(Get-ChildItem -LiteralPath $historyRoot -Directory | ForEach-Object {
            try {
                $entry = Get-Content -LiteralPath (Join-Path $_.FullName 'entry.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $time = [datetimeoffset]::Parse($entry.Time)
                $result = Get-Text $resultLabels[$entry.Result]
                [pscustomobject] @{ Time = $time; Entry = $entry; Directory = $_.FullName; Label = "$($time.ToLocalTime().ToString('g', $uiCulture))  ·  $result  ·  $($entry.Name)" }
            } catch { Write-Verbose $_.Exception.Message }
        } | Sort-Object Time -Descending)
    }
    $notice = Add-ToolText $panel $(if ($entries.Items.Count) { 'Wähle einen Eintrag für Details oder zum Wiederherstellen.' } else { 'Noch keine Treibervorgänge in VoltDeck aufgezeichnet.' })
    $buttons = [Windows.Controls.WrapPanel]::new()
    [void] $panel.Children.Add($buttons)
    $details = Add-ToolButton $buttons $owner 'Treiber vergleichen'
    $restore = Add-ToolButton $buttons $owner 'Sicherung wiederherstellen'
    $browse = Add-ToolButton $buttons $owner 'INF-Datei auswählen'
    $details.IsEnabled = $restore.IsEnabled = $false
    $controls = @{ Entries = $entries; Notice = $notice; Details = $details; Restore = $restore; Dialog = $dialog; Owner = $owner }
    $entries.Tag = $details.Tag = $restore.Tag = $browse.Tag = $controls
    $entries.Add_SelectionChanged({
        param($sender, $eventArgs)
        $state = $sender.Tag
        $entry = $sender.SelectedItem.Entry
        $state.Details.IsEnabled = [bool] $entry.Comparison
        $state.Restore.IsEnabled = [bool] $entry.Backups
        $state.Notice.Text = if ($entry.Error) { $entry.Error } elseif ($entry.Source) { $entry.Source } else { $sender.SelectedItem.Label }
    })
    $details.Add_Click({
        param($sender, $eventArgs)
        $state = $sender.Tag
        $entry = $state.Entries.SelectedItem.Entry
        Show-DriverComparison $state.Dialog $entry.Name $entry.Comparison
    })
    $restore.Add_Click({
        param($sender, $eventArgs)
        $state = $sender.Tag
        $row = $state.Entries.SelectedItem
        $paths = @(foreach ($backup in $row.Entry.Backups) {
            $path = if ([IO.Path]::IsPathRooted($backup)) { $backup } else { Join-Path $row.Directory $backup }
            if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
        })
        if ($paths.Count -eq 1) { Request-DriverRestore $state.Dialog $paths[0] }
        elseif ($paths.Count) { Select-RestoreFile $state.Dialog (Split-Path -Parent $paths[0]) }
        else { $state.Notice.Text = Get-Text 'Die Sicherungsdateien sind nicht mehr vorhanden.' }
    })
    $browse.Add_Click({ param($sender, $eventArgs) Select-RestoreFile $sender.Tag.Dialog '' })
    [void] $dialog.ShowDialog()
}

function Select-RestoreFile($dialog, [string] $directory) {
    $picker = [Microsoft.Win32.OpenFileDialog]::new()
    $picker.Title = Get-Text 'INF-Datei auswählen'
    $picker.Filter = 'INF (*.inf)|*.inf'
    if ($directory) { $picker.InitialDirectory = $directory }
    if ($picker.ShowDialog($dialog)) { Request-DriverRestore $dialog $picker.FileName }
}

function Request-DriverRestore($dialog, [string] $file) {
    if (-not $isAdmin) {
        $dialog.Close()
        Request-Admin
        return
    }
    $prompt = (Get-Text 'Dieses Treiberpaket aus der Sicherung importieren? Windows entscheidet, welcher Treiber aktiv wird.') + "`n`n$file"
    if (Confirm-DriverInstall $dialog $prompt 'Wiederherstellen') {
        $dialog.Close()
        Start-Operation 'restore' (Get-Text 'Treiberpaket wird wiederhergestellt …') $null $file
    }
}

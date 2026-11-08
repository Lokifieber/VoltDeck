function New-ToolDialog($owner, [string] $title) {
    [xml] $markup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Foreground="#EDF3FF"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Width="590" SizeToContent="Height"
        ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="14">
    <Border Background="{DynamicResource ThemeSurface}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="21" Padding="20">
        <StackPanel>
            <DockPanel Margin="0,0,0,13">
                <Button Name="Dismiss" DockPanel.Dock="Right" Width="36" Height="36" Padding="0" IsCancel="True" ToolTip="Schließen" AutomationProperties.Name="Schließen">
                    <Path Data="M 1,1 L 11,11 M 11,1 L 1,11" Stroke="#FFF1F5" StrokeThickness="1.8" Width="12" Height="12"/>
                </Button>
                <TextBlock Name="Heading" FontSize="22" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </DockPanel>
            <StackPanel Name="Content"/>
        </StackPanel>
    </Border>
</Window>
'@
    Localize-Markup $markup
    $dialog = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($markup))
    $dialog.Owner = $owner
    $dialog.Resources.MergedDictionaries.Add($owner.Resources)
    $dialog.FlowDirection = $owner.FlowDirection
    $dialog.Title = Get-Text $title
    $dialog.FindName('Heading').Text = Get-Text $title
    $dismiss = $dialog.FindName('Dismiss')
    $dismiss.Style = $owner.FindResource([Windows.Controls.Button])
    return $dialog
}

function Add-ToolText($panel, [string] $text) {
    $block = [Windows.Controls.TextBlock]::new()
    $block.Text = Get-Text $text
    $block.Foreground = '#B7C7E2'
    $block.TextWrapping = 'Wrap'
    $block.Margin = '0,0,0,11'
    [void] $panel.Children.Add($block)
    return $block
}

function Add-ToolButton($panel, $owner, [string] $label) {
    $button = [Windows.Controls.Button]::new()
    $button.Style = $owner.FindResource([Windows.Controls.Button])
    $button.Content = Get-Text $label
    $button.Margin = '0,0,8,8'
    [void] $panel.Children.Add($button)
    return $button
}

function Confirm-DriverInstall($owner, [string] $prompt, [string] $action = 'Installieren') {
    $dialog = New-ToolDialog $owner 'Installation bestätigen'
    $panel = $dialog.FindName('Content')
    [void] (Add-ToolText $panel $prompt)
    $buttons = [Windows.Controls.WrapPanel]::new()
    [void] $panel.Children.Add($buttons)
    $cancel = Add-ToolButton $buttons $owner 'Abbrechen'
    $cancel.IsCancel = $true
    $install = Add-ToolButton $buttons $owner $action
    $install.Tag = $dialog
    $install.Add_Click({ param($sender, $eventArgs) $sender.Tag.DialogResult = $true })
    return ($dialog.ShowDialog() -eq $true)
}

function Show-Gaming($owner, $autoTimer, [bool] $canInstall) {
    $dialog = New-ToolDialog $owner 'Game Ready und Spielkomponenten'
    $panel = $dialog.FindName('Content')
    [void] (Add-ToolText $panel 'Für aktuelle Gaming-Treiber öffnen diese Schaltflächen die Hersteller-Tools. Dort findest du passende Pakete, Freigabedaten und die vom Hersteller angebotenen Update-Einstellungen.')
    $links = [ordered] @{
        'NVIDIA App · GeForce Game Ready' = 'https://www.nvidia.com/en-us/software/nvidia-app/'
        'AMD Software · Adrenalin Edition' = 'https://www.amd.com/en/resources/support-articles/faqs/GPU-131.html'
        'Intel · Driver & Support Assistant' = 'https://www.intel.com/content/www/us/en/support/detect.html'
        'Microsoft Visual C++ Redistributable' = 'https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist'
        'Microsoft DirectX · ältere Spielkomponenten' = 'https://www.microsoft.com/en-us/download/details.aspx?id=35'
    }
    foreach ($label in $links.Keys) {
        $button = Add-ToolButton $panel $owner $label
        $button.Tag = $links[$label]
        $button.Add_Click({ param($sender, $eventArgs) Start-Process $sender.Tag })
    }
    $auto = [Windows.Controls.CheckBox]::new()
    $auto.Content = Get-Text 'Game-Ready-Updates automatisch installieren'
    $auto.Foreground = '#EDF3FF'
    $auto.Margin = '0,10,0,8'
    $auto.IsEnabled = $canInstall
    $auto.IsChecked = $autoTimer.IsEnabled
    $auto.Add_Checked({ $autoTimer.Start() })
    $auto.Add_Unchecked({ $autoTimer.Stop() })
    [void] $panel.Children.Add($auto)
    $autoNote = 'Solange VoltDeck geöffnet ist, prüft es alle 30 Minuten Windows Update, wenn das Hauptfenster aktiv ist. Die Installation setzt eine eindeutige NVIDIA-Game-Ready-Kennzeichnung und eine bereits akzeptierte Lizenz voraus.'
    [void] (Add-ToolText $panel $autoNote)
    if (-not $canInstall) { [void] (Add-ToolText $panel 'Öffne VoltDeck als Administrator, um die Option zu aktivieren.') }
    [void] $dialog.ShowDialog()
}

function Show-Boost($owner) {
    $dialog = New-ToolDialog $owner 'Spiel-Beschleunigung'
    $panel = $dialog.FindName('Content')
    [void] (Add-ToolText $panel 'Wähle die Hintergrundprogramme, die du vor dem Spielen schließen möchtest. Die Apps erhalten eine normale Schließanforderung und können dich zum Speichern auffordern.')
    $apps = [Windows.Controls.ListBox]::new()
    $apps.Height = 218
    $apps.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'ThemeBase')
    $apps.Foreground = '#EDF3FF'
    $apps.ItemContainerStyle = $owner.FindResource([Windows.Controls.ListBoxItem])
    $apps.SelectionMode = 'Extended'
    $apps.DisplayMemberPath = 'Label'
    $apps.Margin = '0,0,0,11'
    [void] $panel.Children.Add($apps)
    $sessionId = (Get-Process -Id $PID).SessionId
    $apps.ItemsSource = @(Get-Process | ForEach-Object {
        try {
            if ($_.SessionId -eq $sessionId -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -and
                $_.ProcessName -notin @('explorer', 'DriverTool', 'powershell', 'pwsh', 'WindowsTerminal', 'dwm')) {
                $memory = [Math]::Round($_.WorkingSet64 / 1MB)
                [pscustomobject] @{ Label = "$($_.MainWindowTitle)  ·  $($_.ProcessName)  ·  $memory MB RAM"; Process = $_; Started = $_.StartTime }
            }
        } catch { Write-Verbose $_.Exception.Message }
    } | Sort-Object Label)
    $message = Add-ToolText $panel 'Mehrfachauswahl mit Strg oder Umschalt. Windows-Dienste bleiben aktiv.'
    $controls = [Windows.Controls.WrapPanel]::new()
    [void] $panel.Children.Add($controls)
    $closeApps = Add-ToolButton $controls $owner 'Ausgewählte Apps schließen'
    $closeApps.IsEnabled = $false
    $apps.Add_SelectionChanged({ $closeApps.IsEnabled = $apps.SelectedItems.Count -gt 0 })
    $closeApps.Add_Click({
        $sent = 0
        $skipped = 0
        foreach ($app in @($apps.SelectedItems)) {
            try {
                $app.Process.Refresh()
                if ($app.Process.HasExited -or $app.Process.StartTime -ne $app.Started -or -not $app.Process.CloseMainWindow()) {
                    $skipped++
                } else { $sent++ }
            } catch { $skipped++ }
        }
        $message.Text = (Get-Text '{0} Schließanforderungen gesendet. {1} Apps nicht erreicht.') -f $sent, $skipped
        $apps.UnselectAll()
    })

    if ($env:VOLTDECK_PORTABLE_DATA) {
        [void] $dialog.ShowDialog()
        return
    }
    $verb = 'Software\Classes\DesktopBackground\Shell\DriverToolBoost'
    $registry = [Microsoft.Win32.Registry]::CurrentUser
    $shortcut = Add-ToolButton $controls $owner 'Desktop-Menü hinzufügen'
    $existing = $registry.OpenSubKey($verb)
    if ($existing) { $shortcut.Content = Get-Text 'Desktop-Menü entfernen'; $existing.Dispose() }
    $shortcut.Add_Click({
        try {
            $registered = $registry.OpenSubKey($verb)
            if ($registered) {
                $registered.Dispose()
                $registry.DeleteSubKeyTree($verb, $false)
                $shortcut.Content = Get-Text 'Desktop-Menü hinzufügen'
                $message.Text = Get-Text 'Die Verknüpfung wurde entfernt.'
            } else {
                $key = $registry.CreateSubKey($verb)
                try {
                    $key.SetValue('', ('VoltDeck – ' + (Get-Text 'Spiel-Beschleunigung')))
                    $key.SetValue('Icon', '"{0}",0' -f $env:DRIVER_TOOL_EXE)
                    $commandKey = $key.CreateSubKey('command')
                    try { $commandKey.SetValue('', '"{0}" --boost' -f $env:DRIVER_TOOL_EXE) }
                    finally { $commandKey.Dispose() }
                } finally { $key.Dispose() }
                $shortcut.Content = Get-Text 'Desktop-Menü entfernen'
                $message.Text = Get-Text 'Rechtsklick auf den Desktop. Unter Windows 11 ggf. „Weitere Optionen anzeigen“ wählen.'
            }
        } catch { $message.Text = $_.Exception.Message }
    })
    [void] $dialog.ShowDialog()
}

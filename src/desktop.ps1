$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
    if ($taskbarSource) {
        try {
            Add-Type -TypeDefinition $taskbarSource
            [VoltDeckTaskbar]::Initialize()
        } catch { Write-Verbose $_.Exception.Message }
    }
    Initialize-Settings $english $additionalLocales
    Localize-Markup $layout
    $window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($layout))
    if ($uiCulture.TextInfo.IsRightToLeft) { $window.FlowDirection = 'RightToLeft' }
    Set-ToolTheme $window $settings
    $window.Add_SourceInitialized({
        if ('VoltDeckTaskbar' -as [type]) {
            try {
                $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
                [VoltDeckTaskbar]::SetWindow($handle, $env:DRIVER_TOOL_EXE)
            } catch { Write-Verbose $_.Exception.Message }
        }
    })
    try {
        $icon = [Drawing.Icon]::ExtractAssociatedIcon($env:DRIVER_TOOL_EXE)
        try {
            $window.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $icon.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        } finally { if ($icon) { $icon.Dispose() } }
    } catch { Write-Verbose $_.Exception.Message }
    $actions = $window.FindName('Actions')
    $scanButton = $window.FindName('ScanButton')
    $orbitPath = $window.FindName('ScanOrbit')
    $orbit = $orbitPath.RenderTransform.Clone()
    $orbitPath.RenderTransform = $orbit
    $glow = $window.FindName('ScanGlow')
    $emptyState = $window.FindName('EmptyState')
    $emptyTitle = $window.FindName('EmptyTitle')
    $emptyDescription = $window.FindName('EmptyDescription')
    $heroTitle = $window.FindName('HeroTitle')
    $adminButton = $window.FindName('AdminButton')
    $installButton = $window.FindName('InstallButton')
    $compareButton = $window.FindName('CompareButton')
    $status = $window.FindName('Status')
    $updates = $window.FindName('Updates')
    $output = $window.FindName('Output')
    $frame = $window.FindName('WindowFrame')
    $titleBar = $window.FindName('TitleBar')
    $maximize = $window.FindName('MaximizeButton')
    $maximize.Add_Click({
        $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    })
    $window.Add_StateChanged({
        $maximized = $window.WindowState -eq 'Maximized'
        $frame.CornerRadius = if ($maximized) { '0' } else { '19' }
        $titleBar.CornerRadius = if ($maximized) { '0' } else { '18,18,0,0' }
        $maximize.Content = if ($maximized) { '❐' } else { '□' }
    })
    $titleBar.Add_MouseLeftButtonDown({ param($sender, $eventArgs)
        if ($eventArgs.ClickCount -eq 2) {
            $maximize.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        } elseif ($window.WindowState -eq 'Normal') {
            $window.DragMove()
        }
    })
    $window.FindName('MinimizeButton').Add_Click({ $window.WindowState = 'Minimized' })
    $window.FindName('CloseButton').Add_Click({ $window.Close() })
    $window.FindName('SettingsButton').Add_Click({ Show-Settings $window })
    $window.FindName('DiscordButton').Add_Click({ Open-Discord })
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $adminButton.Visibility = if ($isAdmin) { 'Collapsed' } else { 'Visible' }
    $window.FindName('AdminBadge').Visibility = if ($isAdmin) { 'Visible' } else { 'Collapsed' }
    $script:job = $null

    function Set-ScanAnimation([bool] $active) {
        $angle = [Windows.Media.RotateTransform]::AngleProperty
        $opacity = [Windows.UIElement]::OpacityProperty
        if ($active) {
            $rotation = [Windows.Media.Animation.DoubleAnimation]::new(0, 360, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.55)))
            $rotation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $orbit.BeginAnimation($angle, $rotation)
            $pulse = [Windows.Media.Animation.DoubleAnimation]::new(0.08, 0.25, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(780)))
            $pulse.AutoReverse = $true
            $pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            if ([Windows.SystemParameters]::ClientAreaAnimation) { $glow.BeginAnimation($opacity, $pulse) }
        } else {
            $orbit.BeginAnimation($angle, $null)
            $glow.BeginAnimation($opacity, $null)
        }
    }

    function Get-DriverIcon([string] $class, [string] $title) {
        switch -Regex ("$class $title") {
            'Display|GeForce|Radeon|Grafik' { return 'M 1,2 H 19 V 14 H 1 Z M 10,14 V 18 M 5,18 H 15' }
            'Net\b|Ethernet|Wi-Fi|Wireless|Bluetooth' { return 'M 2,7 Q 10,0 18,7 M 5,10 Q 10,5 15,10 M 8,13 Q 10,11 12,13 M 10,16 L 10,17' }
            'Media\b|Audio|Sound' { return 'M 2,7 H 6 L 11,3 V 17 L 6,13 H 2 Z M 14,7 Q 17,10 14,13 M 16,4 Q 22,10 16,16' }
            default { return 'M 4,4 H 16 V 16 H 4 Z M 8,8 H 12 V 12 H 8 Z M 1,7 H 4 M 1,13 H 4 M 16,7 H 19 M 16,13 H 19 M 7,1 V 4 M 13,1 V 4 M 7,16 V 19 M 13,16 V 19' }
        }
    }

    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $worker = [Text.Encoding]::UTF8.GetBytes($backend.ToString())
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $autoTimer = [Windows.Threading.DispatcherTimer]::new()
    $autoTimer.Interval = [TimeSpan]::FromMinutes(30)
    $autoTimer.Add_Tick({
        if ($null -eq $job -and $window.IsActive) {
            Start-Operation 'game-auto' (Get-Text 'Prüfe auf automatisch installierbare Game-Ready-Updates …')
        }
    })

    function Start-Operation($action, $label, $selected, $destination) {
        $startInfo = [Diagnostics.ProcessStartInfo]::new($shell)
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -OutputFormat Text -Command "[Console]::InputEncoding = [Text.Encoding]::UTF8; [Console]::OutputEncoding = [Text.Encoding]::UTF8; $ProgressPreference = ''SilentlyContinue''; & ([scriptblock]::Create([Console]::In.ReadToEnd()))"'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
        $startInfo.EnvironmentVariables['DRIVER_TOOL_ACTION'] = $action
        if ($null -ne $selected) {
            $startInfo.EnvironmentVariables['DRIVER_TOOL_ID'] = $selected.ID
            $startInfo.EnvironmentVariables['DRIVER_TOOL_REVISION'] = [string] $selected.Revision
        }
        if ($destination) { $startInfo.EnvironmentVariables['DRIVER_TOOL_BACKUP'] = $destination }
        try {
            $process = [Diagnostics.Process]::Start($startInfo)
            $readOutput = $process.StandardOutput.ReadToEndAsync()
            $readError = $process.StandardError.ReadToEndAsync()
            try { $process.StandardInput.BaseStream.Write($worker, 0, $worker.Length) }
            finally { $process.StandardInput.Close() }
        } catch {
            if ($process) { $process.Dispose() }
            $status.Text = (Get-Text 'Windows PowerShell konnte nicht gestartet werden.')
            $emptyState.Visibility = 'Collapsed'
            $output.Visibility = 'Visible'
            $output.Text = $_.Exception.Message
            return
        }
        $script:job = @{
            Action = $action
            Process = $process
            Output = $readOutput
            Error = $readError
        }
        $actions.IsEnabled = $adminButton.IsEnabled = $installButton.IsEnabled = $scanButton.IsEnabled = $false
        $updates.ItemsSource = $null
        $updates.Visibility = 'Collapsed'
        $output.Visibility = 'Collapsed'
        $output.Clear()
        $emptyTitle.Text = (Get-Text 'Bitte warten')
        $emptyDescription.Text = (Get-Text 'Das Ergebnis erscheint nach Abschluss des Vorgangs.')
        $emptyState.Visibility = 'Visible'
        $isScan = $action -in 'scan-ui', 'game-auto'
        $heroTitle.Text = if ($isScan) { (Get-Text 'Treiber werden geprüft') } else { (Get-Text 'Treiber verwalten') }
        $status.Text = $label
        Set-ScanAnimation $isScan
        $timer.Start()
    }

    $timer.Add_Tick({
        if (-not ($job.Process.HasExited -and $job.Output.IsCompleted -and $job.Error.IsCompleted)) { return }
        $timer.Stop()
        Set-ScanAnimation $false
        $heroTitle.Text = (Get-Text 'Treiber prüfen')
        $emptyState.Visibility = 'Collapsed'
        $output.Visibility = 'Visible'
        try {
            $stdout = $job.Output.GetAwaiter().GetResult().Trim()
            $stderr = $job.Error.GetAwaiter().GetResult().Trim()
            if ($job.Process.ExitCode -ne 0) {
                $status.Text = (Get-Text 'Der Vorgang ist fehlgeschlagen.')
                $output.Text = "$stdout`r`n$stderr".Trim()
                if ($job.Action -eq 'game-auto') { $autoTimer.Stop() }
            } elseif ($job.Action -in 'scan-ui', 'inventory-ui') {
                $items = ConvertFrom-Json -InputObject $stdout
                $isInventory = $job.Action -eq 'inventory-ui'
                $status.Text = if ($isInventory) { (Get-Text '{0} installierte Treiber gefunden.') -f $items.Count } else { (Get-Text '{0} passende Treiberupdates gefunden.') -f $items.Count }
                if ($items.Count) {
                    $heroTitle.Text = if ($isInventory) { (Get-Text 'Installierte Treiber') } else { (Get-Text 'Updates verfügbar') }
                    foreach ($item in $items) {
                        $item.Details = Get-Text $item.Details
                        $item.Datumsart = Get-Text $item.Datumsart
                        $geometry = [Windows.Media.Geometry]::Parse((Get-DriverIcon $item.Klasse $item.Treiber))
                        Add-Member -InputObject $item -NotePropertyName IconPath -NotePropertyValue $geometry
                    }
                    $updates.ItemsSource = $items
                    $updates.Visibility = 'Visible'
                    $output.Visibility = 'Collapsed'
                } else {
                    $heroTitle.Text = if ($isInventory) { (Get-Text 'Installierte Treiber') } else { (Get-Text 'Keine Updates gefunden') }
                    $emptyTitle.Text = if ($isInventory) { (Get-Text 'Keine Treiber aufgelistet') } else { (Get-Text 'Keine passenden Updates') }
                    $emptyDescription.Text = if ($isInventory) { (Get-Text 'Windows hat keine installierten Treiber gemeldet.') } else { (Get-Text 'Windows Update hat derzeit keine passenden Treiber gemeldet.') }
                    $output.Visibility = 'Collapsed'
                    $emptyState.Visibility = 'Visible'
                }
            } else {
                $status.Text = (Get-Text 'Vorgang abgeschlossen.')
                $output.Text = $stdout
            }
        } catch {
            $status.Text = (Get-Text 'Das Ergebnis konnte nicht angezeigt werden.')
            $output.Text = $_.Exception.Message
        } finally {
            $job.Process.Dispose()
            $script:job = $null
            $actions.IsEnabled = $adminButton.IsEnabled = $scanButton.IsEnabled = $true
        }
    })

    function Request-Admin {
        try {
            Start-Process -FilePath $env:DRIVER_TOOL_EXE -Verb RunAs
            $window.Close()
        } catch {
            $status.Text = (Get-Text 'Die Oberfläche wurde ohne Administratorrechte geöffnet.')
        }
    }

    $adminButton.Add_Click({ Request-Admin })
    $scanButton.Add_Click({ Start-Operation 'scan-ui' (Get-Text 'Suche nach passenden Treiberupdates …') })
    $window.FindName('InventoryButton').Add_Click({ Start-Operation 'inventory-ui' (Get-Text 'Installierte Treiber werden gelesen …') })
    $window.FindName('ProblemsButton').Add_Click({ Start-Operation 'problems' (Get-Text 'Geräte werden geprüft …') })
    $window.FindName('GamingButton').Add_Click({ Show-Gaming $window $autoTimer $isAdmin })
    $window.FindName('HistoryButton').Add_Click({ Show-DriverHistory $window })
    $window.FindName('BoostButton').Add_Click({ Show-Boost $window })
    if ($env:DRIVER_TOOL_OPEN_BOOST -eq '1') {
        $window.Add_ContentRendered({
            if ($env:DRIVER_TOOL_OPEN_BOOST -eq '1') {
                $env:DRIVER_TOOL_OPEN_BOOST = '0'
                Show-Boost $window
            }
        })
    }
    $window.FindName('BackupButton').Add_Click({
        if (-not $isAdmin) { Request-Admin; return }
        $picker = [Windows.Forms.FolderBrowserDialog]::new()
        try {
            $picker.Description = (Get-Text 'Wähle den Ordner, in dem die Sicherung angelegt werden soll.')
            if ($picker.ShowDialog() -eq 'OK') {
                $destination = Join-Path $picker.SelectedPath ('Treiber-Sicherung-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
                Start-Operation 'backup' (Get-Text 'Treiberpakete werden exportiert …') $null $destination
            }
        } finally {
            $picker.Dispose()
        }
    })
    $updates.Add_SelectionChanged({
        $installButton.IsEnabled = [bool] $updates.SelectedItem.ID
        $compareButton.IsEnabled = [bool] $updates.SelectedItem.Comparison
    })
    $compareButton.Add_Click({ Show-DriverComparison $window $updates.SelectedItem.Treiber $updates.SelectedItem.Comparison })
    $installButton.Add_Click({
        $selected = $updates.SelectedItem
        if (-not $selected.ID) { return }
        if (-not $isAdmin) { Request-Admin; return }
        $prompt = (Get-Text 'Dieses Treiberupdate installieren?') + "`n`n$($selected.Treiber)"
        if ($selected.Lizenz) {
            $license = New-ToolDialog $window 'Lizenzbedingungen des Treiberupdates'
            $license.Width = 670
            $licenseText = [Windows.Controls.TextBox]::new()
            $licenseText.Text = $selected.Lizenz
            $licenseText.TextWrapping = 'Wrap'
            $licenseText.VerticalScrollBarVisibility = 'Auto'
            $licenseText.IsReadOnly = $true
            $licenseText.Padding = '16'
            $licenseText.Height = 380
            $licenseText.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'ThemeBase')
            $licenseText.Foreground = '#EDF3FF'
            [void] $license.FindName('Content').Children.Add($licenseText)
            [void] $license.ShowDialog()
            $prompt += "`n`n" + (Get-Text 'Mit Installieren akzeptierst du die zuvor angezeigten Lizenzbedingungen.')
        }
        if (Confirm-DriverInstall $window $prompt) {
            Start-Operation 'install' (Get-Text 'Update wird heruntergeladen und installiert …') $selected
        }
    })
    $window.Add_Closing({ param($sender, $eventArgs)
        if ($null -ne $job) {
            $eventArgs.Cancel = $true
        }
    })
    [void] $window.ShowDialog()
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

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
    $actions.Add_SizeChanged({
        param($sender, $eventArgs)
        $columns = if ($eventArgs.NewSize.Width -ge 775) { 6 } else { 3 }
        if ($sender.Columns -ne $columns) { $sender.Columns = $columns }
    })
    $scanButton = $window.FindName('ScanButton')
    $onlineButton = $window.FindName('OnlineButton')
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
    $detailsButton = $window.FindName('DetailsButton')
    $pinButton = $window.FindName('PinButton')
    $searchBox = $window.FindName('SearchBox')
    $filterPanel = $window.FindName('Filters')
    $inventoryButton = $window.FindName('InventoryButton')
    $problemsButton = $window.FindName('ProblemsButton')
    $dashboardClock = $window.FindName('DashboardClock')
    $dashboardDate = $window.FindName('DashboardDate')
    $restoreWidget = $window.FindName('RestoreWidget')
    $testWidget = $window.FindName('TestWidget')
    $planWidget = $window.FindName('PlanWidget')
    $script:rows = @()
    $script:problemView = $false
    $script:filters = @{ category = ''; status = ''; manufacturer = ''; since = $null; recommended = $false; problems = $false }
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
    $window.FindName('AboutButton').Add_Click({ Show-VoltDeckAbout $window })
    $window.FindName('DiscordButton').Add_Click({ Open-Discord })
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $adminButton.Visibility = if ($isAdmin) { 'Collapsed' } else { 'Visible' }
    $window.FindName('AdminBadge').Visibility = if ($isAdmin) { 'Visible' } else { 'Collapsed' }
    $script:job = $null
    $script:onlineAccess = $false
    $onlineButton.Add_Click({ Set-OnlineAccess })
    $notify = [Windows.Forms.NotifyIcon]::new()
    try { $notify.Icon = [Drawing.Icon]::ExtractAssociatedIcon($env:DRIVER_TOOL_EXE) }
    catch { $notify.Icon = [Drawing.SystemIcons]::Information }
    $notify.Text = 'VoltDeck'
    $notify.Add_BalloonTipClosed({ $notify.Visible = $false })
    $window.Add_Closed({ $notify.Dispose() })

    function Update-DashboardWidgets {
        $now = [datetime]::Now
        $dashboardClock.Text = $now.ToString('t', $uiCulture)
        $dashboardDate.Text = $now.ToString('D', $uiCulture)
        $restoreWidget.Text = Get-Text $(if ($settings.restorePoint) { 'Wiederherstellungspunkt · Aktiv' } else { 'Wiederherstellungspunkt · Aus' })
        $testWidget.Text = Get-Text $(if ($settings.safeMode) { 'Testmodus · Aktiv' } else { 'Testmodus · Aus' })
        $planWidget.Text = Get-Text $(switch ($settings.planHours) {
            24 { 'Update-Plan · Täglich' }
            168 { 'Update-Plan · Wöchentlich' }
            default { 'Update-Plan · Aus' }
        })
    }

    Update-DashboardWidgets

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
        if ($null -eq $job -and $window.IsActive -and -not $settings.safeMode) {
            Start-Operation 'game-auto' (Get-Text 'Prüfe auf automatisch installierbare Game-Ready-Updates …')
        }
    })
    $planTimer = [Windows.Threading.DispatcherTimer]::new()
    $planTimer.Interval = [TimeSpan]::FromSeconds(5)
    $script:lastPlanAttempt = [datetimeoffset]::MinValue
    $planTimer.Add_Tick({
        Update-DashboardWidgets
        if ((Get-ToolAppearance) -ne $activeAppearance) { Set-ToolTheme $window $settings }
        if (-not $onlineAccess -or -not $settings.planHours -or $job -or @($window.OwnedWindows | Where-Object IsVisible).Count) { return }
        $now = [datetimeoffset]::Now
        $last = [datetimeoffset]::MinValue
        [void] [datetimeoffset]::TryParse($settings.lastPlanCheck, [ref] $last)
        if (($now - $last).TotalHours -ge $settings.planHours -and ($now - $lastPlanAttempt).TotalMinutes -ge 15) {
            $script:lastPlanAttempt = $now
            Start-Operation 'plan-scan' (Get-Text 'Geplante Treiberprüfung …')
        }
    })
    $planTimer.Start()
    $window.Add_Closed({ $planTimer.Stop(); $autoTimer.Stop() })

    function Start-Operation($action, $label, $selected, $destination) {
        if ($job) { return }
        if ($action -in 'scan-ui','prepare','install','game-auto','plan-scan' -and -not $onlineAccess) {
            if ($action -notin 'scan-ui','prepare','install' -or -not (Request-OnlineAccess)) { return }
        }
        $startInfo = [Diagnostics.ProcessStartInfo]::new($shell)
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -OutputFormat Text -Command "$env:PSModulePath = Join-Path $PSHOME ''Modules''; [Console]::InputEncoding = [Text.Encoding]::UTF8; [Console]::OutputEncoding = [Text.Encoding]::UTF8; $ProgressPreference = ''SilentlyContinue''; & ([scriptblock]::Create([Console]::In.ReadToEnd()))"'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WorkingDirectory = [Environment]::SystemDirectory
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
        $startInfo.EnvironmentVariables['DRIVER_TOOL_ACTION'] = if ($action -eq 'plan-scan') { 'scan-ui' } else { $action }
        $startInfo.EnvironmentVariables['VOLTDECK_ONLINE'] = [string] [int] $onlineAccess
        $startInfo.EnvironmentVariables['VOLTDECK_RESTORE_POINT'] = [string] [int] $settings.restorePoint
        $startInfo.EnvironmentVariables['VOLTDECK_REQUIRE_CACHE'] = [string] [int] $settings.safeMode
        $startInfo.EnvironmentVariables['VOLTDECK_PROTECT_CRITICAL'] = [string] [int] $settings.protectCritical
        $startInfo.EnvironmentVariables['VOLTDECK_VERIFIED_BACKUP'] = '1'
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
            Selected = $selected
        }
        $actions.IsEnabled = $adminButton.IsEnabled = $installButton.IsEnabled = $scanButton.IsEnabled = $onlineButton.IsEnabled =
            $filterPanel.IsEnabled = $inventoryButton.IsEnabled = $problemsButton.IsEnabled = $false
        if ($action -ne 'prepare') { $script:rows = @() }
        $updates.ItemsSource = $null
        $updates.Visibility = 'Collapsed'
        $output.Visibility = 'Collapsed'
        $output.Clear()
        $emptyTitle.Text = (Get-Text 'Bitte warten')
        $emptyDescription.Text = (Get-Text 'Das Ergebnis erscheint nach Abschluss des Vorgangs.')
        $emptyState.Visibility = 'Visible'
        $isScan = $action -in 'scan-ui', 'plan-scan', 'game-auto'
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
            } elseif ($job.Action -in 'scan-ui', 'plan-scan','inventory-ui','problems-ui') {
                $items = ConvertFrom-Json -InputObject $stdout
                $isInventory = $job.Action -in 'inventory-ui','problems-ui'
                $script:rows = @($items | Where-Object { $null -ne $_ })
                $script:problemView = $job.Action -eq 'problems-ui'
                $status.Text = if ($isInventory) { (Get-Text '{0} installierte Treiber gefunden.') -f $items.Count } else { (Get-Text '{0} passende Treiberupdates gefunden.') -f $items.Count }
                if ($items.Count) {
                    $heroTitle.Text = if ($job.Action -eq 'problems-ui') { Get-Text 'Geräteprobleme' } elseif ($isInventory) { Get-Text 'Installierte Treiber' } else { Get-Text 'Updates verfügbar' }
                    foreach ($item in $items) {
                        $item.Details = Get-Text $item.Details
                        $item.Datumsart = Get-Text $item.Datumsart
                        $geometry = [Windows.Media.Geometry]::Parse((Get-DriverIcon $item.Klasse $item.Treiber))
                        Add-Member -InputObject $item -NotePropertyName IconPath -NotePropertyValue $geometry
                        Add-Member -InputObject $item -NotePropertyName Badge -NotePropertyValue ''
                        Add-Member -InputObject $item -NotePropertyName Pinned -NotePropertyValue $false
                    }
                    Update-DriverList
                    $output.Visibility = 'Collapsed'
                } else {
                    $heroTitle.Text = if ($isInventory) { (Get-Text 'Installierte Treiber') } else { (Get-Text 'Keine Updates gefunden') }
                    $emptyTitle.Text = if ($isInventory) { (Get-Text 'Keine Treiber aufgelistet') } else { (Get-Text 'Keine passenden Updates') }
                    $emptyDescription.Text = if ($isInventory) { (Get-Text 'Windows hat keine installierten Treiber gemeldet.') } else { (Get-Text 'Windows Update hat derzeit keine passenden Treiber gemeldet.') }
                    $output.Visibility = 'Collapsed'
                    $emptyState.Visibility = 'Visible'
                }
                if ($job.Action -eq 'plan-scan') {
                    if ($items.Count) {
                        $notify.Visible = $true
                        $notify.ShowBalloonTip(6000, 'VoltDeck', ((Get-Text '{0} passende Treiberupdates gefunden.') -f $items.Count), 'Info')
                    }
                    $next = $settings.Clone()
                    $next.lastPlanCheck = [datetimeoffset]::Now.ToString('o')
                    Save-ToolSettings $next
                }
            } elseif ($job.Action -eq 'prepare') {
                $job.Selected.Downloaded = $true
                $job.Selected.Lizenz = $null
                $output.Visibility = 'Collapsed'
                Update-DriverList
                if ($updates.Items.Contains($job.Selected)) { $updates.SelectedItem = $job.Selected }
                $status.Text = Get-Text 'Windows Update bestätigt den vollständigen Download.'
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
            $actions.IsEnabled = $adminButton.IsEnabled = $scanButton.IsEnabled = $onlineButton.IsEnabled =
                $filterPanel.IsEnabled = $inventoryButton.IsEnabled = $problemsButton.IsEnabled = $true
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
    $inventoryButton.Add_Click({ Start-Operation 'inventory-ui' (Get-Text 'Installierte Treiber werden gelesen …') })
    $problemsButton.Add_Click({ Start-Operation 'problems-ui' (Get-Text 'Geräte werden geprüft …') })
    $window.FindName('GamingButton').Add_Click({ Show-Gaming $window $autoTimer ($isAdmin -and -not $settings.safeMode) })
    $window.FindName('ToolsButton').Add_Click({ Show-SafetyTools $window; Update-DashboardWidgets })
    $window.FindName('FilterButton').Add_Click({ Show-DriverFilters $window })
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
    $window.FindName('BackupButton').Add_Click({ Select-DriverFolder 'backup' })
    $searchBox.Add_TextChanged({ if (-not $job) { Update-DriverList } })
    $window.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq 'F' -and [Windows.Input.Keyboard]::Modifiers -eq 'Control' -and $searchBox.IsEnabled) {
            [void] $searchBox.Focus()
            $searchBox.SelectAll()
            $eventArgs.Handled = $true
        }
    })
    $updates.ContextMenu.Items[0].Header = Get-Text 'Details kopieren'
    $updates.ContextMenu.Items[0].Add_Click({ if ($updates.SelectedItem) { Copy-DriverDetails (Get-DetailText $updates.SelectedItem) } })
    $updates.Add_PreviewMouseRightButtonDown({
        param($sender, $eventArgs)
        $container = [Windows.Controls.ItemsControl]::ContainerFromElement($updates, $eventArgs.OriginalSource)
        if ($container -is [Windows.Controls.ListBoxItem]) { $container.IsSelected = $true }
    })
    $detailsButton.Add_Click({ Show-DeviceDetails $window $updates.SelectedItem })
    $updates.Add_MouseDoubleClick({ if ($updates.SelectedItem) { Show-DeviceDetails $window $updates.SelectedItem } })
    $pinButton.Add_Click({
        $key = Get-DriverKey $updates.SelectedItem
        if (-not $key) { return }
        $new = $settings.Clone()
        $new.pins = @(if ($key -in $settings.pins) { $settings.pins | Where-Object { $_ -ne $key } } else { @($settings.pins) + $key })
        try { Save-ToolSettings $new; Update-DriverList } catch { $status.Text = $_.Exception.Message }
    })
    $updates.Add_SelectionChanged({
        $installButton.IsEnabled = [bool] ($updates.SelectedItem.ID -and -not $updates.SelectedItem.Interactive)
        $compareButton.IsEnabled = [bool] $updates.SelectedItem.Comparison
        $detailsButton.IsEnabled = [bool] $updates.SelectedItem
        $pinButton.IsEnabled = [bool] (Get-DriverKey $updates.SelectedItem)
        $installButton.Content = if ($settings.safeMode -and $updates.SelectedItem.ID -and -not $updates.SelectedItem.Downloaded) {
            Get-Text 'Download prüfen'
        } else { Get-Text 'Ausgewähltes Update installieren' }
    })
    $compareButton.Add_Click({ Show-DriverComparison $window $updates.SelectedItem.Treiber $updates.SelectedItem.Comparison })
    $installButton.Add_Click({
        $selected = $updates.SelectedItem
        if (-not $selected.ID) { return }
        if (-not $isAdmin) { Request-Admin; return }
        $prepare = $settings.safeMode -and -not $selected.Downloaded
        $prompt = (Get-Text $(if ($prepare) { 'Dieses Update zunächst nur herunterladen?' } else { 'Dieses Treiberupdate installieren?' })) + "`n`n$($selected.Treiber)"
        if (-not $prepare -and $settings.restorePoint) {
            $prompt += "`n`n" + (Get-Text 'VoltDeck wartet vor der Installation auf einen bestätigten Wiederherstellungspunkt.')
        }
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
            $licenseText.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'ThemeText')
            [void] $license.FindName('Content').Children.Add($licenseText)
            [void] $license.ShowDialog()
            $prompt += "`n`n" + (Get-Text 'Mit der Bestätigung akzeptierst du die angezeigten Lizenzbedingungen.')
        }
        if ($prepare) {
            if (Confirm-DriverInstall $window $prompt 'Download prüfen' 'Download prüfen') {
                Start-Operation 'prepare' (Get-Text 'Treiber wird heruntergeladen und geprüft …') $selected
            }
        } elseif (Confirm-DriverInstall $window $prompt) {
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

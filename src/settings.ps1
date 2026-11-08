function Get-Text([string] $text) {
    if ($script:translations.ContainsKey($text)) { return $script:translations[$text] }
    return $text
}

function Localize-Markup([xml] $document) {
    foreach ($attribute in $document.SelectNodes('//@Text | //@Content | //@ToolTip | //@*[name()="AutomationProperties.Name"]')) {
        if (-not $attribute.Value.StartsWith('{')) {
            $localized = Get-Text $attribute.Value
            $attribute.Value = if ($localized.StartsWith('{')) { '{}' + $localized } else { $localized }
        }
    }
}

function Initialize-Settings($english, $additionalLocales) {
    $script:settingsDirectory = if ($env:VOLTDECK_PORTABLE_DATA) { $env:VOLTDECK_PORTABLE_DATA } else {
        Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DriverTool'
    }
    $script:settingsPath = Join-Path $settingsDirectory 'settings.json'
    $script:themes = [ordered] @{
        ocean = @('#172640', '#121B31', '#24204A', '#7BE8DB')
        violet = @('#2A1D45', '#201934', '#392557', '#D5AEFF')
        sunset = @('#462738', '#2B2033', '#593529', '#FFB497')
        graphite = @('#252B38', '#1A202A', '#333B49', '#D7E1F2')
    }
    $script:settings = @{ language = 'system'; theme = 'ocean'; gradient = $true }
    try {
        if (Test-Path -LiteralPath $settingsPath) {
            $saved = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.language -is [string]) { $settings.language = $saved.language }
            if ($themes.Contains([string] $saved.theme)) { $settings.theme = $saved.theme }
            if ($saved.gradient -is [bool]) { $settings.gradient = $saved.gradient }
        }
    } catch { Write-Verbose $_.Exception.Message }

    $script:languages = [ordered] @{
        de = @{ name = 'Deutsch'; strings = $null }
        en = @{ name = 'English'; strings = (ConvertFrom-Json $english) }
    }
    foreach ($locale in (ConvertFrom-Json $additionalLocales).PSObject.Properties) {
        $languages[$locale.Name] = $locale.Value
    }
    if ($env:DRIVER_TOOL_EXE) {
        $localeDirectory = Join-Path (Split-Path -Parent $env:DRIVER_TOOL_EXE) 'locales'
        if (Test-Path -LiteralPath $localeDirectory) {
            foreach ($file in Get-ChildItem -LiteralPath $localeDirectory -Filter '*.json' -File) {
                try {
                    $culture = [Globalization.CultureInfo]::GetCultureInfo($file.BaseName)
                    $locale = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($locale.name -is [string] -and $locale.name.Trim() -and $locale.strings) { $languages[$culture.Name] = $locale }
                } catch { Write-Verbose $_.Exception.Message }
            }
        }
    }
    $selected = $settings.language
    if ($selected -eq 'system') {
        $culture = [Globalization.CultureInfo]::CurrentUICulture
        $selected = $culture.Name
        while ($selected -and -not $languages.Contains($selected)) {
            $culture = $culture.Parent
            $selected = $culture.Name
        }
    }
    if (-not $languages.Contains($selected)) { $selected = 'en' }
    $script:uiCulture = [Globalization.CultureInfo]::GetCultureInfo($selected)
    $script:translations = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    if ($selected -ne 'de') {
        foreach ($catalog in @($languages['en'].strings, $languages[$selected].strings)) {
            if ($catalog) {
                foreach ($entry in $catalog.PSObject.Properties) {
                    if ($entry.Value -is [string] -and $entry.Value) { $translations[$entry.Name] = $entry.Value }
                }
            }
        }
    }
}

function Open-Discord {
    try { Start-Process 'https://discord.gg/8JGu5Ecerh' }
    catch { $status.Text = $_.Exception.Message }
}

function Set-ToolTheme($owner, $preferences) {
    $palette = $themes[$preferences.theme]
    $converter = [Windows.Media.BrushConverter]::new()
    $accent = [Windows.Media.ColorConverter]::ConvertFromString($palette[3])
    foreach ($surface in @{ ThemeBase = 0.045; ThemeSurface = 0.085; ThemeControl = 0.15; ThemeBorder = 0.28; ThemeSelected = 0.34 }.GetEnumerator()) {
        $factor = $surface.Value
        $color = [Windows.Media.Color]::FromRgb(
            [byte] (9 + $accent.R * $factor), [byte] (10 + $accent.G * $factor), [byte] (18 + $accent.B * $factor))
        $owner.Resources[$surface.Key] = [Windows.Media.SolidColorBrush]::new($color)
    }
    $owner.Resources['ThemeAccent'] = [Windows.Media.SolidColorBrush]::new($accent)
    if ($preferences.gradient) {
        $gradient = [Windows.Media.LinearGradientBrush]::new()
        $gradient.StartPoint = [Windows.Point]::new(0, 0)
        $gradient.EndPoint = [Windows.Point]::new(1, 1)
        for ($i = 0; $i -lt 3; $i++) {
            $gradient.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.ColorConverter]::ConvertFromString($palette[$i]), $i / 2.0))
        }
        $owner.Resources['ThemeHero'] = $gradient
    } else {
        $owner.Resources['ThemeHero'] = $converter.ConvertFromString($palette[0])
    }
}

function Add-SettingsCard($panel, [string] $title) {
    $card = [Windows.Controls.Border]::new()
    $card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'ThemeControl')
    $card.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'ThemeBorder')
    $card.BorderThickness = '1'
    $card.CornerRadius = '16'
    $card.Padding = '15,12'
    $card.Margin = '0,0,0,12'
    $content = [Windows.Controls.StackPanel]::new()
    $card.Child = $content
    [void] $panel.Children.Add($card)
    $heading = Add-ToolText $content $title
    $heading.FontSize = 16
    $heading.FontWeight = 'SemiBold'
    $heading.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'ThemeAccent')
    return $content
}

function New-SettingsPicker($panel, $owner) {
    $picker = [Windows.Controls.ListBox]::new()
    $picker.DisplayMemberPath = 'Label'
    $picker.SelectedValuePath = 'Key'
    $picker.ItemContainerStyle = $owner.FindResource([Windows.Controls.ListBoxItem])
    $picker.Background = 'Transparent'
    $picker.BorderThickness = '0'
    $picker.MaxHeight = 126
    [Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($picker, 'Disabled')
    $wrap = [Windows.FrameworkElementFactory]::new([Windows.Controls.WrapPanel])
    $picker.ItemsPanel = [Windows.Controls.ItemsPanelTemplate]::new($wrap)
    [void] $panel.Children.Add($picker)
    return $picker
}

function Show-Settings($owner) {
    $dialog = New-ToolDialog $owner 'Einstellungen'
    $dialog.Width = 650
    $panel = $dialog.FindName('Content')
    $languageCard = Add-SettingsCard $panel 'Sprache'
    $languagePicker = New-SettingsPicker $languageCard $owner
    $languagePicker.ItemsSource = @([pscustomobject] @{ Key = 'system'; Label = (Get-Text 'Windows-Sprache') }) + @(foreach ($language in $languages.GetEnumerator()) {
        [pscustomobject] @{ Key = $language.Key; Label = $language.Value.name }
    })
    $languagePicker.SelectedValue = $settings.language
    if ($languagePicker.SelectedIndex -lt 0) { $languagePicker.SelectedIndex = 0 }
    $themeCard = Add-SettingsCard $panel 'Farbdesign'
    $themePicker = New-SettingsPicker $themeCard $owner
    $themePicker.DisplayMemberPath = ''
    $themePicker.ItemTemplate = $owner.FindResource('ThemeSwatch')
    $themePicker.ItemsSource = @(
        [pscustomobject] @{ Key = 'ocean'; Label = (Get-Text 'Ozean · Türkis'); Swatch = $themes.ocean[3] }
        [pscustomobject] @{ Key = 'violet'; Label = (Get-Text 'Nebel · Violett'); Swatch = $themes.violet[3] }
        [pscustomobject] @{ Key = 'sunset'; Label = (Get-Text 'Sonnenuntergang · Koralle'); Swatch = $themes.sunset[3] }
        [pscustomobject] @{ Key = 'graphite'; Label = (Get-Text 'Graphit · Silber'); Swatch = $themes.graphite[3] }
    )
    $themePicker.SelectedValue = $settings.theme
    $gradient = [Windows.Controls.CheckBox]::new()
    $gradient.Style = $owner.FindResource('SettingsToggle')
    $gradient.Content = Get-Text 'Farbverlauf verwenden'
    $gradient.Foreground = '#EDF3FF'
    $gradient.IsChecked = $settings.gradient
    $gradient.Margin = '5,10,0,2'
    [void] $themeCard.Children.Add($gradient)
    $credits = Add-SettingsCard $panel 'Credits'
    $names = Add-ToolText $credits 'LokiFieber  +  OpenAI Codex'
    $names.FontSize = 20
    $names.FontWeight = 'SemiBold'
    $names.Margin = '0,0,0,3'
    [void] (Add-ToolText $credits 'Projekt, Entwicklung und Design')
    $notice = Add-ToolText $panel 'Eine Sprachänderung wird beim nächsten Start wirksam.'
    $buttons = [Windows.Controls.WrapPanel]::new()
    [void] $panel.Children.Add($buttons)
    $save = Add-ToolButton $buttons $owner 'Speichern'
    $save.Tag = @{ Language = $languagePicker; Theme = $themePicker; Gradient = $gradient; Owner = $owner; Notice = $notice }
    $save.Foreground = '#081B22'
    $save.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'ThemeAccent')
    $save.Add_Click({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $newSettings = @{ language = [string] $controls.Language.SelectedValue; theme = [string] $controls.Theme.SelectedValue; gradient = [bool] $controls.Gradient.IsChecked }
        try {
            [void] [IO.Directory]::CreateDirectory($settingsDirectory)
            $temporary = Join-Path $settingsDirectory ('.settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $newSettings), [Text.UTF8Encoding]::new($false))
                if (Test-Path -LiteralPath $settingsPath) { [IO.File]::Replace($temporary, $settingsPath, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $settingsPath) }
            } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
            $script:settings = $newSettings
            Set-ToolTheme $controls.Owner $settings
            $controls.Notice.Text = Get-Text 'Gespeichert. Eine Sprachänderung wird beim nächsten Start wirksam.'
        } catch { $controls.Notice.Text = $_.Exception.Message }
    })
    [void] $dialog.ShowDialog()
}

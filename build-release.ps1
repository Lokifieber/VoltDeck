param(
    [string] $Cargo = 'cargo',
    [string] $Compiler = 'ISCC.exe'
)

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    & .\build-desktop.ps1 -Cargo $Cargo
    $exe = Get-Item -LiteralPath '.\target\release\VoltDeck.exe'
    $version = $exe.VersionInfo.ProductVersion
    if ($version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { throw 'Ungültige Release-Version in der EXE.' }
    $output = New-Item -Path (Join-Path $PSScriptRoot 'dist') -ItemType Directory -Force
    $prefix = "VoltDeck-$version-Windows-x64"

    & $Compiler "/DReleaseVersion=$version" "/DNumericVersion=$($exe.VersionInfo.FileVersion)" "/O$($output.FullName)" '.\packaging\VoltDeck.iss'
    if ($LASTEXITCODE -ne 0) { throw 'Der Inno-Setup-Build ist fehlgeschlagen.' }
    $setup = Get-Item -LiteralPath (Join-Path $output.FullName "$prefix-Setup.exe")

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $portable = Join-Path $output.FullName "$prefix-Portable.zip"
    $stream = [IO.File]::Create($portable)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            [void] [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $exe.FullName, 'VoltDeck.exe')
            [void] $archive.CreateEntry('portable.flag')
            $guide = [IO.StreamWriter]::new($archive.CreateEntry('README.txt').Open())
            try {
                $guide.WriteLine('VoltDeck Portable | Windows x64 | Early Access')
                $guide.WriteLine('Entpacke alle Dateien in einen beschreibbaren Ordner und starte VoltDeck.exe.')
                $guide.WriteLine('portable.flag aktiviert den portablen Modus. Einstellungen und Treiberverlauf liegen unter data/.')
                $guide.WriteLine('Extract all files to a writable folder and launch VoltDeck.exe. Keep portable.flag beside the EXE.')
            } finally { $guide.Dispose() }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }

    Get-FileHash -Algorithm SHA256 -LiteralPath $setup.FullName, $portable | ForEach-Object {
        '{0}  {1}' -f $_.Hash.ToLowerInvariant(), [IO.Path]::GetFileName($_.Path)
    } | Set-Content -LiteralPath (Join-Path $output.FullName 'SHA256SUMS.txt') -Encoding Ascii
    Write-Output $setup.FullName, $portable
} finally {
    Pop-Location
}

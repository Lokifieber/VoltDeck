function Assert-LocalPath([string] $path) {
    if ($path -notmatch '^[A-Za-z]:\\' -or $path.Substring(2).Contains(':')) {
        throw 'Wähle einen Pfad auf einem lokalen Datenträger.'
    }
    $full = [IO.Path]::GetFullPath($path)
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    if ($drive.DriveType -notin [IO.DriveType]::Fixed, [IO.DriveType]::Removable) {
        throw 'Netzlaufwerke und andere nicht lokale Ziele werden für diese Aktion abgelehnt.'
    }
    for ($item = $full; $item; $item = [IO.Path]::GetDirectoryName($item)) {
        try {
            if ([IO.File]::GetAttributes($item) -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Dateiverknüpfungen und umgeleitete Ordner werden für diese Aktion abgelehnt.'
            }
        } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
            # The selected file or folder may be new. Check its existing parents.
        }
    }
}

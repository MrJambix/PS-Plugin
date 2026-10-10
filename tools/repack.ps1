# Rebuilds scripts/jcore.zip, scripts/jambix_aio.zip and scripts/jambix_market.zip
# from their folders.
#
# .NET ZipArchive rather than Compress-Archive: the 1.0.1 cmdlet writes
# backslash entry names, which the loader does not read. Entries are prefixed
# with the package folder ("jcore/main.lua") and use forward slashes; each
# folder has its own entry ("jcore/lib/").
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\repack.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\repack.ps1 jcore   # only these

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Names = @("jcore", "jambix_aio", "jambix_market")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts"
$slash = [string][char]47
$backslash = [string][char]92

foreach ($name in $Names) {
    $zipPath = Join-Path $root ($name + ".zip")
    $folder = Join-Path $root $name

    $old = @()
    if (Test-Path $zipPath) {
        $existing = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $old = @($existing.Entries | ForEach-Object { $_.FullName })
        $existing.Dispose()
    }

    $tmp = $zipPath + ".tmp"
    if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) }

    $stream = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    # A folder entry per folder ("jcore/", "jcore/lib/"), sorted ordinally
    # among the files (README.md before header.lua), as the zips uploaded to
    # project-sylvanas.net have carried. Sort-Object would ignore case.
    # Entry name -> source file ($null for a folder).
    $paths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    $paths[$name + $slash] = $null
    Get-ChildItem -Path $folder -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($folder.Length + 1).Replace($backslash, $slash)
        if ($_.PSIsContainer) {
            $paths[$name + $slash + $rel + $slash] = $null
        } else {
            $paths[$name + $slash + $rel] = $_.FullName
        }
    }
    $keys = New-Object 'System.Collections.Generic.List[string]'
    $keys.AddRange($paths.Keys)
    $keys.Sort([System.StringComparer]::Ordinal)
    $new = @()
    foreach ($entryName in $keys) {
        $new += $entryName
        $source = $paths[$entryName]
        if ($source) {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $source, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        } else {
            $zip.CreateEntry($entryName) | Out-Null
        }
    }
    $zip.Dispose()
    $stream.Dispose()

    [System.IO.File]::Copy($tmp, $zipPath, $true)
    [System.IO.File]::Delete($tmp)

    $added = @($new | Where-Object { $old -notcontains $_ })
    $removed = @($old | Where-Object { $new -notcontains $_ })
    Write-Output ("{0}.zip: {1} entries (was {2})" -f $name, $new.Count, $old.Count)
    if ($added.Count -gt 0) { Write-Output ("  added:   " + ($added -join ", ")) }
    if ($removed.Count -gt 0) { Write-Output ("  removed: " + ($removed -join ", ")) }
}

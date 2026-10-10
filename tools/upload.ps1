# Uploads plugin zips to Project Sylvanas. This is the local version of the
# "Release" GitHub Actions workflow Sylvanas hands out: log in, package, PUT the
# zip to /api/developer/plugin/<id>/upload. GitHub runs it too: a push to main
# that changes a plugin's header.lua version uploads that plugin
# (.github/workflows/release.yml).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\upload.ps1 jambix_aio
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\upload.ps1 jcore jambix_aio
#
#   -DryRun    rebuild the named zips and show what would go up; no login, no upload
#   -NoRepack  upload the zips as they are (refused if a file is newer than its zip)
#   -Yes       skip the "Upload now?" question
#
# The zips are the ones repack.ps1 builds (entries under the plugin folder,
# "jcore/main.lua"). jambix_debug is deliberately not uploadable.
#
# Credentials come from SYLVANAS_USERNAME / SYLVANAS_PASSWORD, or it asks.
# Nothing is written to disk. Never keep them under scripts\ -- everything in a
# plugin folder goes into its zip.

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Plugins,
    [switch]$DryRun,
    [switch]$NoRepack,
    [switch]$Yes,
    [string]$Api = "https://project-sylvanas.net/api"
)

# The number in each plugin's editor URL on project-sylvanas.net.
$PluginIds = [ordered]@{
    "jcore"         = "1128"
    "jambix_aio"    = "1129"
    "jambix_market" = ""
}

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

$root = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts"

if (-not $Plugins -or $Plugins.Count -eq 0) {
    throw ("name the plugins to upload: " + ($PluginIds.Keys -join ", "))
}
foreach ($name in $Plugins) {
    if (-not $PluginIds.Contains($name)) {
        throw ("'{0}' is not an uploadable plugin (known: {1})" -f $name, ($PluginIds.Keys -join ", "))
    }
}

if (-not $NoRepack) {
    & (Join-Path $PSScriptRoot "repack.ps1") @Plugins
}

$packages = @()
foreach ($name in $Plugins) {
    $folder = Join-Path $root $name
    $zipPath = Join-Path $root ($name + ".zip")
    if (-not (Test-Path $zipPath)) {
        throw ("{0} is missing; run tools\repack.ps1" -f $zipPath)
    }

    $zipTime = (Get-Item $zipPath).LastWriteTime
    $newest = Get-ChildItem -Path $folder -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest -and $newest.LastWriteTime -gt $zipTime) {
        throw ("{0}.zip is older than {1}; run without -NoRepack" -f $name, $newest.FullName.Substring($root.Length + 1))
    }

    $header = [System.IO.File]::ReadAllText((Join-Path $folder "header.lua"))
    $match = [regex]::Match($header, 'plugin\["version"\]\s*=\s*"([^"]+)"')
    $version = "?"
    if ($match.Success) { $version = $match.Groups[1].Value }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $entries = $zip.Entries.Count
    $zip.Dispose()

    $package = [pscustomobject]@{
        Name    = $name
        Version = $version
        Zip     = $zipPath
        Id      = $PluginIds[$name]
    }
    $packages += $package

    $target = "plugin " + $package.Id
    if (-not $package.Id) { $target = "(plugin id not set)" }
    Write-Output ("{0} {1}: {2}.zip, {3:N0} KB, {4} entries -> {5}" -f
        $name, $version, $name, ((Get-Item $zipPath).Length / 1KB), $entries, $target)
}

if ($DryRun) {
    Write-Output "dry run: nothing uploaded"
    return
}

$missing = @($packages | Where-Object { -not $_.Id } | ForEach-Object { $_.Name })
if ($missing.Count -gt 0) {
    throw ("set the plugin id for {0} at the top of tools\upload.ps1 (the number in its plugin editor URL)" -f ($missing -join ", "))
}

if (-not $Yes) {
    $answer = Read-Host "Upload to Project Sylvanas now? [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Output "not uploaded"
        return
    }
}

$user = $env:SYLVANAS_USERNAME
if (-not $user) { $user = Read-Host "Sylvanas username" }
$pass = $env:SYLVANAS_PASSWORD
if (-not $pass) {
    $secure = Read-Host "Sylvanas password" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Windows PowerShell 5.1 may still offer only TLS 1.0/1.1 by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Read-Reply($response) {
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch { }
    [pscustomobject]@{ Code = [int]$response.StatusCode; Text = $text; Json = $json }
}

function Shorten($text) {
    if ($text.Length -le 300) { return $text }
    return $text.Substring(0, 300) + "..."
}

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromMinutes(5)
try {
    $body = @{ username = $user; password = $pass } | ConvertTo-Json -Compress
    $pass = $null
    $login = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, "application/json")
    $body = $null
    $reply = Read-Reply ($client.PostAsync($Api + "/auth/login", $login).GetAwaiter().GetResult())
    $login.Dispose()

    $token = $null
    if ($reply.Json) { $token = $reply.Json.token }
    if (-not $token) {
        throw ("login failed (HTTP {0}): {1}" -f $reply.Code, (Shorten $reply.Text))
    }
    Write-Output "logged in"
    $client.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $token)

    foreach ($package in $packages) {
        $fileName = [System.IO.Path]::GetFileName($package.Zip)
        $file = [System.Net.Http.ByteArrayContent]::new([System.IO.File]::ReadAllBytes($package.Zip))
        $file.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/zip")
        # Quoted the way curl -F writes them; .NET leaves them bare otherwise.
        $file.Headers.ContentDisposition = [System.Net.Http.Headers.ContentDispositionHeaderValue]::new("form-data")
        $file.Headers.ContentDisposition.Name = '"plugin_file"'
        $file.Headers.ContentDisposition.FileName = '"' + $fileName + '"'

        # .NET Framework quotes the boundary in Content-Type; some parsers reject that.
        $boundary = "----upload" + [guid]::NewGuid().ToString("N")
        $form = [System.Net.Http.MultipartFormDataContent]::new($boundary)
        $form.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("multipart/form-data; boundary=" + $boundary)
        $form.Add($file)

        Write-Output ("uploading {0} {1} to plugin {2}..." -f $package.Name, $package.Version, $package.Id)
        $url = "{0}/developer/plugin/{1}/upload" -f $Api, $package.Id
        $reply = Read-Reply ($client.PutAsync($url, $form).GetAwaiter().GetResult())
        $form.Dispose()

        if ($reply.Code -ne 200 -or -not $reply.Json -or $reply.Json.success -ne $true) {
            throw ("{0}: upload failed (HTTP {1}): {2}" -f $package.Name, $reply.Code, (Shorten $reply.Text))
        }
        $upload = @($reply.Json.uploads)[0]
        Write-Output ("{0} {1} uploaded: upload id {2}, checksum {3}" -f
            $package.Name, $package.Version, $upload.id, $upload.checksum)
    }
}
finally {
    $client.Dispose()
}

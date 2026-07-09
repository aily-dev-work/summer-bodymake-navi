# Deploys the site to the configured FTP server.
# Usage:
#   1. Copy .deploy.env.example to .deploy.env and fill in the FTP settings, or
#   2. Set FTP_HOST / FTP_USER / FTP_PASS / FTP_REMOTE_DIR as environment variables.
#   3. Run: powershell -ExecutionPolicy Bypass -File scripts/deploy-ftp.ps1

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$EnvFile = Join-Path $Root ".deploy.env"
$ConfigKeys = @("FTP_HOST", "FTP_USER", "FTP_PASS", "FTP_REMOTE_DIR")

function Set-ConfigValue {
    param(
        [string]$Name,
        [string]$Value
    )
    if ($null -ne $Value -and $Value -ne "") {
        Set-Variable -Name $Name -Value $Value -Scope Script
    }
}

if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            Set-ConfigValue -Name $matches[1].Trim() -Value $matches[2].Trim()
        }
    }
}

foreach ($key in $ConfigKeys) {
    Set-ConfigValue -Name $key -Value ([System.Environment]::GetEnvironmentVariable($key))
}

foreach ($key in $ConfigKeys) {
    $var = Get-Variable -Name $key -ErrorAction SilentlyContinue
    if (-not $var -or -not $var.Value) {
        $sourceHint = if (Test-Path $EnvFile) { ".deploy.env" } else { "GitHub Actions secrets or .deploy.env" }
        Write-Error "$key is not set in $sourceHint."
    }
}

$UseSsl = $false
$ftpUseSsl = [System.Environment]::GetEnvironmentVariable("FTP_USE_SSL")
if ($ftpUseSsl) {
    $UseSsl = @("1", "true", "yes", "on") -contains $ftpUseSsl.ToString().ToLowerInvariant()
}

$ExcludeDirs = @(".git", ".github", "scripts", "_partials", ".cursor")
$ExcludeFiles = @(
    ".deploy.env",
    ".deploy.env.example",
    ".gitkeep",
    ".gitignore",
    "deploy-site.zip",
    "DEPLOYMENT.md",
    "README.md",
    "Untitled"
)

function Ensure-FtpDirectory {
    param([string]$RemoteDir)

    $uri = "ftp://$FTP_HOST$RemoteDir"
    $request = [System.Net.FtpWebRequest]::Create($uri)
    $request.Method = [System.Net.WebRequestMethods+Ftp]::MakeDirectory
    $request.Credentials = New-Object System.Net.NetworkCredential($FTP_USER, $FTP_PASS)
    $request.UsePassive = $true
    $request.EnableSsl = $UseSsl

    try {
        $response = $request.GetResponse()
        $response.Close()
    }
    catch {
        # Directory may already exist.
    }
}

function Upload-FtpFile {
    param(
        [string]$LocalPath,
        [string]$RemotePath
    )

    $uri = "ftp://$FTP_HOST$RemotePath"
    $request = [System.Net.FtpWebRequest]::Create($uri)
    $request.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
    $request.Credentials = New-Object System.Net.NetworkCredential($FTP_USER, $FTP_PASS)
    $request.UseBinary = $true
    $request.UsePassive = $true
    $request.EnableSsl = $UseSsl

    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $request.ContentLength = $bytes.Length

    $stream = $request.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()

    $response = $request.GetResponse()
    $response.Close()
}

function Walk-RemoteDirs {
    param([string]$RelativeDir)

    $localDir = Join-Path $Root $RelativeDir
    if (-not (Test-Path $localDir)) {
        return
    }

    $remoteDir = ($FTP_REMOTE_DIR.TrimEnd("/") + "/" + ($RelativeDir -replace "\\", "/")).Replace("//", "/")
    Ensure-FtpDirectory $remoteDir

    Get-ChildItem $localDir -File | ForEach-Object {
        if ($ExcludeFiles -contains $_.Name) {
            return
        }
        if ($_.Name.StartsWith(".") -and $_.Name -ne ".htaccess") {
            return
        }

        $remotePath = $remoteDir.TrimEnd("/") + "/" + $_.Name
        Write-Host "UP $remotePath"
        Upload-FtpFile $_.FullName $remotePath
    }

    Get-ChildItem $localDir -Directory | ForEach-Object {
        if ($ExcludeDirs -contains $_.Name) {
            return
        }

        $child = if ($RelativeDir) { Join-Path $RelativeDir $_.Name } else { $_.Name }
        Walk-RemoteDirs $child
    }
}

Write-Host "Deploy to ftp://$FTP_HOST$FTP_REMOTE_DIR"
Walk-RemoteDirs ""
Write-Host "Done."

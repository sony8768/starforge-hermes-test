[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^SF-[A-Za-z0-9-]+$')]
    [string]$TaskId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerHost,

    [ValidatePattern('^[a-z_][a-z0-9_-]*$')]
    [string]$RemoteUser = "ubuntu",

    [ValidateRange(1, 65535)]
    [int]$Port = 22,

    [string]$IdentityFile,

    [string]$RepoPath = (Get-Location).Path,

    [string]$DestinationDirectory = (Join-Path $env:USERPROFILE "Desktop\StarForgeArtifacts"),

    [switch]$ForceDownload,

    [switch]$Publish
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-Tool {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string[]]$FallbackPaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($path in $FallbackPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    throw "Required tool '$Name' was not found."
}

function Invoke-External {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$receiverRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$importer = Join-Path $receiverRoot "Import-HermesResult.ps1"

if (-not (Test-Path -LiteralPath $importer -PathType Leaf)) {
    throw "Hermes result importer is missing: $importer"
}

$sftp = Resolve-Tool -Name "sftp" -FallbackPaths @("C:\Windows\System32\OpenSSH\sftp.exe")

$identity = $null
if ($IdentityFile) {
    $identity = (Resolve-Path -LiteralPath $IdentityFile).Path
}

New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
$destinationRoot = (Resolve-Path -LiteralPath $DestinationDirectory).Path
$archiveName = "$TaskId-result.tar.gz"
$destination = Join-Path $destinationRoot $archiveName
$partial = "$destination.partial"
$batchFile = "$destination.sftp-batch"

if ((Test-Path -LiteralPath $destination) -and -not $ForceDownload) {
    throw "Result archive already exists. Use -ForceDownload to replace it: $destination"
}

if (Test-Path -LiteralPath $partial) {
    Remove-Item -LiteralPath $partial -Force
}

$remotePath = "/results/$archiveName"
$sftpDestination = $partial.Replace("\", "/")

try {
    $batchContent = "get `"$remotePath`" `"$sftpDestination`"`n"
    [IO.File]::WriteAllText(
        $batchFile,
        $batchContent,
        [Text.UTF8Encoding]::new($false)
    )

    $sftpArguments = @(
        "-P", "$Port",
        "-b", $batchFile,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=15"
    )
    if ($identity) {
        $sftpArguments += @("-i", $identity)
    }
    $sftpArguments += @("$RemoteUser@$ServerHost")

    Invoke-External -FilePath $sftp -Arguments $sftpArguments

    if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) {
        throw "SFTP completed without creating the expected local file."
    }
    if ((Get-Item -LiteralPath $partial).Length -eq 0) {
        throw "Downloaded archive is empty."
    }

    Move-Item -LiteralPath $partial -Destination $destination -Force

    $archiveHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Downloaded: $destination"
    Write-Host "SHA-256:   $archiveHash"

    $importArguments = @{
        ArchivePath = $destination
        RepoPath = $repo
    }
    if ($Publish) {
        $importArguments.Publish = $true
    }

    & $importer @importArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Hermes result importer failed."
    }
}
finally {
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }
    if (Test-Path -LiteralPath $batchFile) {
        Remove-Item -LiteralPath $batchFile -Force
    }
}

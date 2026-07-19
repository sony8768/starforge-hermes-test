[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArchivePath,

    [string]$RepoPath = (Get-Location).Path,

    [string]$BaseBranch = "main",

    [switch]$Publish
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

function Get-SafeArchiveEntries {
    param(
        [Parameter(Mandatory)]
        [string]$TarPath,

        [Parameter(Mandatory)]
        [string]$Archive
    )

    $entries = & $TarPath -tzf $Archive
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list archive contents."
    }

    foreach ($entry in $entries) {
        $normalized = $entry.Replace("\", "/").TrimStart("./")
        if (
            [string]::IsNullOrWhiteSpace($normalized) -or
            $normalized.StartsWith("/") -or
            $normalized -match '(^|/)\.\.(/|$)' -or
            $normalized -match '^[A-Za-z]:'
        ) {
            throw "Unsafe archive entry: $entry"
        }

        $allowed =
            $normalized -eq "output" -or
            $normalized.StartsWith("output/") -or
            $normalized -eq "checks" -or
            $normalized.StartsWith("checks/") -or
            $normalized -eq "input/task.json" -or
            $normalized -eq "input/lease.json"

        if (-not $allowed) {
            throw "Unexpected archive entry: $entry"
        }
    }

    return $entries
}

function Get-ReportFileHash {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))

    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Report path escapes extraction directory: $RelativePath"
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Report file is missing: $RelativePath"
    }

    return (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
}

$archive = (Resolve-Path -LiteralPath $ArchivePath).Path
$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$git = Resolve-Tool -Name "git" -FallbackPaths @("C:\Program Files\Git\cmd\git.exe")
$dotnet = Resolve-Tool -Name "dotnet" -FallbackPaths @("C:\Program Files\dotnet\dotnet.exe")
$tar = Resolve-Tool -Name "tar" -FallbackPaths @("C:\Windows\System32\tar.exe")
$gh = $null

if ($Publish) {
    $gh = Resolve-Tool -Name "gh" -FallbackPaths @("C:\Program Files\GitHub CLI\gh.exe")
}

if (-not (Test-Path -LiteralPath (Join-Path $repo ".git"))) {
    throw "RepoPath is not a Git repository: $repo"
}

$status = & $git -C $repo status --porcelain
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect repository status."
}
if ($status) {
    throw "Repository must be clean before importing a Hermes result."
}

Get-SafeArchiveEntries -TarPath $tar -Archive $archive | Out-Null

$extractRoot = Join-Path ([IO.Path]::GetTempPath()) ("starforge-hermes-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $extractRoot | Out-Null

try {
    Invoke-External -FilePath $tar -Arguments @("-xzf", $archive, "-C", $extractRoot)

    $taskPath = Join-Path $extractRoot "input/task.json"
    $leasePath = Join-Path $extractRoot "input/lease.json"
    $reportPath = Join-Path $extractRoot "output/report.json"
    $patchPath = Join-Path $extractRoot "output/change.patch"

    foreach ($requiredFile in @($taskPath, $leasePath, $reportPath, $patchPath)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required result file is missing: $requiredFile"
        }
    }

    $task = Get-Content -Raw -Encoding UTF8 -LiteralPath $taskPath | ConvertFrom-Json
    $lease = Get-Content -Raw -Encoding UTF8 -LiteralPath $leasePath | ConvertFrom-Json
    $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportPath | ConvertFrom-Json

    if ($report.status -ne "completed") {
        throw "Hermes report status is not completed: $($report.status)"
    }
    if ($task.taskId -ne $lease.taskId -or $task.taskId -ne $report.taskId) {
        throw "Task IDs do not match across task, lease, and report."
    }
    if ($task.repository.baseCommit -ne $report.revision.baseCommit) {
        throw "Base Commit does not match between task and report."
    }
    if ([string]::IsNullOrWhiteSpace($report.revision.resultCommit)) {
        throw "Result Commit is missing from report."
    }
    if ($report.errors.Count -gt 0) {
        throw "Hermes report contains execution errors."
    }
    if (@($report.acceptanceResults | Where-Object { -not $_.passed }).Count -gt 0) {
        throw "One or more acceptance criteria failed."
    }

    foreach ($property in $report.files.PSObject.Properties) {
        $actualHash = Get-ReportFileHash -Root $extractRoot -RelativePath $property.Name
        $expectedHash = ([string]$property.Value).ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 mismatch for $($property.Name)."
        }
    }

    $taskId = [string]$task.taskId
    $baseCommit = [string]$task.repository.baseCommit
    $safeTaskId = ($taskId.ToLowerInvariant() -replace '[^a-z0-9._-]', '-')
    $branch = "agent/$safeTaskId"

    Invoke-External -FilePath $git -Arguments @("-C", $repo, "fetch", "origin", $BaseBranch)
    Invoke-External -FilePath $git -Arguments @("-C", $repo, "cat-file", "-e", "$baseCommit^{commit}")
    Invoke-External -FilePath $git -Arguments @("-C", $repo, "merge-base", "--is-ancestor", $baseCommit, "origin/$BaseBranch")

    & $git -C $repo show-ref --verify --quiet "refs/heads/$branch"
    if ($LASTEXITCODE -eq 0) {
        throw "Local branch already exists: $branch"
    }

    & $git -C $repo ls-remote --exit-code --heads origin $branch | Out-Null
    if ($LASTEXITCODE -eq 0) {
        throw "Remote branch already exists: $branch"
    }

    Invoke-External -FilePath $git -Arguments @("-C", $repo, "switch", "-c", $branch, $baseCommit)
    Invoke-External -FilePath $git -Arguments @("-C", $repo, "apply", "--check", $patchPath)
    Invoke-External -FilePath $git -Arguments @("-C", $repo, "apply", $patchPath)
    Invoke-External -FilePath $git -Arguments @("-C", $repo, "diff", "--check")
    Invoke-External -FilePath $dotnet -Arguments @("restore", (Join-Path $repo "StarForge.HermesTest.sln"))
    Invoke-External -FilePath $dotnet -Arguments @(
        "build",
        (Join-Path $repo "StarForge.HermesTest.sln"),
        "--configuration",
        "Release",
        "--no-restore"
    )
    Invoke-External -FilePath $dotnet -Arguments @(
        "test",
        (Join-Path $repo "StarForge.HermesTest.sln"),
        "--configuration",
        "Release",
        "--no-build"
    )

    Invoke-External -FilePath $git -Arguments @("-C", $repo, "add", "-A")
    Invoke-External -FilePath $git -Arguments @(
        "-C",
        $repo,
        "commit",
        "-m",
        "feat: import Hermes result $taskId"
    )

    $integratedCommit = (& $git -C $repo rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read integrated Commit SHA."
    }

    if ($Publish) {
        Invoke-External -FilePath $gh -Arguments @("auth", "status")
        Invoke-External -FilePath $git -Arguments @("-C", $repo, "push", "-u", "origin", $branch)

        $remoteUrl = (& $git -C $repo remote get-url origin).Trim()
        if ($remoteUrl -notmatch 'github\.com[/:](?<repo>[^/]+/[^/.]+)(?:\.git)?$') {
            throw "Unable to derive GitHub repository from origin: $remoteUrl"
        }
        $repositoryName = $Matches.repo

        $prBodyPath = Join-Path $extractRoot "pull-request.md"
        @"
## Hermes result

- Task: ``$taskId``
- Base Commit: ``$baseCommit``
- Hermes result Commit: ``$($report.revision.resultCommit)``
- North Star integrated Commit: ``$integratedCommit``

## Automated North Star checks

- Result archive allow-list validation passed.
- Task, lease, and report identities matched.
- Reported SHA-256 hashes matched.
- All acceptance criteria passed.
- Patch replay check passed.
- Release build passed.
- Release tests passed.

This pull request was created by ``tools/Import-HermesResult.ps1``. It remains a draft until North Star reviews the actual diff and evidence.
"@ | Set-Content -Encoding UTF8 -LiteralPath $prBodyPath

        Invoke-External -FilePath $gh -Arguments @(
            "pr",
            "create",
            "--repo",
            $repositoryName,
            "--base",
            $BaseBranch,
            "--head",
            $branch,
            "--draft",
            "--title",
            "feat: import Hermes result $taskId",
            "--body-file",
            $prBodyPath
        )
    }

    [PSCustomObject]@{
        TaskId = $taskId
        Branch = $branch
        BaseCommit = $baseCommit
        HermesResultCommit = $report.revision.resultCommit
        IntegratedCommit = $integratedCommit
        Published = [bool]$Publish
    } | Format-List
}
finally {
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
}

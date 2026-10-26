# On-demand self-hosted GitHub Actions runner for the Vivado workflow.
#
#   runner.ps1 -Action Install [-Token <registration token>]
#   runner.ps1 -Action Start | Stop | Status | Remove
#
# The runner lives under C:\ghr (work directory C:\ghr\w), runs as the
# current non-administrator user, and only while started: Start launches it
# in the background for a CI cycle, Stop ends it. It carries the labels
# self-hosted, windows, vivado and xczu5ev, which only .github/workflows/
# vivado.yml requests; that workflow never runs for pull requests.
#
# A registration token comes from -Token, or from the GitHub CLI when its
# token may administer the repository (fine-grained PAT: Administration
# read/write). The runner's .env puts Git on PATH and points
# HFT_VIVADO_LICENSE at a BASIC-tier Vivado license (split-vivado-license.ps1).
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Install", "Start", "Stop", "Status", "Remove")]
    [string]$Action,
    [string]$Repository = "ps-chong/hft-toy-project",
    [string]$Root = "C:\ghr",
    [string]$Token,
    [string]$Name = "$env:COMPUTERNAME-vivado",
    [string]$License = (Join-Path $env:APPDATA "XilinxLicense-BASIC"),
    [string]$Gh = "C:\Program Files\GitHub CLI\gh.exe"
)

$ErrorActionPreference = "Stop"
$labels = "vivado,xczu5ev"
$pidFile = Join-Path $Root "runner.pid"
$logFile = Join-Path $Root "runner.log"

function Get-RegistrationToken([string]$kind) {
    if ($Token) {
        return $Token
    }
    $value = & $Gh api -X POST "repos/$Repository/actions/runners/$kind-token" --jq .token 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "Cannot create a runner $kind token with the GitHub CLI token (it needs " +
            "Administration read/write on $Repository). Pass -Token from " +
            "Settings > Actions > Runners > New self-hosted runner."
    }
    return $value
}

function Get-RunnerProcess {
    if (-not (Test-Path $pidFile)) {
        return $null
    }
    $id = [int](Get-Content $pidFile)
    return Get-Process -Id $id -ErrorAction SilentlyContinue
}

function Install-Runner {
    New-Item -ItemType Directory -Force -Path $Root, (Join-Path $Root "w") | Out-Null
    if (-not (Test-Path (Join-Path $Root "config.cmd"))) {
        $release = & $Gh api repos/actions/runner/releases/latest | ConvertFrom-Json
        $asset = $release.assets | Where-Object { $_.name -like "actions-runner-win-x64-*.zip" } |
            Select-Object -First 1
        if (-not $asset) {
            throw "No win-x64 runner package in actions/runner $($release.tag_name)."
        }
        # The release notes list each package's SHA-256 between markers.
        if ($release.body -notmatch "<!-- BEGIN SHA win-x64 -->([0-9a-f]{64})<!-- END SHA win-x64 -->") {
            throw "actions/runner $($release.tag_name) publishes no win-x64 checksum."
        }
        $expected = $Matches[1]
        $archive = Join-Path $env:TEMP $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -UseBasicParsing
        $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Checksum mismatch for $($asset.name): $actual, expected $expected."
        }
        Expand-Archive -Path $archive -DestinationPath $Root -Force
        Remove-Item $archive
        Write-Host "Unpacked actions/runner $($release.tag_name) into $Root."
    }

    $git = Join-Path $env:LOCALAPPDATA "Programs\Git\cmd"
    $path = @($git, [Environment]::GetEnvironmentVariable("Path", "User"),
        [Environment]::GetEnvironmentVariable("Path", "Machine")) -join ";"
    @(
        "PATH=$path",
        "HFT_VIVADO_LICENSE=$License"
    ) | Set-Content -Path (Join-Path $Root ".env") -Encoding ascii

    $registration = Get-RegistrationToken "registration"
    & (Join-Path $Root "config.cmd") --unattended --replace `
        --url "https://github.com/$Repository" --token $registration `
        --name $Name --labels $labels --work "w"
    if ($LASTEXITCODE -ne 0) {
        throw "Runner configuration failed with exit code $LASTEXITCODE."
    }
    Write-Host "Registered runner '$Name' with labels self-hosted, windows, $labels."
}

function Start-Runner {
    if (Get-RunnerProcess) {
        Write-Host "Runner already running."
        return
    }
    if (-not (Test-Path (Join-Path $Root ".runner"))) {
        throw "The runner is not registered; run -Action Install first."
    }
    $process = Start-Process -FilePath (Join-Path $Root "run.cmd") -WorkingDirectory $Root `
        -WindowStyle Hidden -RedirectStandardOutput $logFile `
        -RedirectStandardError "$logFile.err" -PassThru
    $process.Id | Set-Content $pidFile
    Write-Host "Runner started (pid $($process.Id)); log $logFile."
}

function Stop-Runner {
    $process = Get-RunnerProcess
    # run.cmd starts Runner.Listener, which starts Runner.Worker per job.
    Get-Process -Name Runner.Listener, Runner.Worker -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$Root*" } | Stop-Process -Force
    if ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    Write-Host "Runner stopped."
}

switch ($Action) {
    "Install" { Install-Runner }
    "Start" { Start-Runner }
    "Stop" { Stop-Runner }
    "Status" {
        $process = Get-RunnerProcess
        $listener = Get-Process -Name Runner.Listener -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like "$Root*" }
        if ($process -or $listener) {
            Write-Host "Runner running (listener pid $($listener.Id -join ', '))."
        } else {
            Write-Host "Runner stopped."
        }
        if (Test-Path (Join-Path $Root ".runner")) {
            Get-Content (Join-Path $Root ".runner") | ConvertFrom-Json |
                Select-Object agentName, gitHubUrl | Format-List
        } else {
            Write-Host "Not registered."
        }
    }
    "Remove" {
        Stop-Runner
        $removal = Get-RegistrationToken "remove"
        & (Join-Path $Root "config.cmd") remove --token $removal
    }
}

# Polls every GitHub Actions run for one commit until all have finished,
# prints a summary, and saves the failed-step logs of failed runs.
#
#   poll-ci.ps1 [-Sha <commit>] [-IntervalSeconds 30] [-TimeoutMinutes 90]
#
# Exits 0 when every run concluded success or skipped, 1 otherwise.
[CmdletBinding()]
param(
    [string]$Sha,
    [string]$Repository = "ps-chong/hft-toy-project",
    [int]$IntervalSeconds = 30,
    [int]$TimeoutMinutes = 90,
    [string]$LogDirectory,
    [string]$Gh = "C:\Program Files\GitHub CLI\gh.exe"
)

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 leaves $PSScriptRoot empty in parameter defaults.
if (-not $LogDirectory) {
    $LogDirectory = Join-Path $PSScriptRoot "..\..\build\ci-logs"
}
if (-not $Sha) {
    $git = Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe"
    $Sha = (& $git rev-parse HEAD).Trim()
}
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$fields = "databaseId,workflowName,status,conclusion,url,event"

Write-Host "Waiting for workflow runs of $Sha in $Repository."
do {
    $runs = & $Gh run list --repo $Repository --commit $Sha --limit 50 --json $fields |
        ConvertFrom-Json
    $pending = @($runs | Where-Object { $_.status -ne "completed" })
    $done = @($runs).Count - $pending.Count
    Write-Host ("{0:HH:mm:ss} {1} run(s), {2} finished, {3} pending" -f (Get-Date), @($runs).Count,
        $done, $pending.Count)
    if (@($runs).Count -gt 0 -and $pending.Count -eq 0) {
        break
    }
    if ((Get-Date) -gt $deadline) {
        throw "Timed out after $TimeoutMinutes minutes with $($pending.Count) run(s) pending."
    }
    Start-Sleep -Seconds $IntervalSeconds
} while ($true)

$runs | Sort-Object workflowName |
    Format-Table workflowName, event, conclusion, url -AutoSize | Out-String -Width 200 |
    Write-Host

$failed = @($runs | Where-Object { $_.conclusion -notin @("success", "skipped") })
if ($failed.Count -eq 0) {
    Write-Host "All runs passed."
    exit 0
}

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
foreach ($run in $failed) {
    $file = Join-Path $LogDirectory ("{0}-{1}.log" -f $run.databaseId,
        ($run.workflowName -replace "[^A-Za-z0-9]+", "-"))
    & $Gh run view $run.databaseId --repo $Repository --log-failed 2>&1 |
        Set-Content -Path $file -Encoding utf8
    Write-Host "Failed: $($run.workflowName) -> $file"
}
exit 1

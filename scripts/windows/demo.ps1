# Runs demo/run_demo.sh from Windows: mirrors the checkout into the WSL ext4
# clone (scripts/ci/sync-wsl.sh), runs the demo there with Docker in WSL,
# and copies demo/out back into this checkout.
[CmdletBinding()]
param(
    [string]$Distribution = "Ubuntu",
    [switch]$Smoke
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$drive = $repoRoot.Substring(0, 1).ToLowerInvariant()
$wslRepo = "/mnt/$drive" + $repoRoot.Substring(2).Replace("\", "/")

& wsl -d $Distribution -e bash "$wslRepo/scripts/ci/sync-wsl.sh" $wslRepo
if ($LASTEXITCODE -ne 0) {
    throw "sync-wsl.sh failed with exit code $LASTEXITCODE."
}

$demoArgs = if ($Smoke) { "--smoke" } else { "" }
& wsl -d $Distribution -e bash -lc "cd ~/hft-ci && demo/run_demo.sh $demoArgs"
$status = $LASTEXITCODE

$output = Join-Path $repoRoot "demo\out"
New-Item -ItemType Directory -Force -Path $output | Out-Null
& wsl -d $Distribution -e bash -lc "cp -r ~/hft-ci/demo/out/. '$wslRepo/demo/out/'"

if ($status -ne 0) {
    throw "The demo failed with exit code $status; see the checks above."
}
Write-Host "Demo outputs copied to $output"

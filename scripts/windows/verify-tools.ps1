[CmdletBinding()]
param(
    [string]$VivadoRoot = "C:\AMDDesignTools\2026.1\Vivado"
)

$ErrorActionPreference = "Stop"
$vivado = Join-Path $VivadoRoot "bin\vivado.bat"

if (-not (Test-Path -LiteralPath $vivado -PathType Leaf)) {
    throw "Vivado 2026.1 was not found at '$vivado'."
}

$expectedRepo = "C:\Users\121679\hft-toy-project"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ($repoRoot -ne $expectedRepo) {
    Write-Warning "Expected checkout '$expectedRepo'; using '$repoRoot'."
}

$version = & $vivado -version 2>&1
if ($LASTEXITCODE -ne 0 -or ($version -join "`n") -notmatch "Vivado v2026\.1") {
    throw "The executable at '$vivado' is not Vivado 2026.1.`n$version"
}

Write-Host "Repository: $repoRoot"
Write-Host "Vivado:    $vivado"
Write-Host ($version | Select-Object -First 1)

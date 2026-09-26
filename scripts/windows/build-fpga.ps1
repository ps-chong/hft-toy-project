[CmdletBinding()]
param(
    [ValidateSet("sim-dma", "sfp10g")]
    [string]$Profile = "sim-dma",
    [string]$VivadoRoot = "C:\AMDDesignTools\2026.1\Vivado",
    [switch]$SynthesisOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$vivado = Join-Path $VivadoRoot "bin\vivado.bat"
$script = Join-Path $repoRoot "fpga\vivado\tcl\build.tcl"
$output = Join-Path $repoRoot "build\vivado\$Profile"

& (Join-Path $PSScriptRoot "verify-tools.ps1") -VivadoRoot $VivadoRoot
New-Item -ItemType Directory -Force -Path $output | Out-Null

$args = @(
    "-mode", "batch",
    "-nojournal",
    "-nolog",
    "-source", $script,
    "-tclargs", $repoRoot, $output, $Profile,
    $(if ($SynthesisOnly) { "synth" } else { "bitstream" })
)

Write-Host "Running Vivado profile '$Profile' in '$output'."
& $vivado @args
if ($LASTEXITCODE -ne 0) {
    throw "Vivado failed with exit code $LASTEXITCODE."
}

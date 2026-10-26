[CmdletBinding()]
param(
    [ValidateSet("sim-dma", "sfp10g")]
    [string]$Profile = "sim-dma",
    [string]$VivadoRoot = "C:\AMDDesignTools\2026.1\Vivado",
    # Directory or file holding a license whose tier covers the XCZU5EV
    # (BASIC or higher); see split-vivado-license.ps1.
    [string]$License = $env:HFT_VIVADO_LICENSE,
    [switch]$Bitstream
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$vivado = Join-Path $VivadoRoot "bin\vivado.bat"
$script = Join-Path $repoRoot "zynq\ultrascale+\vivado\tcl\build.tcl"
$output = Join-Path $repoRoot "build\vivado\$Profile"

if ($License) {
    if (-not (Test-Path -LiteralPath $License)) {
        throw "License '$License' was not found."
    }
    $env:XILINXD_LICENSE_FILE = $License
    Write-Host "Using license: $License"
}

& (Join-Path $PSScriptRoot "verify-tools.ps1") -VivadoRoot $VivadoRoot
New-Item -ItemType Directory -Force -Path $output | Out-Null

$args = @(
    "-mode", "batch",
    "-nojournal",
    "-log", (Join-Path $output "vivado.log"),
    "-source", $script,
    "-tclargs", $repoRoot, $output, $Profile,
    $(if ($Bitstream) { "bitstream" } else { "synth" })
)

Write-Host "Running Vivado profile '$Profile' in '$output'."
& $vivado @args
if ($LASTEXITCODE -ne 0) {
    throw "Vivado failed with exit code $LASTEXITCODE."
}

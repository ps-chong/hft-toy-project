[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$output = Join-Path $repoRoot "build\vivado"

if ((Test-Path -LiteralPath $output) -and
    $PSCmdlet.ShouldProcess($output, "Remove generated Vivado output")) {
    Remove-Item -LiteralPath $output -Recurse -Force
}

# Writes a copy of a Vivado 2026.1 license file that keeps only one license
# tier, so the tier can be chosen with XILINXD_LICENSE_FILE.
#
# Vivado 2026.1 selects a single tier at start-up and exposes only that
# tier's devices. A license file holding both ALVEO and BASIC entries can
# start in ALVEO, which hides the Zynq UltraScale+ XCZU5EV. FlexLM signs each
# feature line separately, so dropping whole INCREMENT/PACKAGE blocks of the
# other tiers keeps the remaining entries valid. The source file is never
# modified.
[CmdletBinding()]
param(
    [string]$Source = (Join-Path $env:APPDATA "XilinxLicense\Xilinx.lic"),
    [ValidateSet("BASIC", "CORE", "PRO", "ALVEO")]
    [string]$Tier = "BASIC",
    [string]$Destination = (Join-Path $env:APPDATA "XilinxLicense-$Tier")
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "License file '$Source' was not found."
}

# Group the file into blocks: a keyword line plus its '\' continuations.
$blocks = [System.Collections.Generic.List[object]]::new()
$current = $null
foreach ($line in Get-Content -LiteralPath $Source) {
    if ($null -eq $current) {
        $current = [System.Collections.Generic.List[string]]::new()
    }
    $current.Add($line)
    if (-not $line.TrimEnd().EndsWith("\")) {
        $blocks.Add($current)
        $current = $null
    }
}
if ($null -ne $current) {
    $blocks.Add($current)
}

$kept = [System.Collections.Generic.List[string]]::new()
$dropped = 0
foreach ($block in $blocks) {
    $text = $block -join "`n"
    $otherTier = $text -match "License_Tier:([A-Z]+)" -and $Matches[1] -ne $Tier
    # Tier packages are named Vivado_<Tier>_Package (e.g. Vivado_Alveo_Package).
    $otherPackage = $text -match "^(PACKAGE|INCREMENT)\s+Vivado_([A-Za-z]+)_Package" -and
        $Matches[2].ToUpperInvariant() -ne $Tier
    if ($otherTier -or $otherPackage) {
        $dropped++
        continue
    }
    $kept.AddRange([string[]]$block)
}

if (-not ($kept -match "License_Tier:$Tier")) {
    throw "'$Source' holds no License_Tier:$Tier entries."
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$output = Join-Path $Destination "Xilinx.lic"
Set-Content -LiteralPath $output -Value $kept -Encoding ascii
Write-Host "Wrote $output ($dropped block(s) of other tiers removed)."
Write-Host "Use it with: `$env:XILINXD_LICENSE_FILE = '$Destination'"

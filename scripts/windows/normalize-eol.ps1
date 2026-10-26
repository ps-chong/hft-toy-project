[CmdletBinding()]
param()

# Windows editors and tools may write CRLF. Linux containers that run the
# local CI mirror (scripts/ci/local.sh) need LF before Git normalizes on
# commit, so rewrite every tracked or untracked text file except the
# PowerShell/batch entry points that .gitattributes keeps as CRLF.
$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$git = Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe"
if (-not (Test-Path -LiteralPath $git)) { $git = "git" }

$utf8 = New-Object System.Text.UTF8Encoding $false
$changed = 0
$files = & $git -C $repoRoot ls-files --cached --others --exclude-standard
foreach ($relative in $files) {
    if ($relative -match '\.(ps1|bat|cmd|bin|onnx|png|dcp|wic|zip|gz|xz)$') { continue }
    $path = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes -notcontains 13 -or $bytes -contains 0) { continue }
    $text = [System.IO.File]::ReadAllText($path)
    [System.IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), $utf8)
    $changed++
}
Write-Host "Normalized $changed file(s) to LF."

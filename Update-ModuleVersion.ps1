# Update-ModuleVersion.ps1
# Developer helper: bumps the module version in OktaToEntra.psd1.
#
# All other version references (banner, reports, installer) read the version
# from the loaded module at runtime, so only the .psd1 needs to be updated.
#
# Version format: YYYY.M.N  (e.g. 2026.3.1)
#   YYYY = year, M = month (no leading zero), N = sequential build this month
#
# Usage:
#   .\Update-ModuleVersion.ps1 -Version '2026.3.2'
#
# After running, commit and push:
#   git add OktaToEntra.psd1
#   git commit -m "Release 2026.3.2: <brief description>"
#   git push

#Requires -Version 7.2

param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d{4}\.\d{1,2}\.\d+$')]
    [string]$Version
)

$psd1 = Join-Path $PSScriptRoot 'OktaToEntra.psd1'

if (-not (Test-Path $psd1)) {
    Write-Error "OktaToEntra.psd1 not found at: $psd1"
    exit 1
}

$current = (Import-PowerShellDataFile $psd1).ModuleVersion

$content = Get-Content $psd1 -Raw
$updated = $content -replace "ModuleVersion\s*=\s*'[^']+'", "ModuleVersion     = '$Version'"

if ($content -eq $updated) {
    Write-Host "  ⚠  No change — ModuleVersion pattern not found in psd1." -ForegroundColor Yellow
    exit 1
}

Set-Content $psd1 -Value $updated -Encoding UTF8 -NoNewline
Write-Host ""
Write-Host "  ✓ OktaToEntra.psd1 updated" -ForegroundColor Green
Write-Host "    $current  →  $Version" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    git add OktaToEntra.psd1" -ForegroundColor Yellow
Write-Host "    git commit -m `"Release $Version`: <describe the change>`"" -ForegroundColor Yellow
Write-Host "    git push" -ForegroundColor Yellow
Write-Host ""

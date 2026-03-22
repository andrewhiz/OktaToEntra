# OktaToEntra.psm1 — Module loader
# FunctionsToExport is controlled by OktaToEntra.psd1 — do NOT add Export-ModuleMember here.

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot\Public\**\*.ps1" -Recurse -ErrorAction SilentlyContinue)

$loadErrors = 0
foreach ($file in @($Private + $Public)) {
    try {
        . $file.FullName
        Write-Verbose "[OktaToEntra] Loaded: $($file.Name)"
    } catch {
        $loadErrors++
        # Always visible — not suppressed by -ErrorAction
        Write-Host "[OktaToEntra] LOAD FAILED: $($file.Name)" -ForegroundColor Red
        Write-Host "              Error: $_" -ForegroundColor Red
        Write-Host "              Path : $($file.FullName)" -ForegroundColor DarkGray
    }
}

if ($loadErrors -gt 0) {
    Write-Host "[OktaToEntra] $loadErrors file(s) failed to load. Some commands will be unavailable." -ForegroundColor Yellow
    Write-Host "              Run: Import-Module OktaToEntra -Verbose  to see full load detail." -ForegroundColor DarkGray
}

# Module-level session state
$script:CurrentProject = $null
$script:DbPath         = $null

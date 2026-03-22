# Install-OktaToEntra.ps1
# Run this once to install prerequisites and register the module.

#Requires -Version 7.2

param(
    [switch]$Force
)

Write-Host ""
Write-Host "  OktaToEntra — Setup" -ForegroundColor Cyan
Write-Host "  ───────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Check PowerShell version ────────────────────────────────────────────────
if ($PSVersionTable.PSVersion -lt [version]'7.2') {
    Write-Error "PowerShell 7.2 or higher is required. Download from: https://aka.ms/powershell"
    exit 1
}
Write-Host "  ✓ PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green

# ── Check NuGet provider ────────────────────────────────────────────────────
$nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
if (-not $nuget -or $nuget.Version -lt '2.8.5.201') {
    Write-Host "  → Installing NuGet provider..." -ForegroundColor Cyan
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}
Write-Host "  ✓ NuGet provider" -ForegroundColor Green

# ── Set PSGallery as trusted ─────────────────────────────────────────────────
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

# ── Required modules ─────────────────────────────────────────────────────────
$modules = @(
    @{ Name='PSSQLite';                          MinVersion='1.1.0'  }
    @{ Name='Microsoft.PowerShell.SecretManagement'; MinVersion='1.1.0' }
    @{ Name='Microsoft.PowerShell.SecretStore';  MinVersion='1.0.0'  }
)

foreach ($mod in $modules) {
    $installed = Get-Module -ListAvailable -Name $mod.Name |
                 Where-Object { $_.Version -ge $mod.MinVersion } |
                 Select-Object -First 1

    if ($installed -and -not $Force) {
        Write-Host "  ✓ $($mod.Name) $($installed.Version)" -ForegroundColor Green
    } else {
        Write-Host "  → Installing $($mod.Name)..." -ForegroundColor Cyan
        try {
            Install-Module -Name $mod.Name -MinimumVersion $mod.MinVersion `
                           -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Host "  ✓ $($mod.Name) installed" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Failed to install $($mod.Name): $_" -ForegroundColor Red
            Write-Host "    Run manually: Install-Module $($mod.Name) -Scope CurrentUser" -ForegroundColor Yellow
        }
    }
}

# ── Check for existing / old module installs ─────────────────────────────────
# Scans every path in $PSModulePath — catches PS5 WindowsPowerShell folders,
# PS7 CurrentUser and AllUsers locations, and any custom module paths.
Write-Host ""
Write-Host "  → Checking for existing OktaToEntra installations..." -ForegroundColor Cyan

$installingVersion = '1.1.0'
$existingInstalls  = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($searchPath in ($env:PSModulePath -split [System.IO.Path]::PathSeparator)) {
    $candidate = Join-Path $searchPath 'OktaToEntra'
    if (-not (Test-Path $candidate)) { continue }

    $foundVersion = 'unknown'
    $manifestPath = Join-Path $candidate 'OktaToEntra.psd1'
    if (Test-Path $manifestPath) {
        try {
            $data = Import-PowerShellDataFile $manifestPath -ErrorAction Stop
            $foundVersion = $data.ModuleVersion
        } catch { }
    }
    $existingInstalls.Add([PSCustomObject]@{ Path = $candidate; Version = $foundVersion })
}

if ($existingInstalls.Count -gt 0) {
    Write-Host ""
    Write-Host "  ⚠  Found existing OktaToEntra installation(s):" -ForegroundColor Yellow
    Write-Host ""
    foreach ($inst in $existingInstalls) {
        $isOlder = $inst.Version -ne 'unknown' -and ([version]$inst.Version -lt [version]$installingVersion)
        $isSame  = $inst.Version -eq $installingVersion
        $tag     = if ($isOlder) { '[OLD]  ' } elseif ($isSame) { '[SAME] ' } else { '[?]    ' }
        $color   = if ($isOlder) { 'Red' } elseif ($isSame) { 'Yellow' } else { 'Gray' }
        Write-Host ("    {0} v{1,-8}  {2}" -f $tag, $inst.Version, $inst.Path) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "  Installing v$installingVersion. Leaving old or duplicate installs in place" -ForegroundColor White
    Write-Host "  can cause PowerShell to load the wrong version. Removing them is recommended." -ForegroundColor White
    Write-Host ""

    if ($Force) {
        $cleanUp = $true
        Write-Host "  -Force specified — removing all existing installs." -ForegroundColor Cyan
    } else {
        $response = Read-Host "  Remove all listed installs before proceeding? [y/N]"
        $cleanUp  = $response -ieq 'y'
    }

    if ($cleanUp) {
        foreach ($inst in $existingInstalls) {
            try {
                Remove-Item -Path $inst.Path -Recurse -Force -ErrorAction Stop
                Write-Host "  ✓ Removed: $($inst.Path)" -ForegroundColor Green
            } catch {
                Write-Host "  ✗ Could not remove: $($inst.Path)" -ForegroundColor Red
                Write-Host "    The module may be loaded in another PowerShell session." -ForegroundColor Yellow
                Write-Host "    Close all other PowerShell windows and re-run this installer." -ForegroundColor Yellow
                exit 1
            }
        }
    } else {
        Write-Host "  Skipping removal. Proceeding — but import conflicts may occur." -ForegroundColor Yellow
        Write-Host "  Re-run the installer and choose [y] to clean up when ready." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  ✓ No existing installations found" -ForegroundColor Green
}

# ── Copy module to PSModulePath ───────────────────────────────────────────────
$moduleSource = $PSScriptRoot
$moduleDest   = Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) `
                "PowerShell\Modules\OktaToEntra"

Write-Host ""
Write-Host "  → Installing module to $moduleDest ..." -ForegroundColor Cyan
try {
    Copy-Item -Path $moduleSource -Destination $moduleDest -Recurse -Force -ErrorAction Stop
    Write-Host "  ✓ Module v$installingVersion installed" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Failed to copy module files: $_" -ForegroundColor Red
    exit 1
}

# ── Initialise SecretStore vault ───────────────────────────────────────────────
# SecretManagement + SecretStore are mandatory for credential storage in v1.1+.
# SecretStore encrypts secrets at rest using DPAPI (Windows) or the OS keyring
# (Linux/macOS). We configure it with no additional master password so that
# scripts can run without interactive prompts — DPAPI protection is sufficient
# for a single-user desktop tool.
Write-Host ""
Write-Host "  → Configuring SecretStore vault..." -ForegroundColor Cyan
try {
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    Import-Module Microsoft.PowerShell.SecretStore       -ErrorAction Stop

    # Disable the SecretStore master-password prompt (uses OS-level encryption instead)
    $storeConfig = Get-SecretStoreConfiguration -ErrorAction SilentlyContinue
    if ($storeConfig -and $storeConfig.Authentication -ne 'None') {
        Set-SecretStoreConfiguration -Authentication None -Confirm:$false -ErrorAction Stop
        Write-Host "  ✓ SecretStore configured (OS-level encryption, no master password)" -ForegroundColor Green
    } elseif (-not $storeConfig) {
        # First-time initialisation
        Set-SecretStoreConfiguration -Authentication None -Confirm:$false -ErrorAction Stop
        Write-Host "  ✓ SecretStore initialised" -ForegroundColor Green
    } else {
        Write-Host "  ✓ SecretStore already configured" -ForegroundColor Green
    }

    $vault = Get-SecretVault -Name "OktaToEntra" -ErrorAction SilentlyContinue
    if (-not $vault) {
        Register-SecretVault -Name "OktaToEntra" `
                             -ModuleName Microsoft.PowerShell.SecretStore `
                             -DefaultVault -ErrorAction Stop
        Write-Host "  ✓ SecretStore vault 'OktaToEntra' registered" -ForegroundColor Green
    } else {
        Write-Host "  ✓ SecretStore vault already registered" -ForegroundColor Green
    }
} catch {
    Write-Host "  ✗ Could not configure SecretStore: $_" -ForegroundColor Red
    Write-Host "    SecretStore is required for credential storage. Resolve the error above" -ForegroundColor Yellow
    Write-Host "    and re-run Install-OktaToEntra.ps1 before using the module." -ForegroundColor Yellow
    exit 1
}

# ── Create data directory ─────────────────────────────────────────────────────
$dataDir = Join-Path $env:APPDATA "OktaToEntra"
if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}
Write-Host "  ✓ Data directory: $dataDir" -ForegroundColor Green

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  To get started:" -ForegroundColor White
Write-Host "    Import-Module OktaToEntra" -ForegroundColor Yellow
Write-Host "    Start-OktaToEntra        # interactive menu" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Or use cmdlets directly:" -ForegroundColor White
Write-Host "    New-OktaToEntraProject -Name 'My Migration' -OktaDomain 'org.okta.com' ..." -ForegroundColor Yellow
Write-Host "    Sync-OktaApps" -ForegroundColor Yellow
Write-Host "    Get-MigrationStatus" -ForegroundColor Yellow
Write-Host ""

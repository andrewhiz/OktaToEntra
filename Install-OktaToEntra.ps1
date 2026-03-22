# Install-OktaToEntra.ps1
# Run this once to install prerequisites and register the module.

#Requires -Version 5.1

param(
    [switch]$Force
)

Write-Host ""
Write-Host "  OktaToEntra — Setup" -ForegroundColor Cyan
Write-Host "  ───────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Check PowerShell version ────────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error "PowerShell 5.1 or higher is required. Please upgrade."
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

# ── Copy module to PSModulePath ───────────────────────────────────────────────
$moduleSource = $PSScriptRoot
$moduleDest   = Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) `
                "PowerShell\Modules\OktaToEntra"

if (Test-Path $moduleDest) {
    if ($Force) {
        Remove-Item $moduleDest -Recurse -Force
    } else {
        Write-Host "  ✓ Module already installed at $moduleDest" -ForegroundColor Green
        Write-Host "    (Use -Force to reinstall)" -ForegroundColor DarkGray
    }
}

if (-not (Test-Path $moduleDest) -or $Force) {
    Write-Host "  → Copying module to $moduleDest ..." -ForegroundColor Cyan
    Copy-Item -Path $moduleSource -Destination $moduleDest -Recurse -Force
    Write-Host "  ✓ Module installed" -ForegroundColor Green
}

# ── Initialise SecretStore vault ───────────────────────────────────────────────
Write-Host ""
Write-Host "  → Configuring SecretStore vault..." -ForegroundColor Cyan
try {
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    Import-Module Microsoft.PowerShell.SecretStore       -ErrorAction Stop

    $vault = Get-SecretVault -Name "OktaToEntra" -ErrorAction SilentlyContinue
    if (-not $vault) {
        Register-SecretVault -Name "OktaToEntra" `
                             -ModuleName Microsoft.PowerShell.SecretStore `
                             -DefaultVault
        Write-Host "  ✓ SecretStore vault 'OktaToEntra' registered" -ForegroundColor Green
        Write-Host "    You will be prompted to set a vault password on first use." -ForegroundColor DarkGray
    } else {
        Write-Host "  ✓ SecretStore vault already registered" -ForegroundColor Green
    }
} catch {
    Write-Host "  ⚠ Could not configure SecretStore: $_" -ForegroundColor Yellow
    Write-Host "    Credentials will use DPAPI fallback (still secure)." -ForegroundColor DarkGray
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

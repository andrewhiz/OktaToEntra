# Private/Vault.ps1
# Credential storage — DPAPI primary, SecretManagement optional.
# Written for PowerShell 5.1 compatibility — no null-coalescing, no inline assignments.

$script:VaultName = 'OktaToEntra'
$script:VaultChecked = $false
$script:VaultAvailable = $false

function Test-VaultAvailable {
    if ($script:VaultChecked) {
        return $script:VaultAvailable
    }
    $script:VaultChecked = $true
    try {
        $mod = Get-Module -ListAvailable -Name 'Microsoft.PowerShell.SecretManagement' -ErrorAction SilentlyContinue
        if ($mod) {
            $minVersion = [version]'1.1.0'
            $goodVersion = $mod | Where-Object { $_.Version -ge $minVersion }
            if ($goodVersion) {
                Import-Module 'Microsoft.PowerShell.SecretManagement' -ErrorAction Stop
                $script:VaultAvailable = $true
            }
        }
    } catch {
        $script:VaultAvailable = $false
    }
    return $script:VaultAvailable
}

function Get-SecretsFilePath {
    param([string]$ProjectId)
    $root = Join-Path $env:APPDATA 'OktaToEntra'
    return Join-Path $root "$ProjectId\secrets.json"
}

function Initialize-Vault {
    if (-not (Test-VaultAvailable)) {
        Write-Verbose 'SecretManagement not available — DPAPI file storage will be used.'
        return
    }
    try {
        $existing = Get-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue
        if (-not $existing) {
            Register-SecretVault -Name $script:VaultName `
                -ModuleName 'Microsoft.PowerShell.SecretStore' `
                -DefaultVault -ErrorAction Stop
        }
    } catch {
        Write-Verbose "SecretStore registration failed: $_ Falling back to DPAPI."
        $script:VaultAvailable = $false
    }
}

function Set-ProjectSecret {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$SecretType,
        [Parameter(Mandatory=$true)][string]$Value
    )

    # Try vault first
    if (Test-VaultAvailable) {
        $key = "OktaToEntra_${ProjectId}_${SecretType}"
        try {
            Set-Secret -Name $key -Secret $Value -Vault $script:VaultName -ErrorAction Stop
            return
        } catch {
            Write-Verbose "Vault write failed, using DPAPI: $_"
            $script:VaultAvailable = $false
        }
    }

    # DPAPI fallback
    $filePath = Get-SecretsFilePath -ProjectId $ProjectId
    $dir = Split-Path $filePath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path $filePath) {
        $obj = Get-Content $filePath -Raw | ConvertFrom-Json
    } else {
        $obj = New-Object PSObject
    }

    $encrypted = ConvertTo-SecureString -String $Value -AsPlainText -Force | ConvertFrom-SecureString
    $obj | Add-Member -NotePropertyName $SecretType -NotePropertyValue $encrypted -Force
    $obj | ConvertTo-Json | Set-Content -Path $filePath -Encoding UTF8
}

function Get-ProjectSecret {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$SecretType
    )

    # Try vault first
    if (Test-VaultAvailable) {
        $key = "OktaToEntra_${ProjectId}_${SecretType}"
        try {
            $val = Get-Secret -Name $key -Vault $script:VaultName -AsPlainText -ErrorAction Stop
            if ($val) { return $val }
        } catch {
            Write-Verbose "Vault read failed, trying DPAPI: $_"
        }
    }

    # DPAPI fallback
    $filePath = Get-SecretsFilePath -ProjectId $ProjectId
    if (-not (Test-Path $filePath)) {
        return $null
    }

    try {
        $obj = Get-Content $filePath -Raw | ConvertFrom-Json
        $encrypted = $obj.$SecretType
        if (-not $encrypted) { return $null }
        $secure = $encrypted | ConvertTo-SecureString
        $cred = New-Object System.Net.NetworkCredential('placeholder', $secure)
        return $cred.Password
    } catch {
        Write-Verbose "DPAPI read failed for $SecretType : $_"
        return $null
    }
}

function Remove-ProjectSecrets {
    param([Parameter(Mandatory=$true)][string]$ProjectId)

    if (Test-VaultAvailable) {
        foreach ($type in @('OktaApiToken','GraphClientSecret','GraphCertThumb')) {
            $key = "OktaToEntra_${ProjectId}_${type}"
            try {
                Remove-Secret -Name $key -Vault $script:VaultName -ErrorAction SilentlyContinue
            } catch { }
        }
    }

    $filePath = Get-SecretsFilePath -ProjectId $ProjectId
    if (Test-Path $filePath) {
        Remove-Item $filePath -Force
    }
}

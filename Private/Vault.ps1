# Private/Vault.ps1
# Credential storage using Microsoft.PowerShell.SecretManagement + SecretStore.
# Requires PS7.2+. SecretStore is a mandatory dependency — run Install-OktaToEntra.ps1
# to install it if not already present.
#
# Secrets are stored as SecureString and returned as SecureString.
# They are only unpacked to plaintext at the point of use (inside HTTP helpers).

$script:VaultName = 'OktaToEntra'

function Initialize-Vault {
    <#
    .SYNOPSIS
        Ensures the OktaToEntra SecretStore vault is registered and configured.
        Called once during New-OktaToEntraProject. Throws on failure.
    #>

    # Configure SecretStore to use no additional master password — DPAPI (Windows) or
    # the OS keyring (Linux/macOS) already encrypts the store at rest. An extra password
    # would block unattended script execution and is unnecessary for a single-user tool.
    try {
        $storeConfig = Get-SecretStoreConfiguration -ErrorAction Stop
        if ($storeConfig.Authentication -ne 'None') {
            Set-SecretStoreConfiguration -Authentication None -Confirm:$false -ErrorAction Stop
        }
    } catch {
        # SecretStore may not be configured yet on first run — that is fine, continue.
        Write-Verbose "SecretStore configuration check skipped: $_"
    }

    $existing = Get-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue
    if (-not $existing) {
        try {
            Register-SecretVault -Name $script:VaultName `
                -ModuleName 'Microsoft.PowerShell.SecretStore' `
                -DefaultVault -ErrorAction Stop
            Write-Verbose "Registered SecretStore vault '$($script:VaultName)'."
        } catch {
            throw (
                "Failed to register SecretStore vault '$($script:VaultName)'. " +
                "Ensure Microsoft.PowerShell.SecretStore is installed:`n" +
                "  Install-Module Microsoft.PowerShell.SecretStore -Scope CurrentUser`n$_"
            )
        }
    }
}

function Set-ProjectSecret {
    <#
    .SYNOPSIS
        Stores a secret (as SecureString) in the SecretStore vault for the given project.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$SecretType,
        [Parameter(Mandatory)][SecureString]$Value
    )

    $key = "OktaToEntra_${ProjectId}_${SecretType}"
    try {
        Set-Secret -Name $key -Secret $Value -Vault $script:VaultName -ErrorAction Stop
    } catch {
        throw "Failed to store secret '$SecretType' in vault '$($script:VaultName)': $_"
    }
}

function Get-ProjectSecret {
    <#
    .SYNOPSIS
        Retrieves a secret from the SecretStore vault as a SecureString.
        Returns $null if the secret does not exist.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$SecretType
    )

    $key = "OktaToEntra_${ProjectId}_${SecretType}"
    try {
        return Get-Secret -Name $key -Vault $script:VaultName -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -match 'not found|does not exist|No secret') {
            return $null
        }
        throw "Failed to retrieve secret '$SecretType' from vault: $_"
    }
}

function Remove-ProjectSecrets {
    <#
    .SYNOPSIS
        Removes all stored secrets for the given project from the vault.
    #>
    param([Parameter(Mandatory)][string]$ProjectId)

    foreach ($type in @('OktaApiToken', 'GraphClientSecret', 'GraphCertThumb')) {
        $key = "OktaToEntra_${ProjectId}_${type}"
        Remove-Secret -Name $key -Vault $script:VaultName -ErrorAction SilentlyContinue
    }
}

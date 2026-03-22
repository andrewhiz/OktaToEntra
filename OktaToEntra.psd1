@{
    RootModule        = 'OktaToEntra.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f7c2e1-5b4d-4f8a-9c1e-2d6b0f3a7e5c'
    Author            = 'OktaToEntra'
    Description       = 'Okta to Microsoft Entra ID migration management tool'
    PowerShellVersion = '5.1'

    # PSSQLite is required. SecretManagement/SecretStore are optional —
    # Vault.ps1 detects and uses them at runtime if available, falls back to DPAPI otherwise.
    RequiredModules = @(
        @{ ModuleName = 'PSSQLite'; ModuleVersion = '1.1.0' }
    )

    FunctionsToExport = @(
        # Project
        'New-OktaToEntraProject'
        'Get-OktaToEntraProject'
        'Select-OktaToEntraProject'
        'Update-ProjectSettings'
        # Okta
        'Test-OktaConnection'
        'Sync-OktaApps'
        'Get-OktaAppDetail'
        # App Usage
        'Get-OktaAppUsage'
        'Show-AppUsageReport'
        'Get-AppUsageHistory'
        'Clear-AppUsageData'
        # Entra
        'Test-EntraConnection'
        'New-EntraAppStub'
        'New-EntraServicePrincipal'
        'Add-EntraAppAssignment'
        # Migration
        'Get-MigrationStatus'
        'Update-MigrationItem'
        'Set-AppGroupMapping'
        'Get-AppGroupMapping'
        # Attribute Mapping
        'Get-AppUsernameAttributes'
        'Set-MigrationClaimMapping'
        'Get-AttributeRiskSummary'
        # Reports
        'Export-MigrationReport'
        'Export-AppConfigPack'
        # Menu
        'Start-OktaToEntra'
    )

    PrivateData = @{
        PSData = @{
            Tags = @('Okta', 'EntraID', 'AzureAD', 'Migration', 'Identity')
        }
    }
}

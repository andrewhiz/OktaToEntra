# Public/Project/Update-ProjectSettings.ps1

function Update-ProjectSettings {
    <#
    .SYNOPSIS
        Interactive menu to view and update Okta / Entra credentials and settings
        for the active project. No parameters required — everything is prompted.

    .DESCRIPTION
        Lets you update any combination of:
          - Okta Domain
          - Okta API Token
          - Entra Tenant ID
          - Entra Client ID
          - Entra Client Secret

        Config values (domain, tenant ID, client ID) are saved to config.json.
        Secrets (API token, client secret) are saved to the SecretStore vault
        (Microsoft.PowerShell.SecretStore) — never stored in plaintext.

        Each change is tested immediately so you know whether the new value works
        before leaving the screen.

    .EXAMPLE
        Update-ProjectSettings
    #>
    [CmdletBinding()]
    param()

    if (-not $script:CurrentProject) {
        throw "No active project. Run Select-OktaToEntraProject first."
    }

    $projectId  = $script:CurrentProject.ProjectId
    $dataRoot   = Get-DataRoot
    $configPath = Join-Path $dataRoot "$projectId\config.json"

    while ($true) {

        # ── Re-read config fresh each loop so edits are reflected ─────────────
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json

        # ── Peek at secrets — just show whether they are stored ───────────────
        $oktaToken    = Get-ProjectSecret -ProjectId $projectId -SecretType 'OktaApiToken'
        $clientSecret = Get-ProjectSecret -ProjectId $projectId -SecretType 'GraphClientSecret'

        $oktaStatus   = if ($oktaToken    -and $oktaToken.Length    -gt 0) { '● stored' } else { '○ NOT SET' }
        $secretStatus = if ($clientSecret -and $clientSecret.Length -gt 0) { '● stored' } else { '○ NOT SET' }
        $oktaColor    = if ($oktaToken    -and $oktaToken.Length    -gt 0) { 'Green' }    else { 'Red' }
        $secretColor  = if ($clientSecret -and $clientSecret.Length -gt 0) { 'Green' }    else { 'Red' }

        # ── Header ────────────────────────────────────────────────────────────
        Clear-Host
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║         Project Settings — $($cfg.Name.PadRight(24))║" -ForegroundColor Cyan
        Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        # ── Okta section ──────────────────────────────────────────────────────
        Write-Host "  ── Okta ──────────────────────────────────────────────" -ForegroundColor DarkCyan
        Write-Host "  [1]  Domain    : " -NoNewline
        Write-Host $cfg.OktaDomain -ForegroundColor White
        Write-Host "  [2]  API Token : " -NoNewline
        Write-Host $oktaStatus -ForegroundColor $oktaColor
        Write-Host ""

        # ── Entra section ─────────────────────────────────────────────────────
        Write-Host "  ── Microsoft Entra ID ────────────────────────────────" -ForegroundColor DarkCyan
        Write-Host "  [3]  Tenant ID       : " -NoNewline
        Write-Host $cfg.EntraTenantId -ForegroundColor White
        Write-Host "  [4]  Client ID (App) : " -NoNewline
        Write-Host $cfg.EntraClientId -ForegroundColor White
        Write-Host "  [5]  Client Secret   : " -NoNewline
        Write-Host $secretStatus -ForegroundColor $secretColor
        Write-Host ""

        # ── Actions ───────────────────────────────────────────────────────────
        Write-Host "  ── Actions ───────────────────────────────────────────" -ForegroundColor DarkCyan
        Write-Host "  [6]  Test Okta connection" -ForegroundColor White
        Write-Host "  [7]  Test Entra connection" -ForegroundColor White
        Write-Host "  [8]  Test both connections" -ForegroundColor White
        Write-Host "  [Q]  Back to main menu" -ForegroundColor DarkGray
        Write-Host ""

        $choice = (Read-Host "  Enter choice").Trim().ToUpper()

        switch ($choice) {

            '1' {
                Write-Host ""
                Write-Host "  Current: $($cfg.OktaDomain)" -ForegroundColor DarkGray
                $newVal = (Read-Host "  New Okta domain (e.g. myorg.okta.com)").Trim()
                if ($newVal -and $newVal -ne $cfg.OktaDomain) {
                    $newVal = $newVal.TrimEnd('/')
                    Invoke-SaveConfigField -ConfigPath $configPath `
                                           -Field 'OktaDomain' -Value $newVal
                    # Also update session state
                    $script:CurrentProject.OktaDomain = $newVal
                    Write-Host "  ✓ Okta domain updated." -ForegroundColor Green
                    Write-Host "  Testing new domain..." -ForegroundColor DarkGray
                    $token = Get-ProjectSecret -ProjectId $projectId -SecretType 'OktaApiToken'
                    if ($token -and $token.Length -gt 0) {
                        Test-OktaConnection -OktaDomain $newVal -ApiToken $token
                    } else {
                        Write-Host "  ⚠ No API token stored yet — update token (option 2) to test." -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "  No change." -ForegroundColor DarkGray
                }
                Invoke-PausePrompt
            }

            '2' {
                Write-Host ""
                Write-Host "  Paste your Okta API token." -ForegroundColor DarkGray
                Write-Host "  Generate one at: Okta Admin → Security → API → Tokens → Create Token" -ForegroundColor DarkGray
                Write-Host ""
                $newVal = Invoke-SecureRead -Prompt "  Okta API Token"
                if ($newVal) {
                    Set-ProjectSecret -ProjectId $projectId `
                                      -SecretType 'OktaApiToken' -Value $newVal
                    Write-Host "  ✓ Okta API token saved." -ForegroundColor Green
                    Write-Host "  Testing..." -ForegroundColor DarkGray
                    $domain = (Get-Content $configPath -Raw | ConvertFrom-Json).OktaDomain
                    Test-OktaConnection -OktaDomain $domain -ApiToken $newVal
                } else {
                    Write-Host "  No change." -ForegroundColor DarkGray
                }
                Invoke-PausePrompt
            }

            '3' {
                Write-Host ""
                Write-Host "  Current: $($cfg.EntraTenantId)" -ForegroundColor DarkGray
                $newVal = (Read-Host "  New Entra Tenant ID (GUID)").Trim()
                if ($newVal -and $newVal -ne $cfg.EntraTenantId) {
                    Invoke-SaveConfigField -ConfigPath $configPath `
                                           -Field 'EntraTenantId' -Value $newVal
                    $script:CurrentProject.EntraTenantId = $newVal
                    Write-Host "  ✓ Tenant ID updated." -ForegroundColor Green
                } else {
                    Write-Host "  No change." -ForegroundColor DarkGray
                }
                Invoke-PausePrompt
            }

            '4' {
                Write-Host ""
                Write-Host "  Current: $($cfg.EntraClientId)" -ForegroundColor DarkGray
                $newVal = (Read-Host "  New Entra Client ID (App Registration GUID)").Trim()
                if ($newVal -and $newVal -ne $cfg.EntraClientId) {
                    Invoke-SaveConfigField -ConfigPath $configPath `
                                           -Field 'EntraClientId' -Value $newVal
                    $script:CurrentProject.EntraClientId = $newVal
                    Write-Host "  ✓ Client ID updated." -ForegroundColor Green
                } else {
                    Write-Host "  No change." -ForegroundColor DarkGray
                }
                Invoke-PausePrompt
            }

            '5' {
                Write-Host ""
                Write-Host "  Paste your Entra App Registration client secret." -ForegroundColor DarkGray
                Write-Host "  Azure Portal → App Registrations → [your app] → Certificates & secrets" -ForegroundColor DarkGray
                Write-Host ""
                $newVal = Invoke-SecureRead -Prompt "  Client Secret"
                if ($newVal) {
                    Set-ProjectSecret -ProjectId $projectId `
                                      -SecretType 'GraphClientSecret' -Value $newVal
                    Write-Host "  ✓ Client secret saved." -ForegroundColor Green
                    Write-Host "  Testing..." -ForegroundColor DarkGray
                    $fresh = Get-Content $configPath -Raw | ConvertFrom-Json
                    Test-EntraConnection -TenantId $fresh.EntraTenantId `
                                         -ClientId $fresh.EntraClientId `
                                         -ClientSecret $newVal
                } else {
                    Write-Host "  No change." -ForegroundColor DarkGray
                }
                Invoke-PausePrompt
            }

            '6' {
                Write-Host ""
                $token = Get-ProjectSecret -ProjectId $projectId -SecretType 'OktaApiToken'
                if (-not $token -or $token.Length -eq 0) {
                    Write-Host "  ✗ No Okta API token stored. Use option [2] to set it." -ForegroundColor Red
                } else {
                    $fresh = Get-Content $configPath -Raw | ConvertFrom-Json
                    Test-OktaConnection -OktaDomain $fresh.OktaDomain -ApiToken $token
                }
                Invoke-PausePrompt
            }

            '7' {
                Write-Host ""
                $fresh  = Get-Content $configPath -Raw | ConvertFrom-Json
                $secret = Get-ProjectSecret -ProjectId $projectId -SecretType 'GraphClientSecret'
                if (-not $secret -or $secret.Length -eq 0) {
                    Write-Host "  ✗ No client secret stored. Use option [5] to set it." -ForegroundColor Red
                } else {
                    Test-EntraConnection -TenantId $fresh.EntraTenantId `
                                         -ClientId $fresh.EntraClientId `
                                         -ClientSecret $secret
                }
                Invoke-PausePrompt
            }

            '8' {
                Write-Host ""
                $fresh  = Get-Content $configPath -Raw | ConvertFrom-Json
                $token  = Get-ProjectSecret -ProjectId $projectId -SecretType 'OktaApiToken'
                $secret = Get-ProjectSecret -ProjectId $projectId -SecretType 'GraphClientSecret'

                Write-Host "  ── Okta ──" -ForegroundColor DarkGray
                if ($token -and $token.Length -gt 0) {
                    Test-OktaConnection -OktaDomain $fresh.OktaDomain -ApiToken $token
                } else {
                    Write-Host "  ✗ No Okta API token stored." -ForegroundColor Red
                }

                Write-Host ""
                Write-Host "  ── Entra ──" -ForegroundColor DarkGray
                if ($secret -and $secret.Length -gt 0) {
                    Test-EntraConnection -TenantId $fresh.EntraTenantId `
                                          -ClientId $fresh.EntraClientId `
                                          -ClientSecret $secret
                } else {
                    Write-Host "  ✗ No client secret stored." -ForegroundColor Red
                }
                Invoke-PausePrompt
            }

            { $_ -in @('Q','QUIT','EXIT','B','BACK') } {
                return
            }

            default {
                Write-Host "  Invalid choice." -ForegroundColor Yellow
                Start-Sleep -Milliseconds 600
            }
        }
    }
}


# ── Helpers private to this file ──────────────────────────────────────────────

function Invoke-SaveConfigField {
    <#
        Updates a single field in config.json without touching other fields.
    #>
    param(
        [string]$ConfigPath,
        [string]$Field,
        [string]$Value
    )
    $obj = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $obj | Add-Member -NotePropertyName $Field -NotePropertyValue $Value -Force
    $obj | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8
}

function Invoke-SecureRead {
    <#
        Reads a secret value using Read-Host -AsSecureString (input masked with asterisks).
        Returns the SecureString directly — never converted to plaintext.
        The SecureString is passed to Set-ProjectSecret and stored in SecretStore.
    #>
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    if ($secure.Length -eq 0) { return $null }
    return $secure
}

function Invoke-PausePrompt {
    Write-Host ""
    Write-Host "  Press Enter to continue..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}

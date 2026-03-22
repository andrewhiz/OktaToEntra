# Public/Project/New-OktaToEntraProject.ps1

function New-OktaToEntraProject {
    <#
    .SYNOPSIS
        Creates a new OktaToEntra migration project and stores credentials securely.

    .DESCRIPTION
        Initialises the local SQLite database, stores Okta API token and Entra
        client credentials in the SecretStore vault, and sets the new project as
        the active session project.

    .PARAMETER Name
        A friendly name for this migration project.

    .PARAMETER OktaDomain
        Your Okta domain, e.g. "mycompany.okta.com" or "mycompany.oktapreview.com".

    .PARAMETER OktaApiToken
        An Okta API token with read permissions (okta.apps.read, okta.groups.read, okta.users.read).

    .PARAMETER EntraTenantId
        The Azure AD / Entra tenant ID (GUID).

    .PARAMETER EntraClientId
        The App Registration client ID used for Microsoft Graph access.

    .PARAMETER EntraClientSecret
        The client secret for the Graph App Registration.

    .EXAMPLE
        New-OktaToEntraProject -Name "Contoso Migration" `
            -OktaDomain "contoso.okta.com" `
            -OktaApiToken "00abc..." `
            -EntraTenantId "11111111-..." `
            -EntraClientId "22222222-..." `
            -EntraClientSecret "secretvalue"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$OktaDomain,
        [Parameter(Mandatory)][SecureString]$OktaApiToken,
        [Parameter(Mandatory)][string]$EntraTenantId,
        [Parameter(Mandatory)][string]$EntraClientId,
        [Parameter(Mandatory)][SecureString]$EntraClientSecret
    )

    Write-Header "Creating New Project: $Name"

    # ── Validate inputs ──────────────────────────────────────────────────────
    $OktaDomain = $OktaDomain.TrimEnd('/')
    if ($OktaDomain -notmatch '^[\w.-]+\.okta(preview)?\.com$') {
        Write-Warn "OktaDomain format looks unusual. Expected: yourorg.okta.com"
    }

    # ── Set up directory ─────────────────────────────────────────────────────
    $projectId  = New-Guid
    $dataRoot   = Get-DataRoot
    $projectDir = Join-Path $dataRoot $projectId
    New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
    Write-Success "Created project directory"

    # ── Initialise database ──────────────────────────────────────────────────
    $dbPath = Join-Path $projectDir "project.db"
    Initialize-Database -DbPath $dbPath
    Write-Success "Initialised local database"

    # ── Insert project record ─────────────────────────────────────────────────
    $now = Get-UtcNow
    Invoke-SqliteQuery -DataSource $dbPath -Query @"
INSERT INTO projects (id, name, okta_domain, entra_tenant_id, created_at, updated_at, status)
VALUES (@id, @name, @okta, @entra, @now, @now, 'active')
"@ -SqlParameters @{
        id    = $projectId
        name  = $Name
        okta  = $OktaDomain
        entra = $EntraTenantId
        now   = $now
    } | Out-Null

    # ── Store configuration JSON (non-secret) ────────────────────────────────
    $config = @{
        ProjectId     = $projectId
        Name          = $Name
        OktaDomain    = $OktaDomain
        EntraTenantId = $EntraTenantId
        EntraClientId = $EntraClientId
        DbPath        = $dbPath
        CreatedAt     = $now
    }
    $configPath = Join-Path $projectDir "config.json"
    $config | ConvertTo-Json | Set-Content $configPath
    Write-Success "Saved project configuration"

    # ── Store secrets in vault ───────────────────────────────────────────────
    Initialize-Vault

    Write-Info "Storing credentials in SecretStore vault..."
    Set-ProjectSecret -ProjectId $projectId -SecretType 'OktaApiToken'      -Value $OktaApiToken
    Set-ProjectSecret -ProjectId $projectId -SecretType 'GraphClientSecret' -Value $EntraClientSecret
    Write-Success "Credentials stored securely"

    # ── Test connections ─────────────────────────────────────────────────────
    Write-Section "Testing Connections"

    $oktaOk  = Test-OktaConnection  -OktaDomain $OktaDomain -ApiToken $OktaApiToken -Silent
    $entraOk = Test-EntraConnection -TenantId $EntraTenantId -ClientId $EntraClientId -ClientSecret $EntraClientSecret -Silent

    if ($oktaOk)  { Write-Success "Okta connection verified" }
    else          { Write-Warn    "Okta connection failed — check domain and API token" }

    if ($entraOk) { Write-Success "Entra / Graph connection verified" }
    else          { Write-Warn    "Entra connection failed — check tenant ID, client ID, and secret" }

    # ── Activate project in session ───────────────────────────────────────────
    $script:CurrentProject = $config
    $script:DbPath         = $dbPath

    Write-Section "Summary"
    Write-Host "  Project ID : " -NoNewline; Write-Host $projectId -ForegroundColor Cyan
    Write-Host "  Name       : " -NoNewline; Write-Host $Name -ForegroundColor White
    Write-Host "  Okta Domain: " -NoNewline; Write-Host $OktaDomain -ForegroundColor White
    Write-Host "  Entra Tenant: " -NoNewline; Write-Host $EntraTenantId -ForegroundColor White
    Write-Host ""
    Write-Success "Project created and set as active. Run Sync-OktaApps to begin."
    Write-Host ""

    return [PSCustomObject]$config
}

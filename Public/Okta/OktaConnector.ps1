# Public/Okta/OktaConnector.ps1

function Test-OktaConnection {
    <#
    .SYNOPSIS
        Validates an Okta API token and domain. Returns $true on success.

    .PARAMETER OktaDomain
        Okta domain, e.g. "myorg.okta.com". If omitted, uses the active project.

    .PARAMETER ApiToken
        Okta SSWS API token. If omitted, retrieved from vault for active project.

    .PARAMETER Silent
        Suppress console output (for use during project creation).
    #>
    [CmdletBinding()]
    param(
        [string]$OktaDomain,
        [SecureString]$ApiToken,
        [switch]$Silent
    )

    # Resolve from active project if not supplied
    if (-not $OktaDomain -or -not $ApiToken) {
        if (-not $script:CurrentProject) { throw "No active project. Provide -OktaDomain and -ApiToken." }
        $OktaDomain = $script:CurrentProject.OktaDomain
        $ApiToken   = Get-ProjectSecret -ProjectId $script:CurrentProject.ProjectId -SecretType 'OktaApiToken'
    }

    # Pre-flight: normalise domain format — strip protocol prefix and trailing slash
    if ($OktaDomain -match '^https?://') {
        $OktaDomain = $OktaDomain -replace '^https?://', ''
        if (-not $Silent) { Write-Warn "Domain should not include 'https://'. Using: $OktaDomain" }
    }
    $OktaDomain = $OktaDomain.TrimEnd('/')

    if (-not $Silent) { Write-Info "Testing Okta connection to $OktaDomain ..." }

    try {
        $org = Invoke-OktaApi -OktaDomain $OktaDomain -ApiToken $ApiToken `
                              -Endpoint '/org' -NoPaginate
        if (-not $Silent) {
            Write-Success "Connected: $($org.companyName) (id: $($org.id))"
        }
        return $true
    } catch {
        if (-not $Silent) {
            # Parse the structured Okta error embedded in the thrown message.
            # Invoke-OktaApi throws: "Okta API error [$statusCode] on $url : {json}"
            $rawMsg     = "$_"
            $statusCode = $null
            $oktaErr    = $null
            if ($rawMsg -match 'Okta API error \[(\d+)\] on [^\s]+ : (.+)$') {
                $statusCode = $Matches[1]
                try { $oktaErr = $Matches[2] | ConvertFrom-Json } catch {}
            }

            $errCode    = $oktaErr?.errorCode
            $errSummary = $oktaErr?.errorSummary
            $errCauses  = $oktaErr?.errorCauses

            Write-Fail "Okta connection failed (domain: $OktaDomain)"
            if ($statusCode) { Write-Info "  HTTP Status : $statusCode" }
            if ($errCode)    { Write-Info "  Error Code  : $errCode" }
            if ($errSummary) { Write-Info "  Summary     : $errSummary" }
            if ($errCauses -and $errCauses.Count -gt 0) {
                Write-Info "  Causes:"
                foreach ($cause in @($errCauses)) {
                    Write-Info "    • $($cause.errorSummary)"
                }
            }

            switch ($errCode) {
                'E0000011' {
                    Write-Warn "  Cause : Invalid API token — it may have been deactivated or never activated."
                    Write-Info "  Verify in Okta Admin: Security → API → Tokens"
                }
                'E0000006' {
                    Write-Warn "  Cause : Insufficient permissions for this API token."
                    Write-Info "  Ensure the token belongs to a user with API access rights."
                }
                'E0000095' {
                    Write-Warn "  Cause : SSL is required. Domain must be accessed over HTTPS."
                }
                'E0000047' {
                    Write-Warn "  Cause : Okta rate limit reached. Wait a moment and try again."
                }
                default {
                    if (-not $errCode) {
                        # No Okta error code — likely a network or DNS failure
                        if ($rawMsg -match 'NameResolutionFailure|No such host|Name or service not known|Could not resolve') {
                            Write-Warn "  Cause : Cannot resolve '$OktaDomain'. Check the domain name."
                            Write-Info "  Expected format: myorg.okta.com  (no https://, no trailing slash)"
                        } elseif ($rawMsg -match 'SSL|TLS|certificate') {
                            Write-Warn "  Cause : SSL/TLS error connecting to '$OktaDomain'."
                        } else {
                            Write-Warn "  Detail: $rawMsg"
                        }
                    }
                }
            }
        }
        return $false
    }
}


function Sync-OktaApps {
    <#
    .SYNOPSIS
        Pulls all apps from Okta and upserts them into the local database.
        Creates a MigrationItem stub for any newly discovered apps.

    .PARAMETER IncludeInactive
        Include Okta apps with status INACTIVE (excluded by default).

    .PARAMETER Force
        Re-sync all apps, not just those changed since last sync.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeInactive,
        [switch]$Force
    )

    if (-not $script:CurrentProject) { throw "No active project. Run Select-OktaToEntraProject first." }

    $projectId = $script:CurrentProject.ProjectId
    $dbPath    = $script:DbPath
    $domain    = $script:CurrentProject.OktaDomain
    $token     = Get-ProjectSecret -ProjectId $projectId -SecretType 'OktaApiToken'

    Write-Header "Syncing Okta Apps"
    Write-Info "Domain  : $domain"
    Write-Info "Project : $($script:CurrentProject.Name)"
    Write-Host ""

    # ── Fetch apps from Okta ─────────────────────────────────────────────────
    Write-Info "Fetching apps from Okta..."
    $endpoint = '/apps?limit=200'
    if (-not $IncludeInactive) { $endpoint += '&filter=status+eq+"ACTIVE"' }

    try {
        $oktaApps = Invoke-OktaApi -OktaDomain $domain -ApiToken $token -Endpoint $endpoint
    } catch {
        Write-Fail "Failed to fetch Okta apps: $_"
        return
    }

    Write-Success "Fetched $($oktaApps.Count) apps from Okta"
    Write-Info "Syncing to local database..."

    $new = 0; $updated = 0; $skipped = 0

    foreach ($app in $oktaApps) {
        $now = Get-UtcNow

        # ── Fetch assignment counts ──────────────────────────────────────────
        $userCount = 0; $groupCount = 0
        try {
            $users  = Invoke-OktaApi -OktaDomain $domain -ApiToken $token `
                                     -Endpoint "/apps/$($app.id)/users?limit=1" -NoPaginate
            # Use pagination header count trick; fallback to list length
            $userCount = if ($users -is [array]) { $users.Count } else { 1 }

            $groups = Invoke-OktaApi -OktaDomain $domain -ApiToken $token `
                                     -Endpoint "/apps/$($app.id)/groups?limit=200" -NoPaginate
            $groupCount = if ($groups -is [array]) { $groups.Count } else { 0 }
        } catch { <# non-fatal #> }

        # ── Extract SSO metadata ─────────────────────────────────────────────
        $loginUrl    = $app.settings?.app?.loginUrl
        $audience    = $app.settings?.signOn?.audience
        $entityId    = $app.settings?.signOn?.entityId ?? $app.settings?.signOn?.issuer
        $metadataUrl = $null
        $redirectUris = $null

        if ($app.signOnMode -in @('SAML_2_0','SAML_1_1')) {
            $metadataUrl = "https://$domain/app/$($app.name)/$($app.id)/sso/saml/metadata"
        } elseif ($app.signOnMode -eq 'OPENID_CONNECT') {
            $redirectUris = ($app.settings?.oauthClient?.redirect_uris -join ',')
            $audience     = $app.settings?.oauthClient?.client_id
        }

        # ── Extract username / attribute mapping ─────────────────────────────
        $attrType     = $null
        $attrTemplate = $null
        $attrResolved = $null
        $attrSuffix   = $null

        $credTemplate = $app.credentials?.userNameTemplate
        if ($credTemplate) {
            $attrType     = $credTemplate.type      # BUILT_IN, CUSTOM, NONE
            $attrTemplate = $credTemplate.template  # raw expression
            $attrSuffix   = $credTemplate.suffix    # e.g. "@company.com"

            # Translate raw template to a human-readable label
            $attrResolved = switch -Regex ($attrTemplate) {
                '^\$\{source\.login\}$'                        { 'Okta Username (login)' }
                '^\$\{source\.email\}$'                        { 'Email (source.email)' }
                '^\$\{user\.email\}$'                          { 'Email (user.email)' }
                '^\$\{user\.login\}$'                          { 'Okta Username (user.login)' }
                '^\$\{source\.login\s*\|.*substringBefore.*\}' { 'Username (strip domain)' }
                '^\$\{user\.samAccountName\}$'                 { 'SAM Account Name' }
                '^\$\{user\.windowsUPN\}$'                     { 'Windows UPN' }
                '^\$\{user\.upn\}$'                            { 'UPN (user.upn)' }
                '^\$\{user\.employeeNumber\}$'                 { 'Employee Number' }
                '^\$\{user\.displayName\}$'                    { 'Display Name' }
                default {
                    if ($attrType -eq 'NONE') { 'Not configured (NONE)' }
                    elseif ($attrTemplate)    { "Custom: $attrTemplate" }
                    else                      { 'Unknown' }
                }
            }

            if ($attrSuffix) { $attrResolved += " + suffix '$attrSuffix'" }
        }

        # ── Determine risk flag ───────────────────────────────────────────────
        # HIGH:   custom expressions or SAM/UPN — likely to differ between users
        # MEDIUM: email when org has mixed email/UPN, or suffix appended
        # LOW:    standard UPN/email with no suffix
        $riskFlag = switch -Regex ($attrResolved) {
            'SAM Account Name|windowsUPN|Custom:|Employee Number|strip domain' { 'HIGH'   }
            "suffix|user\.upn|UPN \(user"                                      { 'MEDIUM' }
            'Not configured'                                                   { 'HIGH'   }
            default                                                            { 'LOW'    }
        }

        $rawJson = $app | ConvertTo-Json -Depth 10 -Compress

        # ── Check if app already exists ──────────────────────────────────────
        $existing = Invoke-SqliteQuery -DataSource $dbPath -Query `
            "SELECT id FROM okta_apps WHERE project_id=@pid AND okta_app_id=@oid" `
            -SqlParameters @{ pid=$projectId; oid=$app.id }

        if ($existing) {
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
UPDATE okta_apps SET
    label=@label, sign_on_mode=@mode, okta_status=@status,
    login_url=@login, redirect_uris=@ruris, audience=@aud,
    entity_id=@eid, metadata_url=@meta,
    assigned_users=@ausers, assigned_groups=@agroups,
    username_attr_type=@attype, username_attr_template=@attempl,
    username_attr_resolved=@atres, username_attr_suffix=@atsuffix,
    raw_json=@json, last_synced=@now
WHERE project_id=@pid AND okta_app_id=@oid
"@ -SqlParameters @{
                label=($app.label ?? $app.name); mode=$app.signOnMode; status=$app.status
                login=$loginUrl; ruris=$redirectUris; aud=$audience; eid=$entityId
                meta=$metadataUrl; ausers=$userCount; agroups=$groupCount
                attype=$attrType; attempl=$attrTemplate; atres=$attrResolved; atsuffix=$attrSuffix
                json=$rawJson; now=$now; pid=$projectId; oid=$app.id
            } | Out-Null

            # Also update the risk flag on the migration item
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
UPDATE migration_items SET attr_risk_flag=@risk, updated_at=@now
WHERE okta_app_id=(SELECT id FROM okta_apps WHERE project_id=@pid AND okta_app_id=@oid)
  AND (attr_risk_flag IS NULL OR attr_risk_flag='')
"@ -SqlParameters @{ risk=$riskFlag; now=$now; pid=$projectId; oid=$app.id } | Out-Null
            $updated++
        } else {
            $rowId = New-Guid
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
INSERT INTO okta_apps
    (id,project_id,okta_app_id,label,sign_on_mode,okta_status,login_url,
     redirect_uris,audience,entity_id,metadata_url,
     assigned_users,assigned_groups,
     username_attr_type,username_attr_template,username_attr_resolved,username_attr_suffix,
     raw_json,last_synced)
VALUES
    (@id,@pid,@oid,@label,@mode,@status,@login,
     @ruris,@aud,@eid,@meta,
     @ausers,@agroups,
     @attype,@attempl,@atres,@atsuffix,
     @json,@now)
"@ -SqlParameters @{
                id=$rowId; pid=$projectId; oid=$app.id
                label=($app.label ?? $app.name); mode=$app.signOnMode; status=$app.status
                login=$loginUrl; ruris=$redirectUris; aud=$audience; eid=$entityId
                meta=$metadataUrl; ausers=$userCount; agroups=$groupCount
                attype=$attrType; attempl=$attrTemplate; atres=$attrResolved; atsuffix=$attrSuffix
                json=$rawJson; now=$now
            } | Out-Null

            # Create migration item with risk flag pre-populated
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
INSERT INTO migration_items (id,project_id,okta_app_id,status,priority,attr_risk_flag,created_at,updated_at)
VALUES (@id,@pid,@aid,'DISCOVERED','MEDIUM',@risk,@now,@now)
"@ -SqlParameters @{ id=(New-Guid); pid=$projectId; aid=$rowId; risk=$riskFlag; now=$now } | Out-Null

            $new++
        }
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Success "Sync complete"
    Write-Host "  New apps       : " -NoNewline; Write-Host $new     -ForegroundColor Green
    Write-Host "  Updated apps   : " -NoNewline; Write-Host $updated -ForegroundColor Yellow
    Write-Host "  Total in store : " -NoNewline; Write-Host ($new + $updated + $skipped) -ForegroundColor White
    Write-Host ""
    Write-Info "Run Get-MigrationStatus to see the full list."
    Write-Host ""
}


function Get-OktaAppDetail {
    <#
    .SYNOPSIS
        Returns the cached Okta app data for a specific app in the active project.

    .PARAMETER Label
        App label to search for (partial match supported).

    .PARAMETER OktaAppId
        Exact Okta App ID.
    #>
    [CmdletBinding()]
    param(
        [string]$Label,
        [string]$OktaAppId
    )

    $dbPath = Get-DbPath

    if ($OktaAppId) {
        $row = Invoke-SqliteQuery -DataSource $dbPath -Query `
            "SELECT * FROM okta_apps WHERE okta_app_id=@id" `
            -SqlParameters @{ id=$OktaAppId }
    } elseif ($Label) {
        $row = Invoke-SqliteQuery -DataSource $dbPath -Query `
            "SELECT * FROM okta_apps WHERE label LIKE @label" `
            -SqlParameters @{ label="%$Label%" }
    } else {
        throw "Provide -Label or -OktaAppId"
    }

    if ($row -and $row.raw_json) {
        $detail = $row.raw_json | ConvertFrom-Json
        return $detail
    }
    return $row
}

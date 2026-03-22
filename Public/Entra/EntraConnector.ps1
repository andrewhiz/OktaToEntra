# Public/Entra/EntraConnector.ps1

function Test-EntraConnection {
    <#
    .SYNOPSIS
        Validates the Graph API credentials for the active project.
    #>
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [string]$ClientId,
        [SecureString]$ClientSecret,
        [switch]$Silent
    )

    # Resolve from active project if not supplied
    if (-not $TenantId) {
        if (-not $script:CurrentProject) { throw "No active project." }
        $TenantId     = $script:CurrentProject.EntraTenantId
        $ClientId     = $script:CurrentProject.EntraClientId
        $ClientSecret = Get-ProjectSecret -ProjectId $script:CurrentProject.ProjectId `
                                          -SecretType 'GraphClientSecret'
    }

    if (-not $Silent) { Write-Info "Testing Entra / Graph connection to tenant $TenantId ..." }

    # Step 1: acquire token
    $token = $null
    try {
        $token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    } catch {
        if (-not $Silent) {
            Write-Fail "Token acquisition failed."
            $msg = "$_"
            if     ($msg -match 'AADSTS70011')  { Write-Warn "  Cause : Invalid scope or client secret. Verify the secret hasn't expired." }
            elseif ($msg -match 'AADSTS50011')  { Write-Warn "  Cause : Reply URL mismatch. Check the App Registration redirect URIs." }
            elseif ($msg -match 'AADSTS700016') { Write-Warn "  Cause : Application '$ClientId' not found in tenant '$TenantId'. Check the Client ID and Tenant ID." }
            elseif ($msg -match 'AADSTS90002')  { Write-Warn "  Cause : Tenant '$TenantId' not found. Verify the Tenant ID (not domain name)." }
            elseif ($msg -match 'AADSTS7000215'){ Write-Warn "  Cause : Invalid client secret. The secret may have expired — generate a new one in the App Registration." }
            elseif ($msg -match 'unauthorized_client') { Write-Warn "  Cause : App not authorised for client_credentials flow. Ensure 'Application' (not Delegated) permissions are used and admin consent is granted." }
            else                                { Write-Warn "  Detail: $msg" }
            Write-Info "  Checklist:"
            Write-Info "    1. App Registration exists in tenant $TenantId"
            Write-Info "    2. Client secret is current (check expiry in Azure Portal)"
            Write-Info "    3. API permissions: Application.ReadWrite.All + AppRoleAssignment.ReadWrite.All + Group.Read.All"
            Write-Info "    4. Admin consent granted for all three permissions"
        }
        return $false
    }

    # Step 2: call Graph to verify permissions
    try {
        $org     = Invoke-GraphApi -AccessToken $token -Endpoint '/organization' -NoPaginate
        $orgName = if ($org.value) { $org.value[0].displayName } else { $org.displayName }
        if (-not $Silent) { Write-Success "Connected to tenant: $orgName ($TenantId)" }
        return $true
    } catch {
        if (-not $Silent) {
            Write-Fail "Token acquired but Graph API call failed: $_"
            if ("$_" -match '403|Forbidden') {
                Write-Warn "  Cause : Permissions issue. Ensure admin consent is granted for all required permissions."
            }
        }
        return $false
    }
}


function New-EntraAppStub {
    <#
    .SYNOPSIS
        Creates an Entra ID App Registration stub for one or more migration items.

    .DESCRIPTION
        Creates a minimal app registration in Entra ID — display name set, tagged as
        OktaMigration, a placeholder redirect URI — ready for the engineer to configure
        the full SSO settings manually. Updates the migration item status to STUB_CREATED.

    .PARAMETER OktaAppId
        The Okta App ID (row ID in local DB) to create a stub for.

    .PARAMETER All
        Create stubs for all migration items with status READY.

    .PARAMETER WhatIf
        Show what would be created without actually calling Graph API.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OktaAppId,
        [switch]$All
    )

    if (-not $script:CurrentProject) { throw "No active project." }
    $projectId = $script:CurrentProject.ProjectId
    $dbPath    = $script:DbPath

    # ── Acquire Graph token ───────────────────────────────────────────────────
    $tenantId     = $script:CurrentProject.EntraTenantId
    $clientId     = $script:CurrentProject.EntraClientId
    $clientSecret = Get-ProjectSecret -ProjectId $projectId -SecretType 'GraphClientSecret'

    try {
        $token = Get-GraphToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    } catch {
        Write-Fail "Failed to acquire Graph token: $_"
        return
    }

    # ── Resolve target migration items ────────────────────────────────────────
    if ($All) {
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id AS item_id, oa.okta_app_id, oa.label, oa.sign_on_mode,
       oa.redirect_uris, oa.audience, mi.status
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
WHERE mi.project_id=@pid AND mi.status='READY'
"@ -SqlParameters @{ pid=$projectId }

        if (-not $items -or $items.Count -eq 0) {
            Write-Warn "No items with status READY. Set items to READY first using Update-MigrationItem."
            return
        }
        Write-Header "Create Entra Stubs for All READY Apps ($($items.Count) apps)"
    } else {
        if (-not $OktaAppId) { throw "Provide -OktaAppId or use -All" }
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id AS item_id, oa.okta_app_id, oa.label, oa.sign_on_mode,
       oa.redirect_uris, oa.audience, mi.status
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
WHERE mi.project_id=@pid AND oa.okta_app_id=@oid
"@ -SqlParameters @{ pid=$projectId; oid=$OktaAppId }

        Write-Header "Create Entra Stub: $($items[0].label)"
    }

    if (-not (Confirm-Action "This will create $($items.Count) app registration(s) in Entra tenant $tenantId.")) {
        Write-Info "Cancelled."
        return
    }

    $created = 0; $failed = 0

    foreach ($item in @($items)) {

        Write-Info "Creating stub for: $($item.label)"

        # ── Build app registration body ───────────────────────────────────────
        $displayName  = $item.label
        $redirectUris = @()
        if ($item.redirect_uris) {
            $redirectUris = $item.redirect_uris -split ',' | Where-Object { $_ }
        }
        if ($redirectUris.Count -eq 0) {
            $redirectUris = @("https://placeholder.migration.local/callback")
        }

        $appBody = @{
            displayName            = $displayName
            signInAudience         = "AzureADMyOrg"
            tags                   = @("OktaMigration", "HideApp")
            notes                  = "Stub created by OktaToEntra migration tool. SSO configuration pending."
            web                    = @{
                redirectUris = $redirectUris
            }
            identifierUris = @()
        }

        # Add OIDC client info if OIDC app
        if ($item.sign_on_mode -eq 'OPENID_CONNECT' -and $item.audience) {
            $appBody.web.implicitGrantSettings = @{
                enableAccessTokenIssuance = $false
                enableIdTokenIssuance     = $false
            }
        }

        if ($PSCmdlet.ShouldProcess($displayName, "Create Entra App Registration")) {
            try {
                $newApp = Invoke-GraphApi -AccessToken $token -Endpoint '/applications' `
                                          -Method 'POST' -Body $appBody -NoPaginate

                $entraAppId    = $newApp.appId        # Client ID (GUID)
                $entraObjectId = $newApp.id            # Object ID

                # ── Update local DB ───────────────────────────────────────────
                $now = Get-UtcNow
                Invoke-SqliteQuery -DataSource $dbPath -Query @"
UPDATE migration_items
SET status='STUB_CREATED', entra_app_id=@appid, entra_object_id=@oid,
    updated_at=@now
WHERE id=@iid
"@ -SqlParameters @{ appid=$entraAppId; oid=$entraObjectId; now=$now; iid=$item.item_id } | Out-Null

                Write-AuditLog -DbPath $dbPath -ProjectId $projectId `
                    -EntityType 'migration_item' -EntityId $item.item_id `
                    -Action 'ENTRA_STUB_CREATED' -NewValue $entraAppId

                Write-Success "  Created: $displayName (appId: $entraAppId)"
                $created++

            } catch {
                Write-Fail "  Failed for $($item.label): $_"
                Write-AuditLog -DbPath $dbPath -ProjectId $projectId `
                    -EntityType 'migration_item' -EntityId $item.item_id `
                    -Action 'ENTRA_STUB_FAILED' -NewValue "$_"
                $failed++
            }
        }
    }

    Write-Host ""
    Write-Host "  Created : " -NoNewline; Write-Host $created -ForegroundColor Green
    Write-Host "  Failed  : " -NoNewline; Write-Host $failed  -ForegroundColor Red
    Write-Host ""
}


function New-EntraServicePrincipal {
    <#
    .SYNOPSIS
        Creates the Service Principal (Enterprise Application) for an existing app registration.
        Required before user/group assignments can be made.

    .PARAMETER OktaAppId
        Okta App ID of the migration item.

    .PARAMETER All
        Create SPs for all items in STUB_CREATED status that don't yet have one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OktaAppId,
        [switch]$All
    )

    if (-not $script:CurrentProject) { throw "No active project." }
    $projectId    = $script:CurrentProject.ProjectId
    $dbPath       = $script:DbPath
    $clientSecret = Get-ProjectSecret -ProjectId $projectId -SecretType 'GraphClientSecret'
    $token        = Get-GraphToken -TenantId $script:CurrentProject.EntraTenantId `
                                   -ClientId $script:CurrentProject.EntraClientId `
                                   -ClientSecret $clientSecret

    if ($All) {
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id AS item_id, oa.label, mi.entra_app_id, mi.entra_sp_id
FROM migration_items mi JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND mi.status='STUB_CREATED' AND mi.entra_app_id IS NOT NULL
  AND (mi.entra_sp_id IS NULL OR mi.entra_sp_id='')
"@ -SqlParameters @{ pid=$projectId }
    } else {
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id AS item_id, oa.label, mi.entra_app_id, mi.entra_sp_id
FROM migration_items mi JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND oa.okta_app_id=@oid
"@ -SqlParameters @{ pid=$projectId; oid=$OktaAppId }
    }

    foreach ($item in @($items)) {
        if ($item.entra_sp_id) {
            Write-Info "$($item.label) already has a Service Principal: $($item.entra_sp_id)"
            continue
        }

        Write-Info "Creating Service Principal for: $($item.label)"

        if ($PSCmdlet.ShouldProcess($item.label, "Create Service Principal")) {
            try {
                $spBody = @{ appId = $item.entra_app_id; tags = @("HideApp","WindowsAzureActiveDirectoryIntegratedApp") }
                $sp = Invoke-GraphApi -AccessToken $token -Endpoint '/servicePrincipals' `
                                      -Method 'POST' -Body $spBody -NoPaginate

                Invoke-SqliteQuery -DataSource $dbPath -Query `
                    "UPDATE migration_items SET entra_sp_id=@spid, updated_at=@now WHERE id=@iid" `
                    -SqlParameters @{ spid=$sp.id; now=(Get-UtcNow); iid=$item.item_id } | Out-Null

                Write-Success "Service Principal created: $($sp.id)"
            } catch {
                Write-Fail "Failed for $($item.label): $_"
            }
        }
    }
}


function Add-EntraAppAssignment {
    <#
    .SYNOPSIS
        Assigns users and/or groups from the Okta app to the corresponding Entra app.

    .DESCRIPTION
        By default, replicates Okta assignments 1:1. If a group mapping exists
        (via Set-AppGroupMapping), uses the mapped Entra group ID instead.

    .PARAMETER OktaAppId
        Okta App ID of the app to process assignments for.

    .PARAMETER All
        Process all items with status STUB_CREATED or IN_PROGRESS.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OktaAppId,
        [switch]$All,
        [switch]$GroupsOnly,
        [switch]$UsersOnly
    )

    if (-not $script:CurrentProject) { throw "No active project." }
    $projectId = $script:CurrentProject.ProjectId
    $dbPath    = $script:DbPath
    $domain    = $script:CurrentProject.OktaDomain
    $oktaToken = Get-ProjectSecret -ProjectId $projectId -SecretType 'OktaApiToken'
    $clientSecret = Get-ProjectSecret -ProjectId $projectId -SecretType 'GraphClientSecret'
    $graphToken   = Get-GraphToken -TenantId $script:CurrentProject.EntraTenantId `
                                   -ClientId $script:CurrentProject.EntraClientId `
                                   -ClientSecret $clientSecret

    if ($All) {
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id AS item_id, oa.okta_app_id AS okta_id, oa.label,
       mi.entra_app_id, mi.entra_sp_id
FROM migration_items mi JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid
  AND mi.status IN ('STUB_CREATED','IN_PROGRESS')
  AND mi.entra_sp_id IS NOT NULL
"@ -SqlParameters @{ pid=$projectId }
    } else {
        if (-not $OktaAppId) { throw "Provide -OktaAppId or use -All" }
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id AS item_id, oa.okta_app_id AS okta_id, oa.label,
       mi.entra_app_id, mi.entra_sp_id
FROM migration_items mi JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND oa.okta_app_id=@oid
"@ -SqlParameters @{ pid=$projectId; oid=$OktaAppId }
    }

    if (-not $items -or $items.Count -eq 0) {
        Write-Warn "No eligible items found. Ensure stubs and service principals exist first."
        return
    }

    foreach ($item in @($items)) {
        Write-Section "Assigning: $($item.label)"

        # ── Load group mappings (if any) ──────────────────────────────────────
        $mappings = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT okta_group_id, entra_group_id FROM group_mappings
WHERE project_id=@pid AND okta_app_id=@aid
"@ -SqlParameters @{ pid=$projectId; aid=$item.item_id }

        $mappingLookup = @{}
        foreach ($m in @($mappings)) { $mappingLookup[$m.okta_group_id] = $m.entra_group_id }

        $assigned = 0; $skipped = 0; $failed = 0

        # ── Process GROUPS ───────────────────────────────────────────────────
        if (-not $UsersOnly) {
            try {
                $oktaGroups = Invoke-OktaApi -OktaDomain $domain -ApiToken $oktaToken `
                                             -Endpoint "/apps/$($item.okta_id)/groups"
                foreach ($grp in @($oktaGroups)) {
                    $entraGroupId = if ($mappingLookup[$grp.id]) {
                        $mappingLookup[$grp.id]   # use mapped group
                    } else {
                        # 1:1: look up Entra group by Okta group name
                        $grpDetail = Invoke-OktaApi -OktaDomain $domain -ApiToken $oktaToken `
                                                    -Endpoint "/groups/$($grp.id)" -NoPaginate
                        $grpName   = $grpDetail.profile.name
                        $found     = Invoke-GraphApi -AccessToken $graphToken `
                                                     -Endpoint "/groups?`$filter=displayName eq '$grpName'&`$select=id,displayName" `
                                                     -NoPaginate
                        if ($found.value -and $found.value.Count -gt 0) { $found.value[0].id } else { $null }
                    }

                    if (-not $entraGroupId) {
                        Write-Warn "  Group '$($grp.id)' not found in Entra — skipping (add a mapping with Set-AppGroupMapping)"
                        $skipped++; continue
                    }

                    if ($PSCmdlet.ShouldProcess($item.label, "Assign group $entraGroupId")) {
                        try {
                            $body = @{
                                principalId = $entraGroupId
                                resourceId  = $item.entra_sp_id
                                appRoleId   = "00000000-0000-0000-0000-000000000000"
                            }
                            Invoke-GraphApi -AccessToken $graphToken `
                                            -Endpoint '/servicePrincipalAppRoleAssignments' `
                                            -Method 'POST' -Body $body -NoPaginate | Out-Null

                            # Log to assignments table
                            Invoke-SqliteQuery -DataSource $dbPath -Query @"
INSERT OR IGNORE INTO assignments (id,project_id,migration_item_id,principal_id,principal_type,app_role_id,assigned_at)
VALUES (@id,@pid,@iid,@prin,'group','00000000-0000-0000-0000-000000000000',@now)
"@ -SqlParameters @{ id=(New-Guid); pid=$projectId; iid=$item.item_id; prin=$entraGroupId; now=(Get-UtcNow) } | Out-Null

                            Write-Success "  Group assigned: $entraGroupId"
                            $assigned++
                        } catch {
                            if ($_ -match '409|already exists') {
                                Write-Info "  Group $entraGroupId already assigned — skipping"
                                $skipped++
                            } else {
                                Write-Fail "  Failed to assign group $entraGroupId : $_"
                                $failed++
                            }
                        }
                    }
                }
            } catch { Write-Warn "Could not fetch Okta groups for $($item.label): $_" }
        }

        # ── Update status to IN_PROGRESS ──────────────────────────────────────
        Invoke-SqliteQuery -DataSource $dbPath -Query @"
UPDATE migration_items SET status='IN_PROGRESS', updated_at=@now WHERE id=@iid AND status='STUB_CREATED'
"@ -SqlParameters @{ now=(Get-UtcNow); iid=$item.item_id } | Out-Null

        Write-Host "  Assigned: $assigned | Skipped: $skipped | Failed: $failed" -ForegroundColor Gray
    }
    Write-Host ""
}

# Public/Reports/Reports.ps1

function Export-MigrationReport {
    <#
    .SYNOPSIS
        Exports a migration status report as CSV and an HTML dashboard.

    .PARAMETER OutputPath
        Folder to write report files to. Defaults to current directory.

    .PARAMETER Format
        One or more of: CSV, HTML. Defaults to both.

    .PARAMETER OpenHtml
        Automatically open the HTML report in the default browser.

    .PARAMETER Status
        Only include items with this status.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath = (Get-Location).Path,
        [ValidateSet('CSV','HTML')]
        [string[]]$Format = @('CSV','HTML'),
        [switch]$OpenHtml,
        [string]$Status
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId
    $projName  = $script:CurrentProject.Name
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    Write-Header "Exporting Migration Report"

    $whereExtra = ""
    if ($Status) { $whereExtra = "AND mi.status='$Status'" }

    $rows = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    oa.label                  AS AppName,
    oa.okta_app_id            AS OktaAppId,
    oa.sign_on_mode           AS Protocol,
    oa.okta_status            AS OktaStatus,
    oa.assigned_users         AS OktaUsers,
    oa.assigned_groups        AS OktaGroups,
    oa.audience               AS Audience,
    oa.entity_id              AS EntityId,
    oa.metadata_url           AS MetadataUrl,
    oa.username_attr_resolved AS OktaUsernameAttr,
    oa.username_attr_template AS OktaAttrTemplate,
    mi.attr_risk_flag         AS AttrRisk,
    mi.entra_claim_attribute  AS EntraClaimAttr,
    mi.entra_claim_notes      AS EntraClaimNotes,
    -- Usage
    mi.usage_flag             AS UsageFlag,
    mi.usage_last_gathered    AS UsageGathered,
    us.period_days            AS UsagePeriodDays,
    us.successful_logins      AS SuccessfulLogins,
    us.failed_logins          AS FailedLogins,
    us.unique_users           AS UniqueUsers,
    us.last_login_at          AS LastLoginAt,
    mi.status                 AS MigrationStatus,
    mi.priority               AS Priority,
    mi.owner_email            AS Owner,
    mi.entra_app_id           AS EntraAppId,
    mi.entra_object_id        AS EntraObjectId,
    mi.entra_sp_id            AS EntraSpId,
    mi.notes                  AS Notes,
    mi.blockers               AS Blockers,
    mi.created_at             AS DiscoveredAt,
    mi.updated_at             AS LastUpdated
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
LEFT JOIN app_usage_stats us ON us.id = (
    SELECT id FROM app_usage_stats
    WHERE okta_app_id = oa.id AND project_id = mi.project_id
    ORDER BY gathered_at DESC LIMIT 1
)
WHERE mi.project_id = @pid $whereExtra
ORDER BY
    CASE mi.priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    oa.label
"@ -SqlParameters @{ pid=$projectId }

    if (-not $rows) { Write-Warn "No data to export."; return }

    # ── CSV Export ─────────────────────────────────────────────────────────────
    if ('CSV' -in $Format) {
        $csvPath = Join-Path $OutputPath "MigrationReport_${timestamp}.csv"
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Success "CSV  : $csvPath"
    }

    # ── HTML Export ─────────────────────────────────────────────────────────────
    if ('HTML' -in $Format) {
        $htmlPath = Join-Path $OutputPath "MigrationReport_${timestamp}.html"
        $html = Build-HtmlReport -Rows $rows -ProjectName $projName
        $html | Set-Content -Path $htmlPath -Encoding UTF8
        Write-Success "HTML : $htmlPath"

        if ($OpenHtml) { Start-Process $htmlPath }
    }

    Write-Host ""
    Write-Host "  $($rows.Count) apps exported" -ForegroundColor White
    Write-Host ""
}


function Export-AppConfigPack {
    <#
    .SYNOPSIS
        Exports a JSON config pack per app containing all Okta SSO configuration
        data — ready to hand to an engineer for manual Entra configuration.

    .PARAMETER OktaAppId
        Export config for a specific app. If omitted, exports all apps.

    .PARAMETER OutputPath
        Folder to write JSON files to. Defaults to current directory.
    #>
    [CmdletBinding()]
    param(
        [string]$OktaAppId,
        [string]$OutputPath = (Get-Location).Path
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    $whereExtra = ""
    if ($OktaAppId) { $whereExtra = "AND oa.okta_app_id='$OktaAppId'" }

    $rows = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    oa.*, mi.id AS item_id, mi.status, mi.priority, mi.owner_email,
    mi.entra_app_id, mi.entra_object_id, mi.notes,
    mi.entra_claim_attribute, mi.attr_risk_flag,
    mi.usage_flag, mi.usage_last_gathered,
    us.period_days, us.successful_logins, us.failed_logins,
    us.unique_users, us.last_login_at, us.total_attempts
FROM okta_apps oa
JOIN migration_items mi ON mi.okta_app_id = oa.id
LEFT JOIN app_usage_stats us ON us.id = (
    SELECT id FROM app_usage_stats
    WHERE okta_app_id = oa.id AND project_id = mi.project_id
    ORDER BY gathered_at DESC LIMIT 1
)
WHERE oa.project_id = @pid $whereExtra
"@ -SqlParameters @{ pid=$projectId }

    if (-not $rows) { Write-Warn "No apps found."; return }

    Write-Header "Exporting App Config Packs"
    $packDir = Join-Path $OutputPath "ConfigPacks_$(Get-Date -Format 'yyyyMMdd')"
    New-Item -ItemType Directory -Path $packDir -Force | Out-Null

    $count = 0
    foreach ($row in @($rows)) {
        $safeName = ($row.label -replace '[^\w\-]', '_').Substring(0, [math]::Min(50, $row.label.Length))
        $filePath = Join-Path $packDir "${safeName}.json"

        $pack = @{
            generatedAt      = Get-UtcNow
            tool             = "OktaToEntra v$((Get-Module OktaToEntra -ErrorAction SilentlyContinue)?.Version?.ToString() ?? '?')"
            oktaApp          = @{
                id           = $row.okta_app_id
                label        = $row.label
                signOnMode   = $row.sign_on_mode
                status       = $row.okta_status
                loginUrl     = $row.login_url
                redirectUris = if ($row.redirect_uris) { $row.redirect_uris -split ',' } else { @() }
                audience     = $row.audience
                entityId     = $row.entity_id
                metadataUrl  = $row.metadata_url
                assignedUsers  = $row.assigned_users
                assignedGroups = $row.assigned_groups
                rawOktaData  = if ($row.raw_json) { $row.raw_json | ConvertFrom-Json } else { $null }
            }
            usernameAttribute = @{
                oktaAttrType      = $row.username_attr_type
                oktaAttrTemplate  = $row.username_attr_template
                oktaAttrResolved  = $row.username_attr_resolved
                oktaAttrSuffix    = $row.username_attr_suffix
                riskFlag          = $row.attr_risk_flag
                entraClaimAttr    = $row.entra_claim_attribute
                entraClaimNotes   = $row.entra_claim_notes
                reviewRequired    = ($row.attr_risk_flag -eq 'HIGH' -and -not $row.entra_claim_attribute)
            }
            usageData = @{
                usageFlag         = $row.usage_flag
                lastGathered      = $row.usage_last_gathered
                periodDays        = $row.period_days
                totalAttempts     = $row.total_attempts
                successfulLogins  = $row.successful_logins
                failedLogins      = $row.failed_logins
                uniqueUsers       = $row.unique_users
                lastLoginAt       = $row.last_login_at
                decommissionCandidate = ($row.usage_flag -eq 'INACTIVE')
                note              = if ($row.usage_flag -eq 'INACTIVE') {
                    "Zero successful logins recorded. Verify whether this app is still needed before migrating."
                } elseif (-not $row.usage_flag) {
                    "Usage not yet gathered. Run Get-OktaAppUsage -OktaAppId $($row.okta_app_id) -Days <n>"
                } else { $null }
            }
            entraApp         = @{
                appId        = $row.entra_app_id
                objectId     = $row.entra_object_id
                status       = $row.status
            }
            migrationContext = @{
                priority     = $row.priority
                owner        = $row.owner_email
                notes        = $row.notes
            }
            swaData = if ($row.sign_on_mode -in @('BOOKMARK','AUTO_LOGIN','SECURE_PASSWORD_STORE','BROWSER_PLUGIN','BASIC_AUTH')) {
                $swaRaw      = $row.raw_json | ConvertFrom-Json -ErrorAction SilentlyContinue
                $swaSettings = if ($swaRaw) { $swaRaw.settings.app } else { $null }
                @{
                    appUrl        = if ($swaSettings) { $swaSettings.url }                              else { $null }
                    loginUrl      = if ($swaSettings) { $swaSettings.loginUrl ?? $swaSettings.url }     else { $null }
                    authUrl       = if ($swaSettings) { $swaSettings.authURL }                          else { $null }
                    usernameField = if ($swaSettings) { $swaSettings.usernameField }                    else { $null }
                    passwordField = if ($swaSettings) { $swaSettings.passwordField }                    else { $null }
                    # All fields needed for a future New-EntraBookmarkApp implementation
                    entraNote     = 'Use loginUrl/appUrl as the Entra My Apps bookmark URL when migrating this app.'
                }
            } else { $null }
            configurationChecklist = if ($row.sign_on_mode -eq 'BOOKMARK') { @(
                @{ step=1; task="Verify bookmark URL (swaData.appUrl) is current and accessible";        done=$false }
                @{ step=2; task="Create Entra My Apps bookmark app using swaData.appUrl";                done=$false }
                @{ step=3; task="Assign users and groups to Entra bookmark app";                         done=$false }
                @{ step=4; task="Verify bookmark appears correctly in user My Apps portal";              done=$false }
                @{ step=5; task="Update migration status to VALIDATED";                                  done=$false }
                @{ step=6; task="Confirm Okta app can be decommissioned, set to COMPLETE";               done=$false }
            )} elseif ($row.sign_on_mode -in @('AUTO_LOGIN','SECURE_PASSWORD_STORE','BROWSER_PLUGIN','BASIC_AUTH')) { @(
                @{ step=1; task="Determine approach: upgrade to federated SSO or migrate as Entra bookmark"; done=$false }
                @{ step=2; task="If SSO upgrade: check vendor support for SAML/OIDC and configure";         done=$false }
                @{ step=3; task="If Entra bookmark: create app using swaData.loginUrl";                     done=$false }
                @{ step=4; task="Configure credential management (Entra SSO for basic auth, or manual)";    done=$false }
                @{ step=5; task="Assign users and groups";                                                  done=$false }
                @{ step=6; task="Test access with a pilot user";                                            done=$false }
                @{ step=7; task="Update migration status to VALIDATED";                                     done=$false }
                @{ step=8; task="Confirm Okta app can be decommissioned, set to COMPLETE";                  done=$false }
            )} else { @(
                @{ step=1; task="Verify app registration display name and identifier URI";                   done=$false }
                @{ step=2; task="Configure SSO: import SAML metadata or set OIDC client ID";                done=$false }
                @{ step=3; task="Configure claim: set NameID / sub to '$($row.entra_claim_attribute ?? "TBD — see usernameAttribute.entraClaimAttr")'"; done=$false }
                @{ step=4; task="Map additional claims / attributes from Okta attribute statements";         done=$false }
                @{ step=5; task="Assign users and groups (automated via Add-EntraAppAssignment)";           done=$false }
                @{ step=6; task="Test SSO login with a pilot user — verify correct attribute sent";         done=$false }
                @{ step=7; task="Update migration status to VALIDATED";                                     done=$false }
                @{ step=8; task="Confirm Okta app can be decommissioned, set to COMPLETE";                  done=$false }
            )}
        }

        $pack | ConvertTo-Json -Depth 15 | Set-Content $filePath -Encoding UTF8
        Write-Success "$($row.label) → $filePath"
        $count++
    }

    Write-Host ""
    Write-Success "Exported $count config pack(s) to: $packDir"
    Write-Host ""
}


#region ── HTML Builder (private helper) ────────────────────────────────────────

function Build-HtmlReport {
    param([array]$Rows, [string]$ProjectName)

    $statusCounts = @{}
    foreach ($s in @('DISCOVERED','READY','STUB_CREATED','IN_PROGRESS','VALIDATED','COMPLETE','IGNORE')) {
        $statusCounts[$s] = ($Rows | Where-Object { $_.MigrationStatus -eq $s }).Count
    }
    $total   = $Rows.Count
    $pct     = if ($total -gt 0) { [math]::Round(($statusCounts['COMPLETE'] + $statusCounts['IGNORE']) / $total * 100, 0) } else { 0 }

    $rowsHtml = ($Rows | ForEach-Object {
        $statusColors = @{
            'DISCOVERED'   = '#6c757d'
            'READY'        = '#0dcaf0'
            'STUB_CREATED' = '#0d6efd'
            'IN_PROGRESS'  = '#fd7e14'
            'VALIDATED'    = '#198754'
            'COMPLETE'     = '#212529'
            'IGNORE'       = '#adb5bd'
        }
        $priColors = @{ 'HIGH'='#dc3545'; 'MEDIUM'='#ffc107'; 'LOW'='#198754' }
        $sc = $statusColors[$_.MigrationStatus] ?? '#6c757d'
        $pc = $priColors[$_.Priority] ?? '#6c757d'
        $entra = if ($_.EntraAppId) { "<span style='font-family:monospace;font-size:11px'>$($_.EntraAppId.Substring(0,[math]::Min(8,$_.EntraAppId.Length)))…</span>" } else { "<span style='color:#aaa'>—</span>" }

        $riskColors = @{ 'HIGH'='#dc3545'; 'MEDIUM'='#ffc107'; 'LOW'='#198754' }
        $rc = $riskColors[$_.AttrRisk] ?? '#aaa'
        $attrDisplay = if ($_.OktaUsernameAttr) { $_.OktaUsernameAttr } else { '<span style="color:#aaa">—</span>' }
        $claimDisplay = if ($_.EntraClaimAttr) {
            "<span style='color:#0d6efd;font-family:monospace;font-size:11px'>$($_.EntraClaimAttr)</span>"
        } else {
            "<span style='color:#ffc107;font-size:11px'>⚠ not set</span>"
        }

        $usageColors = @{ 'ACTIVE'='#198754'; 'LOW_USAGE'='#ffc107'; 'INACTIVE'='#dc3545' }
        $uc = $usageColors[$_.UsageFlag] ?? '#aaa'
        $usageBadge = if ($_.UsageFlag) {
            "<span style='background:$uc;color:#fff;padding:1px 7px;border-radius:10px;font-size:11px'>$($_.UsageFlag)</span>"
        } else { "<span style='color:#aaa;font-size:11px'>—</span>" }
        $loginDisplay = if ($_.SuccessfulLogins -ne $null) {
            "$($_.SuccessfulLogins) / $($_.UniqueUsers) users"
        } else { '<span style="color:#aaa">—</span>' }
        $lastLoginDisplay = if ($_.LastLoginAt) {
            try { ([datetime]$_.LastLoginAt).ToString('yyyy-MM-dd') } catch { $_.LastLoginAt }
        } else { '<span style="color:#aaa">—</span>' }
        $windowLabel = if ($_.UsagePeriodDays) { "($($_.UsagePeriodDays)d)" } else { '' }

        "<tr>
            <td>$($_.AppName)</td>
            <td><span style='font-size:11px;background:#f0f0f0;padding:1px 5px;border-radius:3px'>$($_.Protocol)</span></td>
            <td><span style='background:$sc;color:#fff;padding:2px 8px;border-radius:10px;font-size:11px;white-space:nowrap'>$($_.MigrationStatus)</span></td>
            <td><span style='color:$pc;font-weight:bold;font-size:11px'>$($_.Priority)</span></td>
            <td>$usageBadge <span style='font-size:11px;color:#666'>$windowLabel</span></td>
            <td style='font-size:12px'>$loginDisplay</td>
            <td style='font-size:12px'>$lastLoginDisplay</td>
            <td style='font-size:12px'>$attrDisplay</td>
            <td><span style='background:$rc;color:#fff;padding:1px 7px;border-radius:10px;font-size:11px'>$(if($_.AttrRisk){$_.AttrRisk}else{'—'})</span></td>
            <td style='font-size:12px'>$claimDisplay</td>
            <td>$(if($_.Owner){$_.Owner}else{'<span style="color:#aaa">—</span>'})</td>
            <td>$entra</td>
            <td style='font-size:11px;color:#666'>$(if($_.Notes){$_.Notes}else{''})</td>
        </tr>"
    }) -join "`n"

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OktaToEntra — Migration Report</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f5f7fa;color:#333}
  .header{background:linear-gradient(135deg,#1F4E79,#2E75B6);color:#fff;padding:32px 40px}
  .header h1{font-size:28px;font-weight:700}
  .header p{font-size:14px;opacity:.8;margin-top:4px}
  .container{max-width:1400px;margin:0 auto;padding:24px 40px}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:16px;margin-bottom:24px}
  .card{background:#fff;border-radius:8px;padding:16px;text-align:center;box-shadow:0 1px 4px rgba(0,0,0,.08)}
  .card .num{font-size:32px;font-weight:700;line-height:1}
  .card .lbl{font-size:11px;color:#888;margin-top:4px;text-transform:uppercase;letter-spacing:.05em}
  .progress-bar{background:#e9ecef;border-radius:99px;height:12px;margin-bottom:24px;overflow:hidden}
  .progress-fill{height:100%;background:linear-gradient(90deg,#198754,#20c997);border-radius:99px;transition:width .5s}
  .pct-label{text-align:right;font-size:12px;color:#666;margin-bottom:8px}
  table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.08)}
  th{background:#1F4E79;color:#fff;padding:10px 12px;text-align:left;font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.05em}
  td{padding:9px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;vertical-align:middle}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:#f8f9ff}
  .footer{text-align:center;padding:24px;font-size:12px;color:#aaa}
</style>
</head>
<body>
<div class="header">
  <h1>OktaToEntra Migration Report</h1>
  <p>Project: $ProjectName &nbsp;|&nbsp; Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm UTC") &nbsp;|&nbsp; Total Apps: $total</p>
</div>
<div class="container">
  <div class="cards">
    <div class="card"><div class="num" style="color:#6c757d">$($statusCounts['DISCOVERED'])</div><div class="lbl">Discovered</div></div>
    <div class="card"><div class="num" style="color:#0dcaf0">$($statusCounts['READY'])</div><div class="lbl">Ready</div></div>
    <div class="card"><div class="num" style="color:#0d6efd">$($statusCounts['STUB_CREATED'])</div><div class="lbl">Stub Created</div></div>
    <div class="card"><div class="num" style="color:#fd7e14">$($statusCounts['IN_PROGRESS'])</div><div class="lbl">In Progress</div></div>
    <div class="card"><div class="num" style="color:#198754">$($statusCounts['VALIDATED'])</div><div class="lbl">Validated</div></div>
    <div class="card"><div class="num" style="color:#212529">$($statusCounts['COMPLETE'])</div><div class="lbl">Complete</div></div>
    <div class="card"><div class="num" style="color:#adb5bd">$($statusCounts['IGNORE'])</div><div class="lbl">Ignored</div></div>
  </div>
  <div class="pct-label">$pct% Complete / Ignored</div>
  <div class="progress-bar"><div class="progress-fill" style="width:$pct%"></div></div>
  <table>
    <thead>
      <tr>
        <th>App Name</th><th>Protocol</th><th>Mig Status</th><th>Priority</th>
        <th>Usage</th><th>Logins / Users</th><th>Last Login</th>
        <th>Okta Attribute</th><th>Attr Risk</th><th>Entra Claim</th>
        <th>Owner</th><th>Entra App ID</th><th>Notes</th>
      </tr>
    </thead>
    <tbody>
$rowsHtml
    </tbody>
  </table>
</div>
<div class="footer">OktaToEntra v$((Get-Module OktaToEntra -ErrorAction SilentlyContinue)?.Version?.ToString() ?? '?') — Report generated $(Get-Date -Format "yyyy-MM-dd HH:mm")</div>
</body>
</html>
"@
}

#endregion

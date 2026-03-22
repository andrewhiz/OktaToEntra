# Public/Migration/AttributeMapping.ps1
# Cmdlets for reviewing Okta username attributes and planning Entra claim mappings

function Get-AppUsernameAttributes {
    <#
    .SYNOPSIS
        Reports what username/login attribute each Okta app is using, and flags
        apps whose attribute choice could cause login failures after migration.

    .DESCRIPTION
        In Okta each app has a credentials.userNameTemplate that controls which
        user attribute is sent as the login identifier (NameID for SAML, sub for OIDC).
        This command surfaces those settings alongside a suggested Entra claim mapping
        and a risk flag for review.

        Risk levels:
          HIGH   — Custom expression, SAM Account Name, or unconfigured.
                   These are most likely to differ per-user and require manual review.
          MEDIUM — UPN variant with suffix, or non-standard attribute.
          LOW    — Standard email / Okta Username, likely to align cleanly.

    .PARAMETER RiskFlag
        Filter results by risk: HIGH, MEDIUM, LOW.

    .PARAMETER Protocol
        Filter by sign-on protocol: SAML_2_0, OPENID_CONNECT, etc.

    .PARAMETER NeedsReview
        Show only apps where entra_claim_attribute has NOT been set yet.

    .EXAMPLE
        Get-AppUsernameAttributes
        Get-AppUsernameAttributes -RiskFlag HIGH
        Get-AppUsernameAttributes -NeedsReview
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('HIGH','MEDIUM','LOW')]
        [string]$RiskFlag,
        [string]$Protocol,
        [switch]$NeedsReview
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    $where  = "WHERE mi.project_id=@pid"
    $params = @{ pid=$projectId }

    if ($RiskFlag) {
        $where += " AND mi.attr_risk_flag=@risk"
        $params.risk = $RiskFlag
    }
    if ($Protocol) {
        $where += " AND oa.sign_on_mode=@proto"
        $params.proto = $Protocol
    }
    if ($NeedsReview) {
        $where += " AND (mi.entra_claim_attribute IS NULL OR mi.entra_claim_attribute='')"
    }

    $rows = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    oa.label                  AS AppName,
    oa.sign_on_mode           AS Protocol,
    oa.username_attr_type     AS AttrType,
    oa.username_attr_template AS AttrTemplate,
    oa.username_attr_resolved AS AttrResolved,
    oa.username_attr_suffix   AS AttrSuffix,
    mi.attr_risk_flag         AS RiskFlag,
    mi.entra_claim_attribute  AS EntraClaimAttr,
    mi.entra_claim_notes      AS EntraClaimNotes,
    mi.status                 AS MigStatus,
    oa.okta_app_id            AS OktaAppId,
    mi.id                     AS ItemId
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
$where
ORDER BY
    CASE mi.attr_risk_flag WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    oa.label
"@ -SqlParameters $params

    if (-not $rows -or $rows.Count -eq 0) {
        Write-Warn "No apps match the filter. Run Sync-OktaApps first if you haven't already."
        return
    }

    # ── Summary header ─────────────────────────────────────────────────────────
    Write-Header "Username Attribute Report — $($script:CurrentProject.Name)"

    $high   = ($rows | Where-Object { $_.RiskFlag -eq 'HIGH'   }).Count
    $medium = ($rows | Where-Object { $_.RiskFlag -eq 'MEDIUM' }).Count
    $low    = ($rows | Where-Object { $_.RiskFlag -eq 'LOW'    }).Count
    $mapped = ($rows | Where-Object { $_.EntraClaimAttr        }).Count

    Write-Host "  Total apps : $($rows.Count)" -ForegroundColor White
    Write-Host "  HIGH risk  : " -NoNewline; Write-Host $high   -ForegroundColor Red
    Write-Host "  MEDIUM risk: " -NoNewline; Write-Host $medium -ForegroundColor Yellow
    Write-Host "  LOW risk   : " -NoNewline; Write-Host $low    -ForegroundColor Green
    Write-Host "  Claim mapped: $mapped / $($rows.Count)" -ForegroundColor Cyan
    Write-Host ""

    # ── Detail table ───────────────────────────────────────────────────────────
    foreach ($row in $rows) {

        $riskColor = switch ($row.RiskFlag) {
            'HIGH'   { 'Red'    }
            'MEDIUM' { 'Yellow' }
            default  { 'Green'  }
        }

        Write-Host ("  {0,-38}" -f $row.AppName) -NoNewline
        Write-Host ("[{0,-6}]" -f $row.Protocol.Substring(0,[math]::Min(6,$row.Protocol.Length))) -ForegroundColor DarkGray -NoNewline
        Write-Host ("  [{0,-6}]" -f $row.RiskFlag) -ForegroundColor $riskColor -NoNewline

        if ($row.AttrResolved) {
            Write-Host "  Okta: $($row.AttrResolved)" -ForegroundColor White -NoNewline
        } else {
            Write-Host "  Okta: (not synced)" -ForegroundColor DarkGray -NoNewline
        }

        if ($row.EntraClaimAttr) {
            Write-Host "  →  Entra: $($row.EntraClaimAttr)" -ForegroundColor Cyan
        } else {
            Write-Host "  →  Entra: " -NoNewline
            Write-Host "(not set — run Set-MigrationClaimMapping)" -ForegroundColor DarkYellow
        }

        if ($row.EntraClaimNotes) {
            Write-Host ("  {0,-38}   Notes: {1}" -f '', $row.EntraClaimNotes) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Use Set-MigrationClaimMapping to record the Entra claim for each app." -ForegroundColor DarkGray
    Write-Host "  Use -RiskFlag HIGH to focus on the most critical items first." -ForegroundColor DarkGray
    Write-Host ""

    return $rows
}


function Set-MigrationClaimMapping {
    <#
    .SYNOPSIS
        Records which Entra ID attribute should be used as the login claim for an app.

    .DESCRIPTION
        Does not modify Entra — this is a tracking record that tells the migration
        engineer what to configure in the Entra app's SAML/OIDC claim settings.

        Common Entra claim attributes:
          user.userprincipalname          — UPN (default for most apps)
          user.mail                       — Email address
          user.onpremisessamaccountname   — SAM Account Name (on-prem sync)
          user.onpremisesuserprincipalname — On-prem UPN
          user.employeeid                 — Employee ID
          user.displayname                — Display name

    .PARAMETER OktaAppId
        The Okta App ID to set the mapping for.

    .PARAMETER Label
        App label (partial match). If multiple match, all are updated.

    .PARAMETER EntraClaimAttribute
        The Entra/Graph attribute name to use as the claim value.

    .PARAMETER Notes
        Optional notes explaining why this mapping was chosen, or any caveats.

    .PARAMETER RiskFlag
        Override the auto-detected risk flag: HIGH, MEDIUM, LOW.

    .EXAMPLE
        Set-MigrationClaimMapping -Label "Salesforce" `
            -EntraClaimAttribute "user.onpremisessamaccountname" `
            -Notes "App requires sAMAccountName, not UPN. Verified with vendor."

        Set-MigrationClaimMapping -Label "Workday" `
            -EntraClaimAttribute "user.mail" `
            -Notes "Using mail attribute - all users have unique mail values confirmed."
    #>
    [CmdletBinding()]
    param(
        [string]$OktaAppId,
        [string]$Label,
        [Parameter(Mandatory)]
        [string]$EntraClaimAttribute,
        [string]$Notes,
        [ValidateSet('HIGH','MEDIUM','LOW')]
        [string]$RiskFlag
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    # ── Resolve item(s) ────────────────────────────────────────────────────────
    if ($OktaAppId) {
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id, oa.label, mi.attr_risk_flag FROM migration_items mi
JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND oa.okta_app_id=@oid
"@ -SqlParameters @{ pid=$projectId; oid=$OktaAppId }
    } elseif ($Label) {
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id, oa.label, mi.attr_risk_flag FROM migration_items mi
JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND oa.label LIKE @lbl
"@ -SqlParameters @{ pid=$projectId; lbl="%$Label%" }
    } else {
        throw "Provide -OktaAppId or -Label"
    }

    if (-not $items -or $items.Count -eq 0) {
        Write-Warn "No matching apps found."
        return
    }

    # Warn if setting a low-confidence attribute on a high-risk app
    $suggestedRisk = $RiskFlag
    if (-not $suggestedRisk) {
        $suggestedRisk = switch -Regex ($EntraClaimAttribute) {
            'samaccountname|employeeid|onpremises' { 'HIGH'   }
            'upn|onpremisesupn'                   { 'MEDIUM' }
            default                               { 'LOW'    }
        }
    }

    foreach ($item in @($items)) {
        $setClauses = @(
            "entra_claim_attribute=@attr",
            "attr_risk_flag=@risk",
            "updated_at=@now"
        )
        $params = @{
            attr = $EntraClaimAttribute
            risk = $suggestedRisk
            now  = Get-UtcNow
            id   = $item.id
        }

        if ($Notes) {
            $setClauses += "entra_claim_notes=@notes"
            $params.notes = $Notes
        }

        Invoke-SqliteQuery -DataSource $dbPath -Query @"
UPDATE migration_items SET $($setClauses -join ', ') WHERE id=@id
"@ -SqlParameters $params | Out-Null

        Write-AuditLog -DbPath $dbPath -ProjectId $projectId `
            -EntityType 'migration_item' -EntityId $item.id `
            -Action 'CLAIM_MAPPING_SET' -NewValue $EntraClaimAttribute

        Write-Success "$($item.label)"
        Write-Host "    Okta attr → Entra claim : $EntraClaimAttribute" -ForegroundColor Cyan
        Write-Host "    Risk flag               : $suggestedRisk" -ForegroundColor $(
            switch ($suggestedRisk) { 'HIGH'{'Red'} 'MEDIUM'{'Yellow'} default{'Green'} }
        )
        if ($Notes) {
            Write-Host "    Notes                   : $Notes" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}


function Get-AttributeRiskSummary {
    <#
    .SYNOPSIS
        Prints a concise risk summary table — useful for planning conversations
        and identifying apps that need attribute investigation before cutover.
    #>
    [CmdletBinding()]
    param()

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    $rows = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    oa.username_attr_resolved  AS OktaAttr,
    COUNT(*)                   AS AppCount,
    SUM(CASE WHEN mi.entra_claim_attribute IS NOT NULL AND mi.entra_claim_attribute!='' THEN 1 ELSE 0 END) AS Mapped,
    mi.attr_risk_flag          AS Risk
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
WHERE mi.project_id=@pid
GROUP BY oa.username_attr_resolved, mi.attr_risk_flag
ORDER BY CASE mi.attr_risk_flag WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END, AppCount DESC
"@ -SqlParameters @{ pid=$projectId }

    Write-Header "Attribute Risk Summary — $($script:CurrentProject.Name)"

    $rows | Format-Table -AutoSize @(
        @{ Label='Okta Attribute Used';  Expression={ if ($_.OktaAttr) { $_.OktaAttr } else { '(unknown — re-sync)' } }; Width=42 }
        @{ Label='Apps'; Expression={ $_.AppCount }; Width=6 }
        @{ Label='Mapped'; Expression={ "$($_.Mapped)/$($_.AppCount)" }; Width=9 }
        @{ Label='Risk'; Expression={ $_.Risk }; Width=8 }
    )

    Write-Host "  Run: Get-AppUsernameAttributes -RiskFlag HIGH   to see apps needing attention" -ForegroundColor DarkGray
    Write-Host "  Run: Set-MigrationClaimMapping                  to record Entra claim per app" -ForegroundColor DarkGray
    Write-Host ""
}

# Public/Migration/MigrationPlanner.ps1

$script:ValidStatuses  = @('DISCOVERED','READY','STUB_CREATED','IN_PROGRESS','VALIDATED','COMPLETE','IGNORE')
$script:ValidPriorities = @('HIGH','MEDIUM','LOW')

function Get-MigrationStatus {
    <#
    .SYNOPSIS
        Displays migration status for all apps in the active project.

    .PARAMETER Status
        Filter by a specific status.

    .PARAMETER Owner
        Filter by owner email (partial match).

    .PARAMETER Protocol
        Filter by sign-on protocol: SAML_2_0, OPENID_CONNECT, WS_FED, etc.

    .PARAMETER Priority
        Filter by priority: HIGH, MEDIUM, LOW.

    .PARAMETER ShowDashboard
        Show summary dashboard only (no per-app table).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('DISCOVERED','READY','STUB_CREATED','IN_PROGRESS','VALIDATED','COMPLETE','IGNORE')]
        [string]$Status,
        [string]$Owner,
        [string]$Protocol,
        [ValidateSet('HIGH','MEDIUM','LOW')]
        [string]$Priority,
        [switch]$ShowDashboard
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    # ── Dashboard summary ─────────────────────────────────────────────────────
    $summary = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    mi.status,
    COUNT(*) AS cnt,
    oa.sign_on_mode
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
WHERE mi.project_id = @pid
GROUP BY mi.status
"@ -SqlParameters @{ pid=$projectId }

    $total    = ($summary | Measure-Object -Property cnt -Sum).Sum
    $complete = ($summary | Where-Object { $_.status -eq 'COMPLETE' } | Measure-Object -Property cnt -Sum).Sum
    $ignored  = ($summary | Where-Object { $_.status -eq 'IGNORE'   } | Measure-Object -Property cnt -Sum).Sum
    $pct      = if ($total -gt 0) { [math]::Round(($complete + $ignored) / $total * 100, 0) } else { 0 }

    Write-Header "Migration Status — $($script:CurrentProject.Name)"
    Write-Host "  Total Apps      : " -NoNewline; Write-Host $total -ForegroundColor White
    Write-Host "  Complete/Ignored: " -NoNewline; Write-Host "$($complete + $ignored) ($pct%)" -ForegroundColor Green
    Write-Host ""

    # Status bar
    foreach ($s in $script:ValidStatuses) {
        $count = ($summary | Where-Object { $_.status -eq $s } | Measure-Object -Property cnt -Sum).Sum
        $bar   = "█" * [math]::Min([math]::Round($count / [math]::Max($total,1) * 20), 20)
        Write-Host ("  {0,-14} {1,3}  " -f $s, $count) -NoNewline
        Write-StatusBadge -Status $s
        Write-Host "  $bar" -ForegroundColor DarkGray
    }

    if ($ShowDashboard) { Write-Host ""; return }

    # ── Per-app table ──────────────────────────────────────────────────────────
    $whereClause = "WHERE mi.project_id=@pid"
    $params      = @{ pid=$projectId }

    if ($Status)   { $whereClause += " AND mi.status=@status";   $params.status   = $Status   }
    if ($Owner)    { $whereClause += " AND mi.owner_email LIKE @owner"; $params.owner = "%$Owner%" }
    if ($Protocol) { $whereClause += " AND oa.sign_on_mode=@proto"; $params.proto  = $Protocol }
    if ($Priority) { $whereClause += " AND mi.priority=@pri";    $params.pri      = $Priority }

    $rows = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    oa.label           AS AppName,
    oa.sign_on_mode    AS Protocol,
    mi.status          AS Status,
    mi.priority        AS Priority,
    mi.owner_email     AS Owner,
    mi.entra_app_id    AS EntraAppId,
    oa.assigned_users  AS OktaUsers,
    oa.assigned_groups AS OktaGroups,
    mi.notes           AS Notes,
    mi.id              AS ItemId,
    oa.okta_app_id     AS OktaId
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
$whereClause
ORDER BY
    CASE mi.priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    CASE mi.status WHEN 'DISCOVERED' THEN 1 WHEN 'READY' THEN 2 WHEN 'STUB_CREATED' THEN 3
                   WHEN 'IN_PROGRESS' THEN 4 WHEN 'VALIDATED' THEN 5 WHEN 'COMPLETE' THEN 6
                   WHEN 'IGNORE' THEN 7 ELSE 8 END,
    oa.label
"@ -SqlParameters $params

    Write-Host ""
    if (-not $rows -or $rows.Count -eq 0) {
        Write-Warn "No items match the filter."
        return
    }

    # Add sequential row numbers for display and selection in option 7
    $i = 0
    $numbered = @($rows) | ForEach-Object {
        $i++
        $_ | Add-Member -NotePropertyName 'RowNum' -NotePropertyValue $i -PassThru
    }

    $columns = @(
        @{ Label='#';          Expression={ $_.RowNum };    Width=4  }
        @{ Label='App Name';   Expression={ $_.AppName };   Width=35 }
        @{ Label='Protocol';   Expression={ $_.Protocol };  Width=14 }
        @{ Label='Status';     Expression={ $_.Status };    Width=14 }
        @{ Label='Pri';        Expression={ $_.Priority };  Width=7  }
        @{ Label='Owner';      Expression={ if ($_.Owner) { $_.Owner } else { '—' } }; Width=22 }
        @{ Label='Users';      Expression={ $_.OktaUsers };  Width=6  }
        @{ Label='Groups';     Expression={ $_.OktaGroups }; Width=7  }
        @{ Label='Entra';      Expression={
            if ($_.EntraAppId) { $_.EntraAppId.Substring(0,[math]::Min(8,$_.EntraAppId.Length))+'…' } else { '—' }
        }; Width=10 }
    )

    Invoke-PagedTable -Rows $numbered -Columns $columns -PageSize 20 -CountLabel 'app(s) shown'
}


function Update-MigrationItem {
    <#
    .SYNOPSIS
        Updates the status, owner, priority, or notes on one or more migration items.

    .PARAMETER OktaAppId
        Filter by Okta App ID.

    .PARAMETER Label
        Filter by app label (partial match). All matching items are updated.

    .PARAMETER Status
        New status value.

    .PARAMETER Priority
        New priority value.

    .PARAMETER Owner
        Owner email address.

    .PARAMETER Notes
        Free-text notes (replaces existing notes).

    .PARAMETER AppendNotes
        Append to existing notes rather than replacing.

    .PARAMETER Blockers
        Free-text blockers field.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ItemId,
        [string]$OktaAppId,
        [string]$Label,
        [ValidateSet('DISCOVERED','READY','STUB_CREATED','IN_PROGRESS','VALIDATED','COMPLETE','IGNORE')]
        [string]$Status,
        [ValidateSet('HIGH','MEDIUM','LOW')]
        [string]$Priority,
        [string]$Owner,
        [string]$Notes,
        [switch]$AppendNotes,
        [string]$Blockers,
        [string]$IgnoreReason
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    # ── Resolve items ──────────────────────────────────────────────────────────
    if ($ItemId) {
        # Direct selection by migration_item IDs (from interactive menu option 7)
        $idList = ($ItemId | ForEach-Object { "'$_'" }) -join ','
        $items  = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id, mi.status, mi.notes, oa.label FROM migration_items mi
JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND mi.id IN ($idList)
"@ -SqlParameters @{ pid=$projectId }
    } elseif ($OktaAppId) {
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id, mi.status, mi.notes, oa.label FROM migration_items mi
JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND oa.okta_app_id=@oid
"@ -SqlParameters @{ pid=$projectId; oid=$OktaAppId }
    } elseif ($Label) {
        $items = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id, mi.status, mi.notes, oa.label FROM migration_items mi
JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND oa.label LIKE @lbl
"@ -SqlParameters @{ pid=$projectId; lbl="%$Label%" }
    } else {
        throw "Provide -OktaAppId or -Label to identify the item(s) to update."
    }

    if (-not $items -or $items.Count -eq 0) {
        Write-Warn "No matching migration items found."
        return
    }

    foreach ($item in @($items)) {
        $setClauses = @("updated_at=@now")
        $params     = @{ now=(Get-UtcNow); id=$item.id }
        $changes    = @()

        if ($Status) {
            $setClauses += "status=@status"
            $params.status = $Status
            $changes += "status: $($item.status) → $Status"
        }
        if ($Priority) {
            $setClauses += "priority=@pri"
            $params.pri = $Priority
            $changes += "priority → $Priority"
        }
        if ($Owner) {
            $setClauses += "owner_email=@owner"
            $params.owner = $Owner
            $changes += "owner → $Owner"
        }
        if ($Notes) {
            if ($AppendNotes -and $item.notes) {
                $params.notes = "$($item.notes)`n[$(Get-Date -Format 'yyyy-MM-dd')] $Notes"
            } else {
                $params.notes = $Notes
            }
            $setClauses += "notes=@notes"
            $changes += "notes updated"
        }
        if ($Blockers) {
            $setClauses += "blockers=@blockers"
            $params.blockers = $Blockers
            $changes += "blockers updated"
        }
        if ($IgnoreReason) {
            $setClauses += "ignore_reason=@ignoreReason"
            $params.ignoreReason = $IgnoreReason
            $changes += "ignore_reason updated"
        }

        if ($setClauses.Count -eq 1) {
            Write-Warn "No changes specified for $($item.label)."
            continue
        }

        Invoke-SqliteQuery -DataSource $dbPath -Query @"
UPDATE migration_items SET $($setClauses -join ', ') WHERE id=@id
"@ -SqlParameters $params | Out-Null

        Write-AuditLog -DbPath $dbPath -ProjectId $projectId `
            -EntityType 'migration_item' -EntityId $item.id `
            -Action 'UPDATED' -OldValue $item.status -NewValue ($changes -join '; ')

        Write-Success "$($item.label) — $($changes -join ', ')"
    }
}


function Set-AppGroupMapping {
    <#
    .SYNOPSIS
        Defines an explicit Okta group → Entra group mapping for a specific app.
        Overrides the default 1:1 name-match behaviour for that group.

    .PARAMETER OktaAppId
        The Okta App ID this mapping applies to.

    .PARAMETER OktaGroupId
        The Okta group ID (from Okta admin or Sync-OktaApps output).

    .PARAMETER OktaGroupName
        Display name of the Okta group (for readability).

    .PARAMETER EntraGroupId
        The target Entra / AAD group object ID.

    .PARAMETER EntraGroupName
        Display name of the Entra group (for readability).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OktaAppId,
        [Parameter(Mandatory)][string]$OktaGroupId,
        [Parameter(Mandatory)][string]$OktaGroupName,
        [Parameter(Mandatory)][string]$EntraGroupId,
        [string]$EntraGroupName
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    $item = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id FROM migration_items mi JOIN okta_apps oa ON oa.id=mi.okta_app_id
WHERE mi.project_id=@pid AND oa.okta_app_id=@oid
"@ -SqlParameters @{ pid=$projectId; oid=$OktaAppId }

    if (-not $item) { throw "No migration item found for Okta App ID: $OktaAppId" }

    Invoke-SqliteQuery -DataSource $dbPath -Query @"
INSERT OR REPLACE INTO group_mappings
    (id, project_id, okta_app_id, okta_group_id, okta_group_name, entra_group_id, entra_group_name, created_at)
VALUES (@id, @pid, @aid, @ogid, @ogname, @egid, @egname, @now)
"@ -SqlParameters @{
        id=$( (Invoke-SqliteQuery -DataSource $dbPath -Query "SELECT id FROM group_mappings WHERE project_id=@p AND okta_app_id=@a AND okta_group_id=@g" -SqlParameters @{p=$projectId;a=$item.id;g=$OktaGroupId})?.id ?? (New-Guid) )
        pid=$projectId; aid=$item.id
        ogid=$OktaGroupId; ogname=$OktaGroupName
        egid=$EntraGroupId; egname=$EntraGroupName
        now=(Get-UtcNow)
    } | Out-Null

    Write-Success "Mapping saved: '$OktaGroupName' → '$EntraGroupName' ($EntraGroupId)"
}


function Get-AppGroupMapping {
    <#
    .SYNOPSIS
        Lists all group mappings for an app or the whole project.
    #>
    [CmdletBinding()]
    param([string]$OktaAppId)

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    $query  = "SELECT gm.*, oa.label AS AppLabel FROM group_mappings gm JOIN okta_apps oa ON oa.id=gm.okta_app_id WHERE gm.project_id=@pid"
    $params = @{ pid=$projectId }

    if ($OktaAppId) {
        $query  += " AND oa.okta_app_id=@oid"
        $params.oid = $OktaAppId
    }

    $mappings = Invoke-SqliteQuery -DataSource $dbPath -Query $query -SqlParameters $params

    if (-not $mappings) { Write-Info "No group mappings defined."; return }

    $mappings | Format-Table -AutoSize @(
        @{ Label='App';              Expression={ $_.AppLabel };       Width=30 }
        @{ Label='Okta Group';       Expression={ $_.okta_group_name }; Width=25 }
        @{ Label='Okta Group ID';    Expression={ $_.okta_group_id };  Width=22 }
        @{ Label='Entra Group';      Expression={ $_.entra_group_name }; Width=25 }
        @{ Label='Entra Group ID';   Expression={ $_.entra_group_id }; Width=38 }
    )
}

# Public/Scripts/Start-OktaToEntra.ps1

function Start-OktaToEntra {
    <#
    .SYNOPSIS
        Launches the OktaToEntra interactive console menu.
    #>
    [CmdletBinding()]
    param()

    Clear-Host
    Write-Host @"
  ╔══════════════════════════════════════════════════════════╗
  ║         OktaToEntra  —  Migration Management Tool       ║
  ║                        v1.1                             ║
  ╚══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

    # Load project if none active
    if (-not $script:CurrentProject) {
        $projects = @(Get-OktaToEntraProject 2>$null | Where-Object { $_ -and $_.ProjectId })
        if ($projects.Count -eq 1) {
            Select-OktaToEntraProject -ProjectId $projects[0].ProjectId | Out-Null
        } elseif ($projects.Count -gt 1) {
            Write-Host "  Multiple projects found. Select one:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $projects.Count; $i++) {
                Write-Host "  [$($i+1)] $($projects[$i].Name)  ($($projects[$i].OktaDomain))" -ForegroundColor White
            }
            $sel = Read-Host "  Enter number"
            $idx = [int]$sel - 1
            if ($idx -ge 0 -and $idx -lt $projects.Count) {
                Select-OktaToEntraProject -ProjectId $projects[$idx].ProjectId | Out-Null
            }
        }
    }

    # Status and priority number maps — used in options 5 and 7
    $statusMap = @{
        '1' = 'DISCOVERED'; '2' = 'READY';     '3' = 'STUB_CREATED'
        '4' = 'IN_PROGRESS'; '5' = 'VALIDATED'; '6' = 'COMPLETE'
    }
    $priMap = @{ '1' = 'HIGH'; '2' = 'MEDIUM'; '3' = 'LOW' }

    do {
        $proj = if ($script:CurrentProject) { $script:CurrentProject.Name } else { "(none)" }
        Write-Host ""
        Write-Host "  Active Project: " -NoNewline; Write-Host $proj -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  ── Project ──────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  [1]  New project" -ForegroundColor White
        Write-Host "  [2]  List / switch projects" -ForegroundColor White
        Write-Host "  [S]  Settings — update Okta / Entra credentials" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  ── Okta ─────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  [3]  Test Okta connection" -ForegroundColor White
        Write-Host "  [4]  Sync apps from Okta" -ForegroundColor White
        Write-Host ""
        Write-Host "  ── App Usage ────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  [21] Gather usage data — all apps" -ForegroundColor White
        Write-Host "  [22] Gather usage data — single app" -ForegroundColor White
        Write-Host "  [23] View usage report (all apps)" -ForegroundColor White
        Write-Host "  [24] View INACTIVE apps only" -ForegroundColor Red
        Write-Host "  [25] View usage history for one app" -ForegroundColor White
        Write-Host ""
        Write-Host "  ── Migration Planning ───────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  [5]  View migration status (all apps)" -ForegroundColor White
        Write-Host "  [6]  View dashboard summary" -ForegroundColor White
        Write-Host "  [7]  Update app status / owner / priority" -ForegroundColor White
        Write-Host "  [8]  Manage group mappings" -ForegroundColor White
        Write-Host ""
        Write-Host "  ── Attribute & Claim Mapping ────────────────────────" -ForegroundColor DarkGray
        Write-Host "  [16] View username attribute report (all apps)" -ForegroundColor White
        Write-Host "  [17] View HIGH risk attributes only" -ForegroundColor Red
        Write-Host "  [18] Attribute risk summary (by attribute type)" -ForegroundColor White
        Write-Host "  [19] Set Entra claim mapping for an app" -ForegroundColor White
        Write-Host "  [20] View apps with no claim mapping set yet" -ForegroundColor White
        Write-Host ""
        Write-Host "  ── Entra Actions ────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  [9]  Test Entra / Graph connection" -ForegroundColor White
        Write-Host "  [10] Create Entra stub apps (all READY)" -ForegroundColor White
        Write-Host "  [11] Create Entra stub app (single)" -ForegroundColor White
        Write-Host "  [12] Create Service Principals (all)" -ForegroundColor White
        Write-Host "  [13] Push assignments to Entra (all eligible)" -ForegroundColor White
        Write-Host ""
        Write-Host "  ── Reports ──────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  [14] Export migration report (CSV + HTML)" -ForegroundColor White
        Write-Host "  [15] Export app config packs (JSON per app)" -ForegroundColor White
        Write-Host ""
        Write-Host "  [Q]  Quit" -ForegroundColor DarkGray
        Write-Host ""

        $choice = Read-Host "  Enter choice"

        switch ($choice.Trim().ToUpper()) {

            '1' {
                Write-Host ""
                $name   = Read-Host "  Project name"
                $domain = Read-Host "  Okta domain (e.g. company.okta.com)"
                $token  = Read-Host "  Okta API token" -AsSecureString
                $tid    = Read-Host "  Entra tenant ID (GUID)"
                $cid    = Read-Host "  Entra client ID (GUID)"
                $cs     = Read-Host "  Entra client secret" -AsSecureString
                New-OktaToEntraProject -Name $name -OktaDomain $domain -OktaApiToken $token `
                    -EntraTenantId $tid -EntraClientId $cid -EntraClientSecret $cs
                Invoke-PausePrompt
            }

            '2' {
                Get-OktaToEntraProject
                Invoke-PausePrompt
            }

            'S' { Update-ProjectSettings }

            '3' {
                Test-OktaConnection
                Invoke-PausePrompt
            }

            '4' {
                $inc = Read-Host "  Include inactive apps? [y/N]"
                if ($inc -ieq 'y') { Sync-OktaApps -IncludeInactive }
                else               { Sync-OktaApps }
                Invoke-PausePrompt
            }

            '5' {
                Write-Host ""
                Write-Host "  Filter by status (Enter to show all):" -ForegroundColor DarkGray
                Write-Host "  [1] DISCOVERED  [2] READY  [3] STUB_CREATED" -ForegroundColor DarkGray
                Write-Host "  [4] IN_PROGRESS [5] VALIDATED  [6] COMPLETE" -ForegroundColor DarkGray
                $filterIn     = (Read-Host "  Status number or Enter for all").Trim()
                $filterStatus = if ($filterIn -and $statusMap[$filterIn]) { $statusMap[$filterIn] } else { $null }
                if ($filterStatus) { Get-MigrationStatus -Status $filterStatus }
                else               { Get-MigrationStatus }
                Invoke-PausePrompt
            }

            '6' {
                Get-MigrationStatus -ShowDashboard
                Invoke-PausePrompt
            }

            '7' {
                if (-not $script:CurrentProject) {
                    Write-Warn "No active project."
                    Invoke-PausePrompt; break
                }

                # ── Step 1: Search ────────────────────────────────────────────
                Write-Host ""
                $search = (Read-Host "  App search (partial label, or Enter for all)").Trim()

                $dbPath    = Get-DbPath
                $projectId = $script:CurrentProject.ProjectId

                $whereClause = "WHERE mi.project_id=@pid"
                $sqlParams   = @{ pid = $projectId }
                if ($search) {
                    $whereClause += " AND oa.label LIKE @lbl"
                    $sqlParams.lbl = "%$search%"
                }

                $found = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id              AS ItemId,
       oa.label           AS AppName,
       oa.sign_on_mode    AS Protocol,
       mi.status          AS Status,
       mi.priority        AS Priority,
       mi.owner_email     AS Owner
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
$whereClause
ORDER BY
    CASE mi.priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    CASE mi.status   WHEN 'DISCOVERED' THEN 1 WHEN 'READY' THEN 2
                     WHEN 'STUB_CREATED' THEN 3 WHEN 'IN_PROGRESS' THEN 4
                     WHEN 'VALIDATED' THEN 5 ELSE 6 END,
    oa.label
"@ -SqlParameters $sqlParams

                if (-not $found -or $found.Count -eq 0) {
                    Write-Warn "  No apps found$(if ($search) { " matching '$search'" })."
                    Invoke-PausePrompt; break
                }

                # ── Step 2: Number rows and display paged ─────────────────────
                $n = 0
                $numbered = @($found) | ForEach-Object {
                    $n++
                    $_ | Add-Member -NotePropertyName 'Num' -NotePropertyValue $n -PassThru
                }

                $cols = @(
                    @{ Label='#';        Expression={ $_.Num };      Width=4  }
                    @{ Label='App Name'; Expression={ $_.AppName };  Width=36 }
                    @{ Label='Protocol'; Expression={ $_.Protocol }; Width=14 }
                    @{ Label='Status';   Expression={ $_.Status };   Width=14 }
                    @{ Label='Pri';      Expression={ $_.Priority };  Width=7 }
                    @{ Label='Owner';    Expression={ if ($_.Owner) { $_.Owner } else { '—' } }; Width=22 }
                )
                Invoke-PagedTable -Rows $numbered -Columns $cols -PageSize 20 -CountLabel 'app(s)'

                # ── Step 3: Pick apps ─────────────────────────────────────────
                $sel = (Read-Host "  Enter #IDs to update (e.g. 1,3 or 'all')").Trim()
                if (-not $sel) { break }

                $selectedItems = if ($sel -ieq 'all') {
                    $numbered
                } else {
                    $selNums = $sel -split ',' |
                               ForEach-Object { $_.Trim() } |
                               Where-Object   { $_ -match '^\d+$' } |
                               ForEach-Object { [int]$_ }
                    @($numbered | Where-Object { $_.Num -in $selNums })
                }

                if (-not $selectedItems -or $selectedItems.Count -eq 0) {
                    Write-Warn "  No valid app IDs selected."
                    Invoke-PausePrompt; break
                }

                $selectedIds = @($selectedItems | ForEach-Object { $_.ItemId })
                Write-Host ""
                Write-Host ("  Updating {0} app(s): {1}" -f $selectedItems.Count,
                    ((@($selectedItems) | ForEach-Object { "#$($_.Num) $($_.AppName)" }) -join ', ')) -ForegroundColor Cyan

                # ── Step 4: Status picker ─────────────────────────────────────
                Write-Host ""
                Write-Host "  Status:   [1] DISCOVERED  [2] READY  [3] STUB_CREATED" -ForegroundColor DarkGray
                Write-Host "            [4] IN_PROGRESS [5] VALIDATED  [6] COMPLETE" -ForegroundColor DarkGray
                $statusIn  = (Read-Host "  New status number (Enter to skip)").Trim()
                $newStatus = if ($statusIn -and $statusMap[$statusIn]) { $statusMap[$statusIn] } else { $null }

                # ── Step 5: Priority picker ───────────────────────────────────
                Write-Host "  Priority: [1] HIGH  [2] MEDIUM  [3] LOW" -ForegroundColor DarkGray
                $priIn  = (Read-Host "  New priority number (Enter to skip)").Trim()
                $newPri = if ($priIn -and $priMap[$priIn]) { $priMap[$priIn] } else { $null }

                # ── Step 6: Other fields ──────────────────────────────────────
                $owner    = (Read-Host "  Owner email (Enter to skip)").Trim()
                $notes    = (Read-Host "  Notes (Enter to skip)").Trim()
                $blockers = (Read-Host "  Blockers (Enter to skip)").Trim()

                # ── Apply ─────────────────────────────────────────────────────
                $updateParams = @{ ItemId = $selectedIds }
                if ($newStatus) { $updateParams.Status   = $newStatus }
                if ($newPri)    { $updateParams.Priority = $newPri }
                if ($owner)     { $updateParams.Owner    = $owner }
                if ($notes)     { $updateParams.Notes    = $notes }
                if ($blockers)  { $updateParams.Blockers = $blockers }

                if ($updateParams.Count -le 1) {
                    Write-Warn "  No changes specified."
                } else {
                    Write-Host ""
                    Update-MigrationItem @updateParams
                }
                Invoke-PausePrompt
            }

            '8' {
                $sub = Read-Host "  [L]ist or [A]dd mapping?"
                if ($sub -ieq 'a') {
                    $oid  = Read-Host "  Okta App ID"
                    $ogid = Read-Host "  Okta Group ID"
                    $ogn  = Read-Host "  Okta Group Name"
                    $egid = Read-Host "  Entra Group ID"
                    $egn  = Read-Host "  Entra Group Name"
                    Set-AppGroupMapping -OktaAppId $oid -OktaGroupId $ogid -OktaGroupName $ogn `
                                        -EntraGroupId $egid -EntraGroupName $egn
                } else {
                    Get-AppGroupMapping
                }
                Invoke-PausePrompt
            }

            '9' {
                Test-EntraConnection
                Invoke-PausePrompt
            }

            '10' {
                New-EntraAppStub -All
                Invoke-PausePrompt
            }

            '11' {
                if (-not $script:CurrentProject) {
                    Write-Warn "No active project."
                    Invoke-PausePrompt; break
                }

                # Default: show READY apps. Entering a search term removes the
                # READY filter so the user can stub any app by label if needed.
                Write-Host ""
                Write-Host "  Showing READY apps by default." -ForegroundColor DarkGray
                Write-Host "  Enter a search term to find apps of any status." -ForegroundColor DarkGray
                $search = (Read-Host "  App search (or Enter for all READY)").Trim()

                $dbPath    = Get-DbPath
                $projectId = $script:CurrentProject.ProjectId

                if ($search) {
                    $whereClause = "WHERE mi.project_id=@pid AND oa.label LIKE @lbl"
                    $sqlParams   = @{ pid = $projectId; lbl = "%$search%" }
                } else {
                    $whereClause = "WHERE mi.project_id=@pid AND mi.status='READY'"
                    $sqlParams   = @{ pid = $projectId }
                }

                $found = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT oa.okta_app_id  AS OktaId,
       oa.label        AS AppName,
       oa.sign_on_mode AS Protocol,
       mi.status       AS Status,
       mi.priority     AS Priority
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
$whereClause
ORDER BY
    CASE mi.priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    oa.label
"@ -SqlParameters $sqlParams

                if (-not $found -or $found.Count -eq 0) {
                    $hint = if ($search) { "matching '$search'" } else { "with status READY" }
                    Write-Warn "  No apps found $hint."
                    Invoke-PausePrompt; break
                }

                $n = 0
                $numbered = @($found) | ForEach-Object {
                    $n++
                    $_ | Add-Member -NotePropertyName 'Num' -NotePropertyValue $n -PassThru
                }

                $cols = @(
                    @{ Label='#';        Expression={ $_.Num };      Width=4  }
                    @{ Label='App Name'; Expression={ $_.AppName };  Width=36 }
                    @{ Label='Protocol'; Expression={ $_.Protocol }; Width=14 }
                    @{ Label='Status';   Expression={ $_.Status };   Width=14 }
                    @{ Label='Pri';      Expression={ $_.Priority };  Width=7 }
                )
                Invoke-PagedTable -Rows $numbered -Columns $cols -PageSize 20 -CountLabel 'app(s)'

                $sel = (Read-Host "  Enter # to create stub for").Trim()
                if (-not $sel -or $sel -notmatch '^\d+$') { Invoke-PausePrompt; break }

                $selected = $numbered | Where-Object { $_.Num -eq [int]$sel } | Select-Object -First 1
                if (-not $selected) {
                    Write-Warn "  Invalid selection."
                    Invoke-PausePrompt; break
                }

                Write-Host ""
                Write-Host "  Creating stub for: $($selected.AppName)" -ForegroundColor Cyan
                New-EntraAppStub -OktaAppId $selected.OktaId
                Invoke-PausePrompt
            }

            '12' {
                New-EntraServicePrincipal -All
                Invoke-PausePrompt
            }

            '13' {
                Add-EntraAppAssignment -All
                Invoke-PausePrompt
            }

            '14' {
                $path = Read-Host "  Output folder (Enter for current dir)"
                if (-not $path) { $path = (Get-Location).Path }
                Export-MigrationReport -OutputPath $path -OpenHtml
                Invoke-PausePrompt
            }

            '15' {
                $path = Read-Host "  Output folder (Enter for current dir)"
                if (-not $path) { $path = (Get-Location).Path }
                Export-AppConfigPack -OutputPath $path
                Invoke-PausePrompt
            }

            '16' {
                Get-AppUsernameAttributes
                Invoke-PausePrompt
            }

            '17' {
                Get-AppUsernameAttributes -RiskFlag HIGH
                Invoke-PausePrompt
            }

            '18' {
                Get-AttributeRiskSummary
                Invoke-PausePrompt
            }

            '19' {
                $label = Read-Host "  App label (partial match)"
                Write-Host ""
                Write-Host "  Common Entra claim attributes:" -ForegroundColor DarkGray
                Write-Host "    user.userprincipalname           (UPN — default)" -ForegroundColor DarkGray
                Write-Host "    user.mail                        (Email)" -ForegroundColor DarkGray
                Write-Host "    user.onpremisessamaccountname    (SAM Account Name)" -ForegroundColor DarkGray
                Write-Host "    user.onpremisesuserprincipalname (On-prem UPN)" -ForegroundColor DarkGray
                Write-Host "    user.employeeid                  (Employee ID)" -ForegroundColor DarkGray
                Write-Host ""
                $attr  = Read-Host "  Entra claim attribute"
                $anotes = Read-Host "  Notes (why this mapping, caveats)"
                $aparams = @{ Label=$label; EntraClaimAttribute=$attr }
                if ($anotes) { $aparams.Notes = $anotes }
                Set-MigrationClaimMapping @aparams
                Invoke-PausePrompt
            }

            '20' {
                Get-AppUsernameAttributes -NeedsReview
                Invoke-PausePrompt
            }

            '21' {
                $days = Read-Host "  Lookback window in days (e.g. 30, 60, 90)"
                Get-OktaAppUsage -All -Days ([int]$days)
                Invoke-PausePrompt
            }

            '22' {
                $label = Read-Host "  App label (partial match)"
                $days  = Read-Host "  Lookback window in days"
                Get-OktaAppUsage -Label $label -Days ([int]$days)
                Invoke-PausePrompt
            }

            '23' {
                Show-AppUsageReport
                Invoke-PausePrompt
            }

            '24' {
                Show-AppUsageReport -UsageFlag INACTIVE
                Invoke-PausePrompt
            }

            '25' {
                $label = Read-Host "  App label (partial match)"
                Get-AppUsageHistory -Label $label
                Invoke-PausePrompt
            }

            'Q' { Write-Host "  Goodbye.`n" -ForegroundColor Cyan; return }

            default { Write-Warn "Unknown option: $choice" }
        }

    } while ($true)
}

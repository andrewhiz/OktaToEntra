# Public/Scripts/Start-OktaToEntra.ps1

function Start-OktaToEntra {
    <#
    .SYNOPSIS
        Launches the OktaToEntra interactive console menu.
    #>
    [CmdletBinding()]
    param()

    Clear-Host
    $verTag  = 'v' + ((Get-Module OktaToEntra -ErrorAction SilentlyContinue)?.Version?.ToString() ?? 'dev')
    $padLeft = [int][math]::Floor((58 - $verTag.Length) / 2)
    $verLine = $verTag.PadLeft($padLeft + $verTag.Length).PadRight(58)
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║         OktaToEntra  —  Migration Management Tool       ║" -ForegroundColor Cyan
    Write-Host "  ║$verLine║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

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
        '4' = 'IN_PROGRESS'; '5' = 'VALIDATED'; '6' = 'COMPLETE'; '7' = 'IGNORE'
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
        Write-Host "  [24] Inactive apps — view / mark as IGNORE" -ForegroundColor Red
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
                Write-Host "  [4] IN_PROGRESS [5] VALIDATED  [6] COMPLETE  [7] IGNORE" -ForegroundColor DarkGray
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
                if (-not $script:CurrentProject) { Write-Warn "No active project."; Invoke-PausePrompt; break }

                Write-Host ""
                Write-Host "  How do you want to update?" -ForegroundColor DarkGray
                Write-Host "  [1] Search and bulk-edit" -ForegroundColor White
                Write-Host "  [2] Walk through apps one by one" -ForegroundColor White
                Write-Host "  [B] Back to main menu" -ForegroundColor DarkGray
                $mode7 = (Read-Host "  Mode").Trim().ToUpper()
                if ($mode7 -eq 'B' -or -not $mode7) { break }

                $dbPath    = Get-DbPath
                $projectId = $script:CurrentProject.ProjectId

                if ($mode7 -eq '2') {
                    # ── One-by-one walk mode ──────────────────────────────────
                    $walked = Invoke-AppPicker -DbPath $dbPath -ProjectId $projectId `
                                               -Prompt "Filter apps to walk (partial label)" `
                                               -MultiSelect -IncludeIgnored
                    if (-not $walked) { break }

                    $walkList = @($walked)
                    $walkIdx  = 0
                    foreach ($app in $walkList) {
                        $walkIdx++
                        Write-Host ""
                        Write-Host ("  ── App {0} of {1} ──────────────────────────────────────" -f $walkIdx, $walkList.Count) -ForegroundColor DarkGray
                        Write-Host "  Name    : $($app.AppName)" -ForegroundColor White
                        Write-Host "  Protocol: $($app.Protocol)   Status: " -NoNewline
                        Write-StatusBadge -Status $app.Status
                        Write-Host "   Priority: $($app.Priority)" -ForegroundColor White
                        if ($app.Owner) { Write-Host "  Owner   : $($app.Owner)" -ForegroundColor DarkGray }
                        Write-Host ""

                        Write-Host "  Status:   [1] DISCOVERED  [2] READY  [3] STUB_CREATED" -ForegroundColor DarkGray
                        Write-Host "            [4] IN_PROGRESS [5] VALIDATED  [6] COMPLETE  [7] IGNORE" -ForegroundColor DarkGray
                        $statusIn  = (Read-Host "  New status (Enter to skip)").Trim()
                        $newStatus = if ($statusIn -and $statusMap[$statusIn]) { $statusMap[$statusIn] } else { $null }

                        $newIgnoreReason = $null
                        if ($newStatus -eq 'IGNORE') {
                            $newIgnoreReason = (Read-Host "  Reason for ignoring (Enter to skip)").Trim()
                        }

                        Write-Host "  Priority: [1] HIGH  [2] MEDIUM  [3] LOW" -ForegroundColor DarkGray
                        $priIn  = (Read-Host "  New priority (Enter to skip)").Trim()
                        $newPri = if ($priIn -and $priMap[$priIn]) { $priMap[$priIn] } else { $null }

                        $owner    = (Read-Host "  Owner email (Enter to skip)").Trim()
                        $notes    = (Read-Host "  Notes (Enter to skip)").Trim()
                        $blockers = (Read-Host "  Blockers (Enter to skip)").Trim()

                        $updateParams = @{ ItemId = @($app.ItemId) }
                        if ($newStatus)       { $updateParams.Status       = $newStatus }
                        if ($newPri)          { $updateParams.Priority     = $newPri }
                        if ($owner)           { $updateParams.Owner        = $owner }
                        if ($notes)           { $updateParams.Notes        = $notes }
                        if ($blockers)        { $updateParams.Blockers     = $blockers }
                        if ($newIgnoreReason) { $updateParams.IgnoreReason = $newIgnoreReason }

                        if ($updateParams.Count -gt 1) { Update-MigrationItem @updateParams }
                        else { Write-Host "  (no changes)" -ForegroundColor DarkGray }

                        if ($walkIdx -lt $walkList.Count) {
                            $nav = (Read-Host "  [N] Next  [Q] Stop walk").Trim().ToUpper()
                            if ($nav -eq 'Q') { break }
                        }
                    }
                    Invoke-PausePrompt

                } else {
                    # ── Bulk-edit mode (original behaviour) ───────────────────
                    $selected = Invoke-AppPicker -DbPath $dbPath -ProjectId $projectId `
                                                 -Prompt "App search (partial label)" `
                                                 -MultiSelect -IncludeIgnored
                    if (-not $selected) { break }

                    $selectedIds = @($selected | ForEach-Object { $_.ItemId })
                    Write-Host ""
                    Write-Host ("  Updating {0} app(s): {1}" -f $selected.Count,
                        ((@($selected) | ForEach-Object { $_.AppName }) -join ', ')) -ForegroundColor Cyan

                    Write-Host ""
                    Write-Host "  Status:   [1] DISCOVERED  [2] READY  [3] STUB_CREATED" -ForegroundColor DarkGray
                    Write-Host "            [4] IN_PROGRESS [5] VALIDATED  [6] COMPLETE  [7] IGNORE" -ForegroundColor DarkGray
                    $statusIn  = (Read-Host "  New status number (Enter to skip)").Trim()
                    $newStatus = if ($statusIn -and $statusMap[$statusIn]) { $statusMap[$statusIn] } else { $null }

                    $newIgnoreReason = $null
                    if ($newStatus -eq 'IGNORE') {
                        $newIgnoreReason = (Read-Host "  Reason for ignoring (Enter to skip)").Trim()
                    }

                    Write-Host "  Priority: [1] HIGH  [2] MEDIUM  [3] LOW" -ForegroundColor DarkGray
                    $priIn  = (Read-Host "  New priority number (Enter to skip)").Trim()
                    $newPri = if ($priIn -and $priMap[$priIn]) { $priMap[$priIn] } else { $null }

                    $owner    = (Read-Host "  Owner email (Enter to skip)").Trim()
                    $notes    = (Read-Host "  Notes (Enter to skip)").Trim()
                    $blockers = (Read-Host "  Blockers (Enter to skip)").Trim()

                    $updateParams = @{ ItemId = $selectedIds }
                    if ($newStatus)       { $updateParams.Status       = $newStatus }
                    if ($newPri)          { $updateParams.Priority     = $newPri }
                    if ($owner)           { $updateParams.Owner        = $owner }
                    if ($notes)           { $updateParams.Notes        = $notes }
                    if ($blockers)        { $updateParams.Blockers     = $blockers }
                    if ($newIgnoreReason) { $updateParams.IgnoreReason = $newIgnoreReason }

                    if ($updateParams.Count -le 1) {
                        Write-Warn "  No changes specified."
                    } else {
                        Write-Host ""
                        Update-MigrationItem @updateParams
                    }
                    Invoke-PausePrompt
                }
            }

            '8' {
                if (-not $script:CurrentProject) { Write-Warn "No active project."; Invoke-PausePrompt; break }
                Write-Host "  [L] List mappings   [A] Add mapping   [B] Back" -ForegroundColor DarkGray
                $sub = (Read-Host "  Choice").Trim().ToUpper()
                if ($sub -eq 'B' -or -not $sub) { break }
                if ($sub -eq 'A') {
                    $picked = Invoke-AppPicker -DbPath (Get-DbPath) -ProjectId $script:CurrentProject.ProjectId `
                                               -Prompt "Search for app to map (partial label, or Enter for all)"
                    if (-not $picked) { break }
                    $app  = $picked | Select-Object -First 1
                    Write-Host "  Adding group mapping for: $($app.AppName)" -ForegroundColor Cyan
                    $ogid = Read-Host "  Okta Group ID"
                    $ogn  = Read-Host "  Okta Group Name"
                    $egid = Read-Host "  Entra Group ID"
                    $egn  = Read-Host "  Entra Group Name"
                    Set-AppGroupMapping -OktaAppId $app.OktaId -OktaGroupId $ogid -OktaGroupName $ogn `
                                        -EntraGroupId $egid -EntraGroupName $egn
                } else {
                    Get-AppGroupMapping  # L or anything else
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
                if (-not $script:CurrentProject) { Write-Warn "No active project."; Invoke-PausePrompt; break }

                Write-Host "  Shows READY apps. Use option 7 to change status before stubbing non-READY apps." -ForegroundColor DarkGray
                $picked = Invoke-AppPicker -DbPath (Get-DbPath) -ProjectId $script:CurrentProject.ProjectId `
                                           -Prompt "App search (or Enter for all READY)" `
                                           -FilterStatus @('READY')

                if (-not $picked) { break }

                $selected = $picked | Select-Object -First 1
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
                if (-not $script:CurrentProject) { Write-Warn "No active project."; Invoke-PausePrompt; break }
                $picked = Invoke-AppPicker -DbPath (Get-DbPath) -ProjectId $script:CurrentProject.ProjectId `
                                           -Prompt "Search for app to set claim mapping (partial label, or Enter for all)"
                if (-not $picked) { break }
                $app = $picked | Select-Object -First 1
                Write-Host ""
                Write-Host "  Setting claim mapping for: $($app.AppName)" -ForegroundColor Cyan
                Write-Host "  Common Entra claim attributes:" -ForegroundColor DarkGray
                Write-Host "    user.userprincipalname           (UPN — default)" -ForegroundColor DarkGray
                Write-Host "    user.mail                        (Email)" -ForegroundColor DarkGray
                Write-Host "    user.onpremisessamaccountname    (SAM Account Name)" -ForegroundColor DarkGray
                Write-Host "    user.onpremisesuserprincipalname (On-prem UPN)" -ForegroundColor DarkGray
                Write-Host "    user.employeeid                  (Employee ID)" -ForegroundColor DarkGray
                Write-Host ""
                $attr   = Read-Host "  Entra claim attribute"
                $anotes = Read-Host "  Notes (why this mapping, caveats)"
                $aparams = @{ Label=$app.AppName; EntraClaimAttribute=$attr }
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
                if (-not $script:CurrentProject) { Write-Warn "No active project."; Invoke-PausePrompt; break }
                $picked = Invoke-AppPicker -DbPath (Get-DbPath) -ProjectId $script:CurrentProject.ProjectId `
                                           -Prompt "Search for app to gather usage (partial label, or Enter for all)"
                if (-not $picked) { break }
                $app  = $picked | Select-Object -First 1
                $days = Read-Host "  Lookback window in days (e.g. 30, 60, 90)"
                Get-OktaAppUsage -Label $app.AppName -Days ([int]$days)
                Invoke-PausePrompt
            }

            '23' {
                Show-AppUsageReport
                Invoke-PausePrompt
            }

            '24' {
                if (-not $script:CurrentProject) { Write-Warn "No active project."; Invoke-PausePrompt; break }

                do {
                    Write-Host ""
                    Write-Host "  ── Inactive Apps ────────────────────────────────────" -ForegroundColor DarkGray
                    Write-Host "  [1] View inactive apps list" -ForegroundColor White
                    Write-Host "  [2] Mark inactive apps as IGNORE (one by one)" -ForegroundColor White
                    Write-Host "  [3] Mark ALL inactive apps as IGNORE (bulk)" -ForegroundColor Red
                    Write-Host "  [B] Back" -ForegroundColor DarkGray
                    $sub24 = (Read-Host "  Choice").Trim().ToUpper()

                    switch ($sub24) {
                        '1' {
                            Show-AppUsageReport -UsageFlag INACTIVE
                            Invoke-PausePrompt
                        }

                        '2' {
                            # Walk through inactive apps one by one
                            $dbPath    = Get-DbPath
                            $projectId = $script:CurrentProject.ProjectId

                            $inactive = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id         AS ItemId,
       oa.label      AS AppName,
       oa.sign_on_mode AS Protocol,
       mi.status     AS Status,
       mi.usage_flag AS UsageFlag,
       aus.last_login_at AS LastLogin
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
LEFT JOIN app_usage_stats aus ON aus.id = (
    SELECT id FROM app_usage_stats
    WHERE okta_app_id = oa.id AND project_id = mi.project_id
    ORDER BY gathered_at DESC LIMIT 1
)
WHERE mi.project_id=@pid AND mi.usage_flag='INACTIVE' AND mi.status != 'IGNORE'
ORDER BY oa.label
"@ -SqlParameters @{ pid=$projectId }

                            if (-not $inactive -or $inactive.Count -eq 0) {
                                Write-Warn "No inactive apps (or all already ignored)."
                                Invoke-PausePrompt; break
                            }

                            $idx = 0
                            foreach ($app in @($inactive)) {
                                $idx++
                                Write-Host ""
                                Write-Host ("  ── {0} of {1} ──────────────────────────────────────" -f $idx, $inactive.Count) -ForegroundColor DarkGray
                                Write-Host "  $($app.AppName)" -ForegroundColor White
                                $lastLogin = if ($app.LastLogin) {
                                    try { ([datetime]$app.LastLogin).ToString('yyyy-MM-dd') } catch { $app.LastLogin }
                                } else { 'never' }
                                Write-Host "  Last login: $lastLogin   Protocol: $($app.Protocol)" -ForegroundColor DarkGray
                                $ans = (Read-Host "  Mark as IGNORE? [Y/N/Q]").Trim().ToUpper()
                                if ($ans -eq 'Q') { break }
                                if ($ans -eq 'Y') {
                                    $reason = (Read-Host "  Reason (Enter to skip)").Trim()
                                    $upParams = @{ ItemId=@($app.ItemId); Status='IGNORE' }
                                    if ($reason) { $upParams.IgnoreReason = $reason }
                                    Update-MigrationItem @upParams
                                }
                            }
                            Invoke-PausePrompt
                        }

                        '3' {
                            $dbPath    = Get-DbPath
                            $projectId = $script:CurrentProject.ProjectId

                            $inactiveCount = (Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT COUNT(*) AS cnt FROM migration_items
WHERE project_id=@pid AND usage_flag='INACTIVE' AND status != 'IGNORE'
"@ -SqlParameters @{ pid=$projectId }).cnt

                            if (-not $inactiveCount -or $inactiveCount -eq 0) {
                                Write-Warn "No inactive apps to mark (or all already ignored)."
                                Invoke-PausePrompt; break
                            }

                            Write-Host ""
                            Write-Warn "This will mark $inactiveCount inactive app(s) as IGNORE."
                            $confirm = (Read-Host "  Continue? [y/N]").Trim()
                            if ($confirm -ieq 'y') {
                                $reason = (Read-Host "  Bulk reason (Enter to skip)").Trim()
                                $ids = @(Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT mi.id FROM migration_items mi
WHERE mi.project_id=@pid AND mi.usage_flag='INACTIVE' AND mi.status != 'IGNORE'
"@ -SqlParameters @{ pid=$projectId } | ForEach-Object { $_.id })
                                $upParams = @{ ItemId=$ids; Status='IGNORE' }
                                if ($reason) { $upParams.IgnoreReason = $reason }
                                Update-MigrationItem @upParams
                                Write-Success "Marked $inactiveCount app(s) as IGNORE."
                                Invoke-PausePrompt
                            }
                        }
                    }
                } while ($sub24 -notin @('B','Q'))
            }

            '25' {
                if (-not $script:CurrentProject) { Write-Warn "No active project."; Invoke-PausePrompt; break }
                $picked = Invoke-AppPicker -DbPath (Get-DbPath) -ProjectId $script:CurrentProject.ProjectId `
                                           -Prompt "Search for app to view history (partial label, or Enter for all)"
                if (-not $picked) { break }
                $app = $picked | Select-Object -First 1
                Get-AppUsageHistory -Label $app.AppName
                Invoke-PausePrompt
            }

            'Q' { Write-Host "  Goodbye.`n" -ForegroundColor Cyan; return }

            default { Write-Warn "Unknown option: $choice" }
        }

    } while ($true)
}

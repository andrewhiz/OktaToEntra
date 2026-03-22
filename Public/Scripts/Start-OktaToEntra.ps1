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
  ║                        v1.0                             ║
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
            }
            '2' { Get-OktaToEntraProject }
            'S' { Update-ProjectSettings }
            '3' { Test-OktaConnection }
            '4' {
                $inc = Read-Host "  Include inactive apps? [y/N]"
                if ($inc -ieq 'y') { Sync-OktaApps -IncludeInactive }
                else               { Sync-OktaApps }
            }
            '5' {
                $filter = Read-Host "  Filter by status? (Enter to show all)"
                if ($filter) { Get-MigrationStatus -Status $filter.ToUpper() }
                else          { Get-MigrationStatus }
            }
            '6' { Get-MigrationStatus -ShowDashboard }
            '7' {
                $label  = Read-Host "  App label (partial match)"
                $status = Read-Host "  New status (Enter to skip)"
                $owner  = Read-Host "  Owner email (Enter to skip)"
                $pri    = Read-Host "  Priority HIGH/MEDIUM/LOW (Enter to skip)"
                $notes  = Read-Host "  Notes (Enter to skip)"
                $params = @{ Label=$label }
                if ($status) { $params.Status   = $status.ToUpper() }
                if ($owner)  { $params.Owner    = $owner }
                if ($pri)    { $params.Priority = $pri.ToUpper() }
                if ($notes)  { $params.Notes    = $notes }
                Update-MigrationItem @params
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
                } else { Get-AppGroupMapping }
            }
            '9'  { Test-EntraConnection }
            '10' { New-EntraAppStub -All }
            '11' {
                $oid = Read-Host "  Okta App ID"
                New-EntraAppStub -OktaAppId $oid
            }
            '12' { New-EntraServicePrincipal -All }
            '13' { Add-EntraAppAssignment -All }
            '14' {
                $path = Read-Host "  Output folder (Enter for current dir)"
                if (-not $path) { $path = (Get-Location).Path }
                Export-MigrationReport -OutputPath $path -OpenHtml
            }
            '15' {
                $path = Read-Host "  Output folder (Enter for current dir)"
                if (-not $path) { $path = (Get-Location).Path }
                Export-AppConfigPack -OutputPath $path
            }
            '16' { Get-AppUsernameAttributes }
            '17' { Get-AppUsernameAttributes -RiskFlag HIGH }
            '18' { Get-AttributeRiskSummary }
            '19' {
                $label = Read-Host "  App label (partial match)"
                Write-Host ""
                Write-Host "  Common Entra claim attributes:" -ForegroundColor DarkGray
                Write-Host "    user.userprincipalname          (UPN — default)" -ForegroundColor DarkGray
                Write-Host "    user.mail                       (Email)" -ForegroundColor DarkGray
                Write-Host "    user.onpremisessamaccountname   (SAM Account Name)" -ForegroundColor DarkGray
                Write-Host "    user.onpremisesuserprincipalname (On-prem UPN)" -ForegroundColor DarkGray
                Write-Host "    user.employeeid                 (Employee ID)" -ForegroundColor DarkGray
                Write-Host ""
                $attr  = Read-Host "  Entra claim attribute"
                $notes = Read-Host "  Notes (why this mapping, caveats)"
                $params = @{ Label=$label; EntraClaimAttribute=$attr }
                if ($notes) { $params.Notes = $notes }
                Set-MigrationClaimMapping @params
            }
            '20' { Get-AppUsernameAttributes -NeedsReview }
            '21' {
                $days = Read-Host "  Lookback window in days (e.g. 30, 60, 90)"
                Get-OktaAppUsage -All -Days ([int]$days)
            }
            '22' {
                $label = Read-Host "  App label (partial match)"
                $days  = Read-Host "  Lookback window in days"
                Get-OktaAppUsage -Label $label -Days ([int]$days)
            }
            '23' { Show-AppUsageReport }
            '24' { Show-AppUsageReport -UsageFlag INACTIVE }
            '25' {
                $label = Read-Host "  App label (partial match)"
                Get-AppUsageHistory -Label $label
            }
            'Q' { Write-Host "  Goodbye.`n" -ForegroundColor Cyan; return }
            default { Write-Warn "Unknown option: $choice" }
        }

    } while ($true)
}

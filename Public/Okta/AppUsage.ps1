# Public/Okta/AppUsage.ps1
# On-demand Okta System Log usage gathering per app

# Event types captured — covers SSO, MFA step-up, and session initiations
$script:UsageEventTypes = @(
    'user.authentication.sso'
    'user.authentication.auth_via_mfa'
    'user.session.start'
)

# Usage classification thresholds (applied per 30-day equivalent)
# Scaled proportionally when a different window is used
$script:UsageThresholds = @{
    ActiveMin   = 10   # >= 10 successful logins per 30 days = ACTIVE
    LowUsageMin = 1    # >= 1  successful login  per 30 days = LOW_USAGE
                       # 0 successful logins                 = INACTIVE
}


function Get-OktaAppUsage {
    <#
    .SYNOPSIS
        Pulls authentication log data from Okta for one or more apps and stores
        usage statistics in the local database.

    .DESCRIPTION
        Queries the Okta System Log API for the following event types:
          - user.authentication.sso        (SAML / OIDC app sign-in)
          - user.authentication.auth_via_mfa (MFA step-up during app access)
          - user.session.start             (session initiations tied to an app)

        This is on-demand only — it does not run automatically during Sync-OktaApps.
        Each run creates a new snapshot row in app_usage_stats so you can compare
        usage over time across multiple runs.

        Rate limit note: Okta's /api/v1/logs endpoint is limited to 20 requests/sec
        (Tier 3). For large app counts with long windows the cmdlet paces requests
        automatically and shows a progress bar.

    .PARAMETER Days
        Required. Number of days to look back from now.
        There is no default — you must be explicit about the window.

    .PARAMETER All
        Gather usage for every app in the active project.

    .PARAMETER OktaAppId
        Gather usage for a single app by its Okta App ID.

    .PARAMETER Label
        Gather usage for apps whose label contains this string (partial match).
        Multiple values accepted — they are OR'd together.

    .PARAMETER EventTypes
        Override the default event types to capture. Defaults to all three.

    .PARAMETER Force
        Re-gather even if usage data was already collected today for these apps.

    .EXAMPLE
        # Pull 90-day usage for all apps
        Get-OktaAppUsage -All -Days 90

        # Single app
        Get-OktaAppUsage -OktaAppId "0oa1abc..." -Days 30

        # Specific apps by label
        Get-OktaAppUsage -Label "Salesforce","Workday" -Days 60

        # After gathering, view results
        Show-AppUsageReport
        Show-AppUsageReport -UsageFlag INACTIVE
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 365)]
        [int]$Days,

        [switch]$All,

        [string]$OktaAppId,

        [string[]]$Label,

        [string[]]$EventTypes = $script:UsageEventTypes,

        [switch]$Force
    )

    if (-not $script:CurrentProject) { throw "No active project. Run Select-OktaToEntraProject first." }

    $projectId = $script:CurrentProject.ProjectId
    $dbPath    = $script:DbPath
    $domain    = $script:CurrentProject.OktaDomain
    $token     = Get-ProjectSecret -ProjectId $projectId -SecretType 'OktaApiToken'

    # ── Resolve target apps ───────────────────────────────────────────────────
    $apps = @()

    if ($All) {
        $apps = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT id AS row_id, okta_app_id, label FROM okta_apps
WHERE project_id = @pid ORDER BY label
"@ -SqlParameters @{ pid = $projectId }

    } elseif ($OktaAppId) {
        $apps = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT id AS row_id, okta_app_id, label FROM okta_apps
WHERE project_id = @pid AND okta_app_id = @oid
"@ -SqlParameters @{ pid = $projectId; oid = $OktaAppId }

    } elseif ($Label) {
        $conditions = ($Label | ForEach-Object { "label LIKE '%$__%'" }) -join ' OR '
        $apps = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT id AS row_id, okta_app_id, label FROM okta_apps
WHERE project_id = @pid AND ($conditions)
ORDER BY label
"@ -SqlParameters @{ pid = $projectId }

    } else {
        throw "Specify -All, -OktaAppId, or -Label."
    }

    if (-not $apps -or $apps.Count -eq 0) {
        Write-Warn "No matching apps found in the local database. Run Sync-OktaApps first."
        return
    }

    # ── Skip apps already gathered today unless -Force ────────────────────────
    if (-not $Force) {
        $todayPrefix = (Get-Date -Format 'yyyy-MM-dd')
        $skippable   = @()
        $toProcess   = @()

        foreach ($app in @($apps)) {
            $lastRun = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT gathered_at FROM app_usage_stats
WHERE okta_app_id = @aid AND project_id = @pid AND period_days = @days
ORDER BY gathered_at DESC LIMIT 1
"@ -SqlParameters @{ aid = $app.row_id; pid = $projectId; days = $Days }

            if ($lastRun -and $lastRun.gathered_at -like "$todayPrefix*") {
                $skippable += $app
            } else {
                $toProcess += $app
            }
        }

        if ($skippable.Count -gt 0) {
            Write-Warn "$($skippable.Count) app(s) already gathered today for a $Days-day window — skipping. Use -Force to re-gather."
            Write-Info "Skipped: $(($skippable | Select-Object -ExpandProperty label) -join ', ')"
        }

        $apps = $toProcess
        if ($apps.Count -eq 0) {
            Write-Info "Nothing to gather. All apps already have usage data for today."
            return
        }
    }

    # ── Calculate time window ─────────────────────────────────────────────────
    $periodEnd   = [System.DateTime]::UtcNow
    $periodStart = $periodEnd.AddDays(-$Days)
    $sinceIso    = $periodStart.ToString("yyyy-MM-ddTHH:mm:ss.000Z")
    $untilIso    = $periodEnd.ToString("yyyy-MM-ddTHH:mm:ss.000Z")

    Write-Header "Gathering App Usage — $($script:CurrentProject.Name)"
    Write-Host "  Apps to process : $($apps.Count)" -ForegroundColor White
    Write-Host "  Lookback window : $Days days  ($($periodStart.ToString('yyyy-MM-dd')) → $($periodEnd.ToString('yyyy-MM-dd')))" -ForegroundColor White
    Write-Host "  Event types     : $($EventTypes -join ', ')" -ForegroundColor DarkGray
    Write-Host ""

    $results   = @{ Success=0; Failed=0; NoData=0 }
    $appIndex  = 0

    foreach ($app in @($apps)) {
        $appIndex++
        $pct = [math]::Round($appIndex / $apps.Count * 100)

        Write-Progress `
            -Activity "Gathering Okta usage logs" `
            -Status   "[$appIndex/$($apps.Count)] $($app.label)" `
            -PercentComplete $pct

        Write-Host ("  [{0,3}%] {1}" -f $pct, $app.label) -ForegroundColor Gray -NoNewline

        try {
            $stats = Invoke-OktaUsagePull `
                        -Domain      $domain `
                        -Token       $token `
                        -OktaAppId   $app.okta_app_id `
                        -EventTypes  $EventTypes `
                        -Since       $sinceIso `
                        -Until       $untilIso

            # ── Compute usage flag ────────────────────────────────────────────
            # Scale threshold to the actual window (thresholds defined per 30 days)
            $scaleFactor  = $Days / 30.0
            $activeMin    = [math]::Round($script:UsageThresholds.ActiveMin   * $scaleFactor)
            $lowMin       = [math]::Round($script:UsageThresholds.LowUsageMin * $scaleFactor)

            $usageFlag = if     ($stats.SuccessfulLogins -ge $activeMin) { 'ACTIVE'    }
                         elseif ($stats.SuccessfulLogins -ge $lowMin)    { 'LOW_USAGE' }
                         elseif ($stats.TotalAttempts -eq 0)             { 'INACTIVE'  }
                         else                                            { 'LOW_USAGE' }

            # ── Persist to app_usage_stats ────────────────────────────────────
            $now = Get-UtcNow
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
INSERT INTO app_usage_stats
    (id, project_id, okta_app_id, gathered_at, period_days,
     period_start, period_end,
     total_attempts, successful_logins, failed_logins, unique_users,
     last_login_at, first_login_in_period, event_breakdown, usage_flag)
VALUES
    (@id, @pid, @aid, @now, @days,
     @pstart, @pend,
     @total, @success, @failed, @unique,
     @last, @first, @breakdown, @flag)
"@ -SqlParameters @{
                id        = New-Guid
                pid       = $projectId
                aid       = $app.row_id
                now       = $now
                days      = $Days
                pstart    = $sinceIso
                pend      = $untilIso
                total     = $stats.TotalAttempts
                success   = $stats.SuccessfulLogins
                failed    = $stats.FailedLogins
                unique    = $stats.UniqueUsers
                last      = $stats.LastLoginAt
                first     = $stats.FirstLoginInPeriod
                breakdown = ($stats.EventBreakdown | ConvertTo-Json -Compress)
                flag      = $usageFlag
            } | Out-Null

            # ── Update migration_item with latest flag ────────────────────────
            Invoke-SqliteQuery -DataSource $dbPath -Query @"
UPDATE migration_items
SET usage_flag = @flag, usage_last_gathered = @now, updated_at = @now
WHERE project_id = @pid
  AND okta_app_id = (SELECT id FROM okta_apps WHERE project_id=@pid AND okta_app_id=@oid)
"@ -SqlParameters @{
                flag = $usageFlag; now = $now
                pid  = $projectId; oid = $app.okta_app_id
            } | Out-Null

            # ── Console output ────────────────────────────────────────────────
            $flagColor = switch ($usageFlag) {
                'ACTIVE'    { 'Green'  }
                'LOW_USAGE' { 'Yellow' }
                'INACTIVE'  { 'Red'    }
                default     { 'Gray'   }
            }
            Write-Host "  ✓" -ForegroundColor Green -NoNewline
            Write-Host ("  {0,-8}" -f $usageFlag) -ForegroundColor $flagColor -NoNewline
            Write-Host "  $($stats.SuccessfulLogins) logins  $($stats.UniqueUsers) users  last: $(
                if ($stats.LastLoginAt) { ([datetime]$stats.LastLoginAt).ToString('yyyy-MM-dd') } else { 'never' }
            )" -ForegroundColor White

            $results.Success++

        } catch {
            Write-Host "  ✗  ERROR: $_" -ForegroundColor Red
            $results.Failed++
        }

        # Pace requests — stay well inside Okta's rate limit
        if ($appIndex -lt $apps.Count) { Start-Sleep -Milliseconds 300 }
    }

    Write-Progress -Activity "Gathering Okta usage logs" -Completed

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Done.  Succeeded: " -NoNewline
    Write-Host $results.Success -ForegroundColor Green -NoNewline
    Write-Host "   Failed: " -NoNewline
    Write-Host $results.Failed -ForegroundColor Red
    Write-Host ""
    Write-Info "Run Show-AppUsageReport to view results."
    Write-Info "Run Show-AppUsageReport -UsageFlag INACTIVE to identify decommission candidates."
    Write-Host ""
}


function Invoke-OktaUsagePull {
    <#
    .SYNOPSIS
        Internal: pulls and aggregates System Log events for one app.
    #>
    param(
        [string]   $Domain,
        [string]   $Token,
        [string]   $OktaAppId,
        [string[]] $EventTypes,
        [string]   $Since,
        [string]   $Until
    )

    $totalAttempts    = 0
    $successfulLogins = 0
    $failedLogins     = 0
    $uniqueUserIds    = [System.Collections.Generic.HashSet[string]]::new()
    $lastLoginAt      = $null
    $firstLoginAt     = $null
    $eventBreakdown   = @{}

    foreach ($eventType in $EventTypes) {
        $eventBreakdown[$eventType] = @{ success = 0; failure = 0 }

        # Okta System Log filter: eventType + target app id
        $encodedFilter = [System.Uri]::EscapeDataString(
            "eventType eq `"$eventType`" and target.id eq `"$OktaAppId`""
        )
        $endpoint = "/logs?filter=${encodedFilter}&since=${Since}&until=${Until}&limit=1000&sortOrder=DESCENDING"

        try {
            $events = Invoke-OktaApi -OktaDomain $Domain -ApiToken $Token -Endpoint $endpoint
        } catch {
            # 400 can happen when the app has no log entries at all — treat as zero
            if ($_ -match '400|Bad Request') { continue }
            throw
        }

        if (-not $events) { continue }

        foreach ($evt in @($events)) {
            $totalAttempts++

            $outcome = $evt.outcome.result   # SUCCESS, FAILURE, SKIPPED, etc.
            $userId  = $evt.actor.id

            if ($outcome -eq 'SUCCESS') {
                $successfulLogins++
                $eventBreakdown[$eventType].success++

                # Track last / first successful login timestamps
                $ts = $evt.published
                if ($ts) {
                    if (-not $lastLoginAt  -or $ts -gt $lastLoginAt)  { $lastLoginAt  = $ts }
                    if (-not $firstLoginAt -or $ts -lt $firstLoginAt) { $firstLoginAt = $ts }
                }
            } else {
                $failedLogins++
                $eventBreakdown[$eventType].failure++
            }

            # Track unique users (by actor id)
            if ($userId) { $uniqueUserIds.Add($userId) | Out-Null }
        }
    }

    return [PSCustomObject]@{
        TotalAttempts       = $totalAttempts
        SuccessfulLogins    = $successfulLogins
        FailedLogins        = $failedLogins
        UniqueUsers         = $uniqueUserIds.Count
        LastLoginAt         = $lastLoginAt
        FirstLoginInPeriod  = $firstLoginAt
        EventBreakdown      = $eventBreakdown
    }
}


function Show-AppUsageReport {
    <#
    .SYNOPSIS
        Displays the most recent usage snapshot for each app in the active project.

    .PARAMETER UsageFlag
        Filter by usage classification: ACTIVE, LOW_USAGE, INACTIVE, UNKNOWN.

    .PARAMETER SortBy
        Column to sort by: Label, TotalLogins, UniqueUsers, LastLogin, UsageFlag.
        Default: UsageFlag (INACTIVE first — the ones that need attention).

    .PARAMETER NeverGathered
        Show only apps that have never had usage data collected.

    .EXAMPLE
        Show-AppUsageReport
        Show-AppUsageReport -UsageFlag INACTIVE
        Show-AppUsageReport -UsageFlag INACTIVE | Export-Csv decommission_candidates.csv
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('ACTIVE','LOW_USAGE','INACTIVE','UNKNOWN')]
        [string]$UsageFlag,

        [ValidateSet('Label','TotalLogins','UniqueUsers','LastLogin','UsageFlag')]
        [string]$SortBy = 'UsageFlag',

        [switch]$NeverGathered
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    $whereExtra = ""
    if ($UsageFlag)    { $whereExtra += " AND mi.usage_flag = '$UsageFlag'" }
    if ($NeverGathered){ $whereExtra += " AND (mi.usage_flag IS NULL OR mi.usage_flag = '')" }

    $orderBy = switch ($SortBy) {
        'Label'       { "oa.label" }
        'TotalLogins' { "COALESCE(us.successful_logins,0) DESC" }
        'UniqueUsers' { "COALESCE(us.unique_users,0) DESC" }
        'LastLogin'   { "us.last_login_at DESC" }
        default {
            # INACTIVE first, then LOW_USAGE, then ACTIVE, then unmeasured
            "CASE mi.usage_flag WHEN 'INACTIVE' THEN 1 WHEN 'LOW_USAGE' THEN 2 WHEN 'ACTIVE' THEN 3 ELSE 4 END, oa.label"
        }
    }

    $rows = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    oa.label                AS AppName,
    oa.sign_on_mode         AS Protocol,
    mi.status               AS MigStatus,
    mi.usage_flag           AS UsageFlag,
    mi.usage_last_gathered  AS LastGathered,
    us.period_days          AS PeriodDays,
    us.total_attempts       AS TotalAttempts,
    us.successful_logins    AS SuccessfulLogins,
    us.failed_logins        AS FailedLogins,
    us.unique_users         AS UniqueUsers,
    us.last_login_at        AS LastLoginAt,
    us.first_login_in_period AS FirstLogin,
    oa.okta_app_id          AS OktaAppId,
    mi.id                   AS ItemId
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
-- Latest usage snapshot per app
LEFT JOIN app_usage_stats us ON us.id = (
    SELECT id FROM app_usage_stats
    WHERE okta_app_id = oa.id AND project_id = @pid
    ORDER BY gathered_at DESC LIMIT 1
)
WHERE mi.project_id = @pid $whereExtra
ORDER BY $orderBy
"@ -SqlParameters @{ pid = $projectId }

    if (-not $rows -or $rows.Count -eq 0) {
        Write-Warn "No results. $(if($NeverGathered){'All apps have usage data.'}else{'Try running Get-OktaAppUsage -All -Days <n> first.'})"
        return
    }

    # ── Summary dashboard ──────────────────────────────────────────────────────
    Write-Header "App Usage Report — $($script:CurrentProject.Name)"

    $active   = ($rows | Where-Object { $_.UsageFlag -eq 'ACTIVE'    }).Count
    $low      = ($rows | Where-Object { $_.UsageFlag -eq 'LOW_USAGE' }).Count
    $inactive = ($rows | Where-Object { $_.UsageFlag -eq 'INACTIVE'  }).Count
    $unknown  = ($rows | Where-Object { -not $_.UsageFlag            }).Count

    Write-Host "  ACTIVE    : " -NoNewline; Write-Host $active   -ForegroundColor Green
    Write-Host "  LOW_USAGE : " -NoNewline; Write-Host $low      -ForegroundColor Yellow
    Write-Host "  INACTIVE  : " -NoNewline; Write-Host $inactive -ForegroundColor Red
    Write-Host "  Not yet gathered: " -NoNewline; Write-Host $unknown -ForegroundColor DarkGray
    Write-Host ""

    if ($inactive -gt 0 -and -not $UsageFlag) {
        Write-Host "  ⚠  $inactive app(s) show zero successful logins in the measured window." -ForegroundColor Yellow
        Write-Host "     Consider whether these are decommission candidates vs. genuine low-traffic apps." -ForegroundColor DarkGray
        Write-Host ""
    }

    # ── Per-app table ──────────────────────────────────────────────────────────
    foreach ($row in $rows) {
        $flagColor = switch ($row.UsageFlag) {
            'ACTIVE'    { 'Green'    }
            'LOW_USAGE' { 'Yellow'   }
            'INACTIVE'  { 'Red'      }
            default     { 'DarkGray' }
        }
        $flag    = if ($row.UsageFlag) { $row.UsageFlag } else { '(not gathered)' }
        $lastLog = if ($row.LastLoginAt) {
            try { ([datetime]$row.LastLoginAt).ToString('yyyy-MM-dd') } catch { $row.LastLoginAt }
        } else { 'never' }
        $window  = if ($row.PeriodDays) { "$($row.PeriodDays)d" } else { '—' }
        $gathered = if ($row.LastGathered) {
            try { ([datetime]$row.LastGathered).ToString('yyyy-MM-dd') } catch { '?' }
        } else { '—' }

        Write-Host ("  {0,-38}" -f $row.AppName) -NoNewline
        Write-Host ("{0,-8}" -f $flag) -ForegroundColor $flagColor -NoNewline
        Write-Host ("  {0,6} logins" -f $row.SuccessfulLogins) -NoNewline
        Write-Host ("  {0,4} users" -f $row.UniqueUsers) -NoNewline
        Write-Host ("  {0,5} failed" -f $row.FailedLogins) -NoNewline
        Write-Host ("  window:{0,-4}" -f $window) -ForegroundColor DarkGray -NoNewline
        Write-Host ("  last:{0}" -f $lastLog) -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  $($rows.Count) app(s) shown" -ForegroundColor DarkGray
    Write-Host "  Data gathered column shows date of last pull. Re-run Get-OktaAppUsage -All -Days <n> to refresh." -ForegroundColor DarkGray
    Write-Host ""

    # Return objects so caller can pipe to Export-Csv etc.
    return $rows
}


function Get-AppUsageHistory {
    <#
    .SYNOPSIS
        Shows all historical usage snapshots for a specific app — useful for
        seeing whether usage is trending up, down, or was always zero.

    .PARAMETER OktaAppId
        Okta App ID to look up.

    .PARAMETER Label
        App label (partial match).
    #>
    [CmdletBinding()]
    param(
        [string]$OktaAppId,
        [string]$Label
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    if ($OktaAppId) {
        $app = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT id, label FROM okta_apps WHERE project_id=@pid AND okta_app_id=@oid
"@ -SqlParameters @{ pid=$projectId; oid=$OktaAppId }
    } elseif ($Label) {
        $app = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT id, label FROM okta_apps WHERE project_id=@pid AND label LIKE @lbl LIMIT 1
"@ -SqlParameters @{ pid=$projectId; lbl="%$Label%" }
    } else {
        throw "Provide -OktaAppId or -Label"
    }

    if (-not $app) { Write-Warn "App not found."; return }

    $history = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    gathered_at, period_days, period_start, period_end,
    total_attempts, successful_logins, failed_logins,
    unique_users, last_login_at, usage_flag
FROM app_usage_stats
WHERE okta_app_id = @aid AND project_id = @pid
ORDER BY gathered_at DESC
"@ -SqlParameters @{ aid=$app.id; pid=$projectId }

    if (-not $history) {
        Write-Warn "No usage history for '$($app.label)'. Run Get-OktaAppUsage first."
        return
    }

    Write-Header "Usage History — $($app.label)"

    $history | Format-Table -AutoSize @(
        @{ Label='Gathered';    Expression={ try{([datetime]$_.gathered_at).ToString('yyyy-MM-dd HH:mm')}catch{$_.gathered_at} }; Width=18 }
        @{ Label='Window'; Expression={ "$($_.period_days)d" }; Width=7 }
        @{ Label='Successful';  Expression={ $_.successful_logins }; Width=11 }
        @{ Label='Failed';      Expression={ $_.failed_logins };     Width=7  }
        @{ Label='Total';       Expression={ $_.total_attempts };    Width=7  }
        @{ Label='Uniq Users';  Expression={ $_.unique_users };      Width=11 }
        @{ Label='Last Login';  Expression={ if($_.last_login_at){try{([datetime]$_.last_login_at).ToString('yyyy-MM-dd')}catch{$_.last_login_at}}else{'never'} }; Width=12 }
        @{ Label='Flag';        Expression={ $_.usage_flag };        Width=10 }
    )
}


function Clear-AppUsageData {
    <#
    .SYNOPSIS
        Removes usage snapshots from the database — for a specific app, all apps,
        or snapshots older than a given number of days.

    .PARAMETER OktaAppId
        Clear data for this specific app only.

    .PARAMETER OlderThanDays
        Remove snapshots gathered more than N days ago (keeps recent data).

    .PARAMETER All
        Remove ALL usage snapshots for the active project (requires confirmation).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OktaAppId,
        [int]$OlderThanDays,
        [switch]$All
    )

    $dbPath    = Get-DbPath
    $projectId = $script:CurrentProject.ProjectId

    if ($All) {
        if (-not (Confirm-Action "This will permanently delete ALL usage snapshots for project '$($script:CurrentProject.Name)'.")) {
            Write-Info "Cancelled."; return
        }
        $deleted = Invoke-SqliteQuery -DataSource $dbPath -Query @"
DELETE FROM app_usage_stats WHERE project_id=@pid
"@ -SqlParameters @{ pid=$projectId }
        Write-Success "All usage snapshots deleted."

    } elseif ($OlderThanDays) {
        $cutoff = [System.DateTime]::UtcNow.AddDays(-$OlderThanDays).ToString("o")
        Invoke-SqliteQuery -DataSource $dbPath -Query @"
DELETE FROM app_usage_stats WHERE project_id=@pid AND gathered_at < @cutoff
"@ -SqlParameters @{ pid=$projectId; cutoff=$cutoff } | Out-Null
        Write-Success "Deleted usage snapshots older than $OlderThanDays days."

    } elseif ($OktaAppId) {
        $app = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT id, label FROM okta_apps WHERE project_id=@pid AND okta_app_id=@oid
"@ -SqlParameters @{ pid=$projectId; oid=$OktaAppId }
        if (-not $app) { Write-Warn "App not found."; return }

        Invoke-SqliteQuery -DataSource $dbPath -Query @"
DELETE FROM app_usage_stats WHERE okta_app_id=@aid AND project_id=@pid
"@ -SqlParameters @{ aid=$app.id; pid=$projectId } | Out-Null
        Write-Success "Usage data cleared for: $($app.label)"

    } else {
        throw "Provide -All, -OktaAppId, or -OlderThanDays."
    }
}

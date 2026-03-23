# Private/Helpers.ps1
# Shared utilities: console output, HTTP wrappers, formatting

#region ── Console Output ──────────────────────────────────────────────────────

function Write-Header {
    param([string]$Text)
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor White
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "── $Text ──" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Text)
    Write-Host "  ✓ $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  ⚠ $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "  ✗ $Text" -ForegroundColor Red
}

function Write-Info {
    param([string]$Text)
    Write-Host "  → $Text" -ForegroundColor Cyan
}

function Write-StatusBadge {
    param([string]$Status)
    $colors = @{
        'DISCOVERED'    = 'DarkGray'
        'READY'         = 'Cyan'
        'STUB_CREATED'  = 'Blue'
        'IN_PROGRESS'   = 'Yellow'
        'VALIDATED'     = 'Green'
        'COMPLETE'      = 'White'
        'IGNORE'        = 'DarkGray'
    }
    $c = $colors[$Status]
    if (-not $c) { $c = 'Gray' }
    Write-Host $Status -ForegroundColor $c -NoNewline
}

function Confirm-Action {
    param([string]$Message)
    Write-Host ""
    Write-Host "  $Message" -ForegroundColor Yellow
    $response = Read-Host "  Confirm? [y/N]"
    return ($response -ieq 'y')
}

function Invoke-PausePrompt {
    Write-Host ""
    Write-Host "  Press Enter to return to the menu..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}

function Invoke-PagedTable {
    <#
    .SYNOPSIS
        Displays an array of pre-numbered objects in pages using Format-Table.
        Prompts between pages. Rows must already have a 'Num' property.
    #>
    param(
        [Parameter(Mandatory)][array]  $Rows,
        [Parameter(Mandatory)][array]  $Columns,
        [int]   $PageSize   = 20,
        [string]$CountLabel = 'items'
    )
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $totalPages = [math]::Ceiling($Rows.Count / $PageSize)

    for ($page = 0; $page -lt $totalPages; $page++) {
        $pageRows = $Rows | Select-Object -Skip ($page * $PageSize) -First $PageSize
        $pageRows | Format-Table -AutoSize $Columns | Out-Host

        if ($page -lt $totalPages - 1) {
            Write-Host ("  Page {0}/{1}" -f ($page + 1), $totalPages) -ForegroundColor DarkGray -NoNewline
            $next = Read-Host " — Enter for next page, Q to stop"
            if ($next.Trim() -ieq 'q') { break }
        }
    }

    Write-Host "  $($Rows.Count) $CountLabel" -ForegroundColor DarkGray
    Write-Host ""
}

#endregion

#region ── HTTP Helpers ─────────────────────────────────────────────────────────

function Unprotect-SecureString {
    <#
    .SYNOPSIS
        Converts a SecureString to plaintext transiently — for use only at the
        point of building HTTP headers or request bodies. Do not store the result.
    #>
    param([Parameter(Mandatory)][SecureString]$SecureString)
    return [System.Net.NetworkCredential]::new('', $SecureString).Password
}

function Invoke-OktaApi {
    <#
    .SYNOPSIS
        Calls the Okta REST API with automatic pagination.
    .OUTPUTS
        Array of all result objects (handles link header pagination).
    #>
    param(
        [Parameter(Mandatory)][string]$OktaDomain,
        [Parameter(Mandatory)][SecureString]$ApiToken,
        [Parameter(Mandatory)][string]$Endpoint,
        [string]$Method = 'GET',
        [object]$Body,
        [switch]$NoPaginate
    )

    $baseUrl = "https://${OktaDomain}/api/v1"
    $url     = "${baseUrl}${Endpoint}"
    $headers = @{
        'Authorization' = "SSWS $(Unprotect-SecureString $ApiToken)"
        'Accept'        = 'application/json'
        'Content-Type'  = 'application/json'
    }

    $results = @()

    do {
        $params = @{
            Uri     = $url
            Method  = $Method
            Headers = $headers
        }
        if ($Body -and $Method -ne 'GET') {
            $params.Body = ($Body | ConvertTo-Json -Depth 10)
        }

        # ── Request with 429 retry ────────────────────────────────────────────
        $response = $null
        $attempt  = 0
        do {
            $attempt++
            try {
                $response = Invoke-WebRequest @params -ErrorAction Stop
            } catch {
                $statusCode = $_.Exception.Response.StatusCode.value__

                if ($statusCode -eq 429 -and $attempt -lt 4) {
                    # Respect X-Rate-Limit-Reset (epoch) or Retry-After (seconds)
                    $waitSecs = 60
                    try {
                        $resetVals = $_.Exception.Response.Headers.GetValues('X-Rate-Limit-Reset')
                        if ($resetVals) {
                            $nowEpoch = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                            $waitSecs = [math]::Max(5, [long]($resetVals | Select-Object -First 1) - $nowEpoch + 2)
                        } else {
                            $retryVals = $_.Exception.Response.Headers.GetValues('Retry-After')
                            if ($retryVals) { $waitSecs = [math]::Max(5, [int]($retryVals | Select-Object -First 1)) }
                        }
                    } catch {}
                    Write-Host ""
                    Write-Host "  ⏳ Okta rate limit hit — waiting ${waitSecs}s then retrying (attempt $attempt/3)..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $waitSecs
                } else {
                    $errBody = $_.ErrorDetails.Message
                    throw "Okta API error [$statusCode] on $url : $errBody"
                }
            }
        } while ($null -eq $response -and $attempt -lt 4)

        if ($null -eq $response) {
            throw "Okta API error [429] on $url : Rate limit exceeded after 3 retries."
        }

        $data = $response.Content | ConvertFrom-Json

        if ($data -is [array]) { $results += $data }
        else                   { $results += @($data) }

        # Follow Link header for pagination.
        # In PS7, Headers['Link'] returns string[] not string; join into a scalar
        # before -match so that $Matches is correctly populated.
        $url = $null
        if (-not $NoPaginate) {
            $linkHeader = @($response.Headers['Link']) -join ', '
            if ($linkHeader -match '<([^>]+)>;\s*rel="next"') {
                $url = $Matches[1]
            }
        }

    } while ($url)

    return $results
}

function Invoke-GraphApi {
    <#
    .SYNOPSIS
        Calls Microsoft Graph API with automatic pagination.
    #>
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$Endpoint,
        [string]$Method = 'GET',
        [object]$Body,
        [switch]$NoPaginate
    )

    $baseUrl = "https://graph.microsoft.com/v1.0"
    $url     = if ($Endpoint -like 'https://*') { $Endpoint } else { "${baseUrl}${Endpoint}" }
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
    }

    $results = @()

    do {
        $params = @{
            Uri     = $url
            Method  = $Method
            Headers = $headers
        }
        if ($Body -and $Method -ne 'GET') {
            $params.Body = ($Body | ConvertTo-Json -Depth 10)
        }

        try {
            $response = Invoke-WebRequest @params -ErrorAction Stop
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $errBody    = $_.ErrorDetails.Message
            throw "Graph API error [$statusCode] on $url : $errBody"
        }

        $data = $response.Content | ConvertFrom-Json

        if ($data.value) { $results += $data.value }
        else              { return $data }   # single object response

        $url = $data.'@odata.nextLink'

    } while ($url -and -not $NoPaginate)

    return $results
}

function Get-GraphToken {
    <#
    .SYNOPSIS
        Acquires an access token for Microsoft Graph via client credentials flow.
        ClientSecret is accepted as SecureString and unpacked only for the HTTP call.
    #>
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][SecureString]$ClientSecret
    )

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = Unprotect-SecureString $ClientSecret
        scope         = 'https://graph.microsoft.com/.default'
    }

    try {
        $response = Invoke-RestMethod `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Method POST `
            -Body $body `
            -ErrorAction Stop
        return $response.access_token
    } catch {
        throw "Failed to acquire Graph token: $_"
    }
}

#endregion

#region ── Formatting Helpers ──────────────────────────────────────────────────

function Format-AppTable {
    param([array]$Items)
    $Items | Format-Table -AutoSize @(
        @{ Label='App Name';    Expression={ $_.label };         Width=35 }
        @{ Label='Protocol';   Expression={ $_.sign_on_mode };  Width=10 }
        @{ Label='Status';     Expression={ $_.status };        Width=14 }
        @{ Label='Priority';   Expression={ $_.priority };      Width=8  }
        @{ Label='Owner';      Expression={ $_.owner_email };   Width=25 }
        @{ Label='Entra ID';   Expression={
            if ($_.entra_app_id) { $_.entra_app_id.Substring(0,8) + '...' } else { '—' }
        }; Width=14 }
    )
}

function ConvertTo-StatusSummary {
    param([array]$Items)
    $statuses = @('DISCOVERED','READY','STUB_CREATED','IN_PROGRESS','VALIDATED','COMPLETE','IGNORE')
    $summary  = [ordered]@{}
    foreach ($s in $statuses) {
        $summary[$s] = ($Items | Where-Object { $_.status -eq $s }).Count
    }
    return $summary
}

function Invoke-AppPicker {
    <#
    .SYNOPSIS
        Interactive app search → paged numbered list → selection helper.
        Returns an array of selected row objects.

    .PARAMETER DbPath
        Path to the project SQLite database.

    .PARAMETER ProjectId
        The project ID to scope the query.

    .PARAMETER Prompt
        Text shown to the user before the search input.

    .PARAMETER FilterStatus
        If provided, only show apps with one of these statuses.

    .PARAMETER MultiSelect
        Allow comma-separated numbers or 'all'. Otherwise single selection only.

    .PARAMETER IncludeIgnored
        By default IGNORE-status apps are hidden. Set this switch to include them.
    #>
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$ProjectId,
        [string]  $Prompt        = "App search (partial label, or Enter for all)",
        [string[]]$FilterStatus,
        [switch]  $MultiSelect,
        [switch]  $IncludeIgnored
    )

    Write-Host ""
    $search = (Read-Host "  $Prompt  (Enter for all)").Trim()

    $whereClause = "WHERE mi.project_id=@pid"
    $sqlParams   = @{ pid = $ProjectId }

    if ($FilterStatus -and $FilterStatus.Count -gt 0) {
        $inList = ($FilterStatus | ForEach-Object { "'$_'" }) -join ','
        $whereClause += " AND mi.status IN ($inList)"
    } elseif (-not $IncludeIgnored) {
        $whereClause += " AND mi.status != 'IGNORE'"
    }

    if ($search) {
        $whereClause += " AND oa.label LIKE @lbl"
        $sqlParams.lbl = "%$search%"
    }

    $found = Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT mi.id              AS ItemId,
       oa.okta_app_id     AS OktaId,
       oa.label           AS AppName,
       oa.sign_on_mode    AS Protocol,
       mi.status          AS Status,
       mi.priority        AS Priority,
       mi.usage_flag      AS UsageFlag,
       mi.owner_email     AS Owner
FROM migration_items mi
JOIN okta_apps oa ON oa.id = mi.okta_app_id
$whereClause
ORDER BY
    CASE mi.priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    CASE mi.status WHEN 'DISCOVERED' THEN 1 WHEN 'READY' THEN 2 WHEN 'STUB_CREATED' THEN 3
                   WHEN 'IN_PROGRESS' THEN 4 WHEN 'VALIDATED' THEN 5 WHEN 'COMPLETE' THEN 6
                   WHEN 'IGNORE' THEN 7 ELSE 8 END,
    oa.label
"@ -SqlParameters $sqlParams

    if (-not $found -or $found.Count -eq 0) {
        Write-Warn "No apps found$(if ($search) { " matching '$search'" })."
        return $null
    }

    $n = 0
    $numbered = @($found) | ForEach-Object {
        $n++
        $_ | Add-Member -NotePropertyName 'Num' -NotePropertyValue $n -PassThru
    }

    $cols = @(
        @{ Label='#';        Expression={ $_.Num };       Width=4  }
        @{ Label='App Name'; Expression={ $_.AppName };   Width=36 }
        @{ Label='Protocol'; Expression={ $_.Protocol };  Width=14 }
        @{ Label='Status';   Expression={ $_.Status };    Width=14 }
        @{ Label='Usage';    Expression={ if ($_.UsageFlag) { $_.UsageFlag } else { '—' } }; Width=10 }
        @{ Label='Pri';      Expression={ $_.Priority };  Width=7  }
        @{ Label='Owner';    Expression={ if ($_.Owner) { $_.Owner } else { '—' } }; Width=22 }
    )
    Invoke-PagedTable -Rows $numbered -Columns $cols -PageSize 20 -CountLabel 'app(s)'

    if ($MultiSelect) {
        $sel = (Read-Host "  Enter #(s) to select (e.g. 1,3 or 'all')  [B] Back").Trim()
        if (-not $sel -or $sel -ieq 'b') { return $null }
        $selected = if ($sel -ieq 'all') {
            $numbered
        } else {
            $selNums = $sel -split ',' |
                       ForEach-Object { $_.Trim() } |
                       Where-Object   { $_ -match '^\d+$' } |
                       ForEach-Object { [int]$_ }
            @($numbered | Where-Object { $_.Num -in $selNums })
        }
    } else {
        $sel = (Read-Host "  Enter # to select  [B] Back").Trim()
        if (-not $sel -or $sel -ieq 'b' -or $sel -notmatch '^\d+$') { return $null }
        $selected = @($numbered | Where-Object { $_.Num -eq [int]$sel } | Select-Object -First 1)
    }

    if (-not $selected -or $selected.Count -eq 0) {
        Write-Warn "No valid selection."
        return $null
    }

    return $selected
}

#endregion

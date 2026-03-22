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
        $pageRows | Format-Table -AutoSize $Columns

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

        try {
            $response = Invoke-WebRequest @params -ErrorAction Stop
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $errBody    = $_.ErrorDetails.Message
            throw "Okta API error [$statusCode] on $url : $errBody"
        }

        $data = $response.Content | ConvertFrom-Json

        if ($data -is [array]) { $results += $data }
        else                   { $results += @($data) }

        # Follow Link header for pagination
        $url = $null
        if (-not $NoPaginate) {
            $linkHeader = $response.Headers['Link']
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
    $statuses = @('DISCOVERED','READY','STUB_CREATED','IN_PROGRESS','VALIDATED','COMPLETE')
    $summary  = [ordered]@{}
    foreach ($s in $statuses) {
        $summary[$s] = ($Items | Where-Object { $_.status -eq $s }).Count
    }
    return $summary
}

#endregion

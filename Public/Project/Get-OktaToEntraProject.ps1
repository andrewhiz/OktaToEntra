# Public/Project/Get-OktaToEntraProject.ps1

function Get-OktaToEntraProject {
    <#
    .SYNOPSIS
        Lists all local OktaToEntra projects or gets details on a specific one.

    .PARAMETER ProjectId
        Optional. If supplied, returns only that project's details.
    #>
    [CmdletBinding()]
    param(
        [string]$ProjectId
    )

    $dataRoot = Get-DataRoot
    $projects = @()

    Get-ChildItem -Path $dataRoot -Directory | ForEach-Object {
        $configPath = Join-Path $_.FullName "config.json"
        if (Test-Path $configPath) {
            $cfg = Get-Content $configPath | ConvertFrom-Json
            if (-not $ProjectId -or $cfg.ProjectId -eq $ProjectId) {

                # Add live stats from DB
                $dbPath = Join-Path $_.FullName "project.db"
                if (Test-Path $dbPath) {
                    $stats = Invoke-SqliteQuery -DataSource $dbPath -Query @"
SELECT
    COUNT(*)                                          AS TotalApps,
    SUM(CASE WHEN mi.status='COMPLETE' THEN 1 ELSE 0 END) AS Complete,
    SUM(CASE WHEN mi.status='IN_PROGRESS' THEN 1 ELSE 0 END) AS InProgress,
    SUM(CASE WHEN mi.status='STUB_CREATED' THEN 1 ELSE 0 END) AS StubCreated
FROM migration_items mi
WHERE mi.project_id = @pid
"@ -SqlParameters @{ pid = $cfg.ProjectId }

                    $cfg | Add-Member -NotePropertyName TotalApps  -NotePropertyValue $stats.TotalApps  -Force
                    $cfg | Add-Member -NotePropertyName Complete    -NotePropertyValue $stats.Complete    -Force
                    $cfg | Add-Member -NotePropertyName InProgress  -NotePropertyValue $stats.InProgress  -Force
                    $cfg | Add-Member -NotePropertyName StubCreated -NotePropertyValue $stats.StubCreated -Force
                    $cfg | Add-Member -NotePropertyName IsActive -NotePropertyValue ($script:CurrentProject?.ProjectId -eq $cfg.ProjectId) -Force
                }

                $projects += $cfg
            }
        }
    }

    if ($ProjectId -and $projects.Count -eq 0) {
        Write-Warn "No project found with ID: $ProjectId"
        return $null
    }

    if (-not $ProjectId) {
        Write-Header "OktaToEntra Projects"
        $projects | Format-Table -AutoSize @(
            @{ Label='*';           Expression={ if ($_.IsActive) { '►' } else { ' ' } }; Width=3 }
            @{ Label='Name';        Expression={ $_.Name };        Width=30 }
            @{ Label='Okta Domain'; Expression={ $_.OktaDomain };  Width=28 }
            @{ Label='Total Apps';  Expression={ $_.TotalApps };   Width=10 }
            @{ Label='Complete';    Expression={ $_.Complete };    Width=10 }
            @{ Label='In Progress'; Expression={ $_.InProgress };  Width=11 }
            @{ Label='Project ID';  Expression={ $_.ProjectId };   Width=38 }
        )
        Write-Host "  ► = Active project in this session" -ForegroundColor DarkGray
        Write-Host ""
    }

    return $projects
}


function Select-OktaToEntraProject {
    <#
    .SYNOPSIS
        Sets the active project for this PowerShell session.

    .PARAMETER ProjectId
        The project GUID to activate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectId
    )

    $dataRoot   = Get-DataRoot
    $configPath = Join-Path $dataRoot "$ProjectId\config.json"

    if (-not (Test-Path $configPath)) {
        throw "Project '$ProjectId' not found. Run Get-OktaToEntraProject to list projects."
    }

    $config = Get-Content $configPath | ConvertFrom-Json
    $dbPath = Join-Path $dataRoot "$ProjectId\project.db"

    $script:CurrentProject = $config
    $script:DbPath         = $dbPath

    # Apply any pending schema migrations silently
    Invoke-DatabaseMigration -DbPath $dbPath

    Write-Success "Active project set to: $($config.Name)"
    Write-Info "Okta domain : $($config.OktaDomain)"
    Write-Info "Entra tenant: $($config.EntraTenantId)"
    Write-Host ""

    return $config
}

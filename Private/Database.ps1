# Private/Database.ps1
# SQLite schema management and query helpers using PSSQLite

function Initialize-Database {
    <#
    .SYNOPSIS
        Creates the SQLite database and all tables for a new project.
    #>
    param([string]$DbPath)

    $schema = @"
CREATE TABLE IF NOT EXISTS projects (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    okta_domain TEXT NOT NULL,
    entra_tenant_id TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active'
);

CREATE TABLE IF NOT EXISTS okta_apps (
    id                      TEXT PRIMARY KEY,
    project_id              TEXT NOT NULL,
    okta_app_id             TEXT NOT NULL,
    label                   TEXT NOT NULL,
    sign_on_mode            TEXT NOT NULL,
    okta_status             TEXT NOT NULL,
    login_url               TEXT,
    redirect_uris           TEXT,
    audience                TEXT,
    entity_id               TEXT,
    metadata_url            TEXT,
    assigned_users          INTEGER DEFAULT 0,
    assigned_groups         INTEGER DEFAULT 0,
    -- Username / attribute mapping fields
    username_attr_type      TEXT,    -- e.g. BUILT_IN, CUSTOM
    username_attr_template  TEXT,    -- raw Okta expression e.g. ${source.login}, ${source.email}
    username_attr_resolved  TEXT,    -- human-readable label e.g. "Okta Username", "Email", "Custom: ${source.samAccountName}"
    username_attr_suffix    TEXT,    -- suffix appended by Okta e.g. "@company.com"
    raw_json                TEXT,
    last_synced             TEXT NOT NULL,
    FOREIGN KEY (project_id) REFERENCES projects(id),
    UNIQUE (project_id, okta_app_id)
);

CREATE TABLE IF NOT EXISTS migration_items (
    id                      TEXT PRIMARY KEY,
    project_id              TEXT NOT NULL,
    okta_app_id             TEXT NOT NULL,
    status                  TEXT NOT NULL DEFAULT 'DISCOVERED',
    priority                TEXT NOT NULL DEFAULT 'MEDIUM',
    owner_email             TEXT,
    entra_app_id            TEXT,
    entra_object_id         TEXT,
    entra_sp_id             TEXT,
    notes                   TEXT,
    blockers                TEXT,
    -- Entra claim mapping (filled in by migration engineer)
    entra_claim_attribute   TEXT,    -- e.g. user.userprincipalname, user.mail, user.onpremisessamaccountname
    entra_claim_notes       TEXT,    -- free text: why this mapping, any caveats
    attr_risk_flag          TEXT,    -- NULL | LOW | MEDIUM | HIGH — set automatically by sync, overrideable
    -- Usage tracking (populated by Get-OktaAppUsage)
    usage_flag              TEXT,    -- ACTIVE | LOW_USAGE | INACTIVE | UNKNOWN
    usage_last_gathered     TEXT,    -- when usage was last pulled
    -- Ignore tracking
    ignore_reason           TEXT,    -- free-text reason why this app will not be migrated
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    FOREIGN KEY (project_id) REFERENCES projects(id),
    FOREIGN KEY (okta_app_id) REFERENCES okta_apps(id)
);

CREATE TABLE IF NOT EXISTS group_mappings (
    id              TEXT PRIMARY KEY,
    project_id      TEXT NOT NULL,
    okta_app_id     TEXT NOT NULL,
    okta_group_id   TEXT NOT NULL,
    okta_group_name TEXT NOT NULL,
    entra_group_id  TEXT NOT NULL,
    entra_group_name TEXT,
    created_at      TEXT NOT NULL,
    FOREIGN KEY (project_id) REFERENCES projects(id),
    UNIQUE (project_id, okta_app_id, okta_group_id)
);

CREATE TABLE IF NOT EXISTS assignments (
    id                  TEXT PRIMARY KEY,
    project_id          TEXT NOT NULL,
    migration_item_id   TEXT NOT NULL,
    principal_id        TEXT NOT NULL,
    principal_type      TEXT NOT NULL,
    principal_name      TEXT,
    app_role_id         TEXT DEFAULT '00000000-0000-0000-0000-000000000000',
    assigned_at         TEXT NOT NULL,
    FOREIGN KEY (migration_item_id) REFERENCES migration_items(id)
);

CREATE TABLE IF NOT EXISTS audit_log (
    id              TEXT PRIMARY KEY,
    project_id      TEXT NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       TEXT NOT NULL,
    action          TEXT NOT NULL,
    old_value       TEXT,
    new_value       TEXT,
    performed_by    TEXT,
    performed_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_usage_stats (
    id                   TEXT PRIMARY KEY,
    project_id           TEXT NOT NULL,
    okta_app_id          TEXT NOT NULL,   -- FK to okta_apps.id (row id, not okta app id)
    gathered_at          TEXT NOT NULL,   -- when this pull was run
    period_days          INTEGER NOT NULL, -- lookback window used
    period_start         TEXT NOT NULL,   -- ISO datetime — start of window
    period_end           TEXT NOT NULL,   -- ISO datetime — end of window
    -- Aggregated counts across all captured event types
    total_attempts       INTEGER DEFAULT 0,
    successful_logins    INTEGER DEFAULT 0,
    failed_logins        INTEGER DEFAULT 0,
    unique_users         INTEGER DEFAULT 0,
    -- Key dates
    last_login_at        TEXT,            -- most recent successful login timestamp
    first_login_in_period TEXT,           -- earliest event in the window
    -- Per-event-type breakdown stored as JSON
    -- e.g. {"user.authentication.sso":{"success":42,"failure":3},"user.authentication.auth_via_mfa":{"success":12,"failure":1}}
    event_breakdown      TEXT,
    -- Computed usage classification
    usage_flag           TEXT,            -- ACTIVE | LOW_USAGE | INACTIVE | UNKNOWN
    FOREIGN KEY (project_id) REFERENCES projects(id),
    FOREIGN KEY (okta_app_id) REFERENCES okta_apps(id)
);

CREATE INDEX IF NOT EXISTS idx_okta_apps_project    ON okta_apps(project_id);
CREATE INDEX IF NOT EXISTS idx_migration_project     ON migration_items(project_id);
CREATE INDEX IF NOT EXISTS idx_migration_status      ON migration_items(status);
CREATE INDEX IF NOT EXISTS idx_audit_project         ON audit_log(project_id);
CREATE INDEX IF NOT EXISTS idx_usage_app             ON app_usage_stats(okta_app_id);
CREATE INDEX IF NOT EXISTS idx_usage_project         ON app_usage_stats(project_id);

CREATE TABLE IF NOT EXISTS schema_version (
    version     INTEGER NOT NULL,
    applied_at  TEXT NOT NULL,
    description TEXT
);
"@

    foreach ($stmt in ($schema -split ";\s*\n" | Where-Object { $_.Trim() })) {
        Invoke-SqliteQuery -DataSource $DbPath -Query ($stmt.Trim() + ";") | Out-Null
    }
}

function Get-DbPath {
    <#
    .SYNOPSIS
        Returns the database path for a given project, or the active project if none specified.
    #>
    param([string]$ProjectId)

    $dataRoot = Join-Path $env:APPDATA "OktaToEntra"

    if ($ProjectId) {
        return Join-Path $dataRoot "$ProjectId\project.db"
    }

    if ($script:DbPath -and (Test-Path $script:DbPath)) {
        return $script:DbPath
    }

    throw "No active project. Run Select-OktaToEntraProject or New-OktaToEntraProject first."
}

function Get-DataRoot {
    $path = Join-Path $env:APPDATA "OktaToEntra"
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    return $path
}

function New-Guid { return [System.Guid]::NewGuid().ToString() }

function Get-UtcNow { return [System.DateTime]::UtcNow.ToString("o") }

function Write-AuditLog {
    param(
        [string]$DbPath,
        [string]$ProjectId,
        [string]$EntityType,
        [string]$EntityId,
        [string]$Action,
        [string]$OldValue,
        [string]$NewValue
    )
    $query = @"
INSERT INTO audit_log (id, project_id, entity_type, entity_id, action, old_value, new_value, performed_by, performed_at)
VALUES (@id, @proj, @etype, @eid, @action, @old, @new, @by, @at)
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $query -SqlParameters @{
        id     = New-Guid
        proj   = $ProjectId
        etype  = $EntityType
        eid    = $EntityId
        action = $Action
        old    = $OldValue
        new    = $NewValue
        by     = $env:USERNAME
        at     = Get-UtcNow
    } | Out-Null
}

function Invoke-DatabaseMigration {
    <#
    .SYNOPSIS
        Applies incremental schema changes to an existing database.
        Tracks applied migrations in the schema_version table so each
        migration runs exactly once, regardless of how many times this
        function is called. Safe to run on new or pre-existing databases.
    #>
    param([string]$DbPath)

    function Add-ColumnIfMissing {
        param([string]$Db, [string]$Table, [string]$Column, [string]$Definition)
        $cols = Invoke-SqliteQuery -DataSource $Db -Query "PRAGMA table_info($Table)"
        if (-not ($cols | Where-Object { $_.name -eq $Column })) {
            Invoke-SqliteQuery -DataSource $Db -Query "ALTER TABLE $Table ADD COLUMN $Column $Definition" | Out-Null
            Write-Verbose "  Added column: $Table.$Column"
        }
    }

    # Ensure schema_version table exists (handles DBs created before this feature)
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
CREATE TABLE IF NOT EXISTS schema_version (
    version     INTEGER NOT NULL,
    applied_at  TEXT NOT NULL,
    description TEXT
);
"@ | Out-Null

    $row = Invoke-SqliteQuery -DataSource $DbPath -Query "SELECT MAX(version) AS v FROM schema_version"
    [int]$ver = if ($null -ne $row.v -and $row.v -isnot [System.DBNull]) { [int]$row.v } else { 0 }

    # ── Migration 1: Username attribute tracking + Entra claim mapping ──────────
    if ($ver -lt 1) {
        Add-ColumnIfMissing $DbPath 'okta_apps'       'username_attr_type'     'TEXT'
        Add-ColumnIfMissing $DbPath 'okta_apps'       'username_attr_template' 'TEXT'
        Add-ColumnIfMissing $DbPath 'okta_apps'       'username_attr_resolved' 'TEXT'
        Add-ColumnIfMissing $DbPath 'okta_apps'       'username_attr_suffix'   'TEXT'
        Add-ColumnIfMissing $DbPath 'migration_items' 'entra_claim_attribute'  'TEXT'
        Add-ColumnIfMissing $DbPath 'migration_items' 'entra_claim_notes'      'TEXT'
        Add-ColumnIfMissing $DbPath 'migration_items' 'attr_risk_flag'         'TEXT'
        Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO schema_version (version, applied_at, description)
VALUES (1, @at, 'Username attribute tracking and Entra claim mapping')
"@ -SqlParameters @{ at = (Get-UtcNow) } | Out-Null
        $ver = 1
        Write-Verbose "  DB migration 1 applied"
    }

    # ── Migration 2: Usage tracking columns + app_usage_stats table ─────────────
    if ($ver -lt 2) {
        Add-ColumnIfMissing $DbPath 'migration_items' 'usage_flag'          'TEXT'
        Add-ColumnIfMissing $DbPath 'migration_items' 'usage_last_gathered' 'TEXT'
        Invoke-SqliteQuery -DataSource $DbPath -Query @"
CREATE TABLE IF NOT EXISTS app_usage_stats (
    id                    TEXT PRIMARY KEY,
    project_id            TEXT NOT NULL,
    okta_app_id           TEXT NOT NULL,
    gathered_at           TEXT NOT NULL,
    period_days           INTEGER NOT NULL,
    period_start          TEXT NOT NULL,
    period_end            TEXT NOT NULL,
    total_attempts        INTEGER DEFAULT 0,
    successful_logins     INTEGER DEFAULT 0,
    failed_logins         INTEGER DEFAULT 0,
    unique_users          INTEGER DEFAULT 0,
    last_login_at         TEXT,
    first_login_in_period TEXT,
    event_breakdown       TEXT,
    usage_flag            TEXT
);
"@ | Out-Null
        Invoke-SqliteQuery -DataSource $DbPath -Query "CREATE INDEX IF NOT EXISTS idx_usage_app     ON app_usage_stats(okta_app_id);"  | Out-Null
        Invoke-SqliteQuery -DataSource $DbPath -Query "CREATE INDEX IF NOT EXISTS idx_usage_project ON app_usage_stats(project_id);"   | Out-Null
        Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO schema_version (version, applied_at, description)
VALUES (2, @at, 'Usage tracking columns and app_usage_stats table')
"@ -SqlParameters @{ at = (Get-UtcNow) } | Out-Null
        $ver = 2
        Write-Verbose "  DB migration 2 applied"
    }

    # ── Migration 3: IGNORE status — ignore_reason column ───────────────────────
    if ($ver -lt 3) {
        Add-ColumnIfMissing $DbPath 'migration_items' 'ignore_reason' 'TEXT'
        Invoke-SqliteQuery -DataSource $DbPath -Query @"
INSERT INTO schema_version (version, applied_at, description)
VALUES (3, @at, 'IGNORE status — ignore_reason column on migration_items')
"@ -SqlParameters @{ at = (Get-UtcNow) } | Out-Null
        $ver = 3
        Write-Verbose "  DB migration 3 applied"
    }

    Write-Verbose "Database schema version: $ver"
}

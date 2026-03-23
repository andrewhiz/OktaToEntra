# OktaToEntra — PowerShell Migration Tool

> A PowerShell module for discovering, planning, and tracking application migrations from Okta to Microsoft Entra ID.

| | |
|---|---|
| **Module version** | 2026.3.1 |
| **DB schema version** | 2 |

---

## What This Does

| Capability | Detail |
|---|---|
| **Okta Discovery** | Pulls all apps (SAML, OIDC, SWA, Bookmark, and more) with protocol, SSO config, user/group counts |
| **Usage Tracking** | Pulls 90-day sign-in history per app to identify active vs. unused apps |
| **Entra Stub Creation** | Creates App Registrations in Entra via Graph API |
| **Service Principals** | Creates Enterprise Apps ready for assignment |
| **Assignment Push** | Replicates Okta user/group assignments to Entra (1:1 default, mappable) |
| **Status Tracking** | Per-app lifecycle: DISCOVERED → READY → STUB_CREATED → IN_PROGRESS → VALIDATED → COMPLETE |
| **Reports** | CSV + HTML dashboard, JSON config packs per app |
| **Credential Security** | SecretStore vault — no plaintext secrets ever |

**What it does NOT do:** Configure SAML/OIDC SSO settings. That stays manual — this tool generates config packs to make it easy.

---

## Prerequisites

- **PowerShell 7.2 or later** (required — Windows PowerShell is not supported)
- An **Okta API token** with read permissions:
  - `okta.apps.read`
  - `okta.groups.read`
  - `okta.users.read`
- An **Entra App Registration** for Graph API with:
  - `Application.ReadWrite.All` *(application permission)*
  - `AppRoleAssignment.ReadWrite.All` *(application permission)*
  - `Group.Read.All` *(application permission)*
  - `Organization.Read.All` *(application permission)*
  - Admin consent granted

---

## Installation

```powershell
# 1. Clone or extract the module folder
# 2. Run the setup script (installs dependencies, registers vault)
.\Install-OktaToEntra.ps1

# 3. Import and launch
Import-Module OktaToEntra
Start-OktaToEntra
```

The installer handles:
- PSSQLite (local database)
- Microsoft.PowerShell.SecretManagement + SecretStore (credential vault)
- Module copy to `$env:DOCUMENTS\PowerShell\Modules\`
- Database schema migration for existing projects (non-destructive)

---

## Getting Started

The easiest way to use OktaToEntra is the **interactive menu** — it covers every operation with numbered options and guided prompts:

```powershell
Import-Module OktaToEntra
Start-OktaToEntra
```

If you prefer to script operations directly, all functionality is also available as individual cmdlets (see [Cmdlet Reference](#cmdlet-reference) below).

---

## Quick Start (CLI)

### 1. Create a project
```powershell
# Secrets are prompted with masked input (recommended)
New-OktaToEntraProject `
    -Name          "Contoso Migration Q2 2026" `
    -OktaDomain    "contoso.okta.com" `
    -OktaApiToken  (Read-Host "Okta API Token" -AsSecureString) `
    -EntraTenantId "11111111-2222-3333-4444-555555555555" `
    -EntraClientId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" `
    -EntraClientSecret (Read-Host "Entra Client Secret" -AsSecureString)

# Scripted — load secrets from environment variables (e.g. CI)
$token  = ConvertTo-SecureString $env:OKTA_API_TOKEN     -AsPlainText -Force
$secret = ConvertTo-SecureString $env:ENTRA_CLIENT_SECRET -AsPlainText -Force
New-OktaToEntraProject -Name "Contoso Migration" `
    -OktaDomain "contoso.okta.com" -OktaApiToken $token `
    -EntraTenantId "11111111-..." -EntraClientId "aaaaaaaa-..." -EntraClientSecret $secret
```

### 2. Sync all apps from Okta
```powershell
Sync-OktaApps
# Add -IncludeInactive to also pull inactive apps
```

### 3. Gather usage data
```powershell
# Pull 90-day sign-in history for all apps
Get-OktaAppUsage -All

# View usage summary in the console
Show-AppUsageReport
```

### 4. Review what was found
```powershell
Get-MigrationStatus
Get-MigrationStatus -Status DISCOVERED
Get-MigrationStatus -Protocol SAML_2_0
```

### 5. Mark apps as ready, assign owners, set priorities
```powershell
Update-MigrationItem -Label "Salesforce" -Status READY -Owner "alice@contoso.com" -Priority HIGH
Update-MigrationItem -Label "Slack"      -Status READY -Owner "bob@contoso.com"   -Priority MEDIUM
```

### 6. Create Entra stub app registrations
```powershell
# All READY apps at once
New-EntraAppStub -All

# Or a specific app
New-EntraAppStub -OktaAppId "0oa1bcdef..."
```

### 7. Create Service Principals (needed before assignments)
```powershell
New-EntraServicePrincipal -All
```

### 8. Push assignments from Okta → Entra
```powershell
# Uses 1:1 matching by group display name
Add-EntraAppAssignment -All

# If a group name doesn't match, set up an explicit mapping first:
Set-AppGroupMapping `
    -OktaAppId      "0oa1bcdef..." `
    -OktaGroupId    "00g1abc..." `
    -OktaGroupName  "Salesforce-Users-Okta" `
    -EntraGroupId   "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" `
    -EntraGroupName "Salesforce-Users"
```

### 9. Export reports
```powershell
# CSV + HTML report (opens browser)
Export-MigrationReport -OpenHtml

# JSON config packs for engineers doing the manual SSO config
Export-AppConfigPack

# Single app config pack
Export-AppConfigPack -OktaAppId "0oa1bcdef..."
```

---

## Interactive Menu

```powershell
Start-OktaToEntra
```

Launches a numbered menu covering all operations — no need to remember cmdlet names.

---

## Data Model

```
Project
  └── OktaApp (synced from Okta)
        ├── MigrationItem
        │     ├── status: DISCOVERED → READY → STUB_CREATED → IN_PROGRESS → VALIDATED → COMPLETE
        │     ├── owner_email
        │     ├── priority: HIGH | MEDIUM | LOW
        │     ├── entra_app_id (populated after New-EntraAppStub)
        │     ├── entra_sp_id  (populated after New-EntraServicePrincipal)
        │     ├── notes / blockers
        │     └── Assignments (users and groups pushed to Entra)
        └── AppUsageStats (90-day sign-in counts per app)

GroupMappings (per project, per app: Okta group ID → Entra group ID)
AuditLog      (immutable record of all changes)
```

All data lives in `%APPDATA%\OktaToEntra\<project-guid>\project.db` (SQLite).
Secrets are stored in the SecretStore vault, never in the database or config file.

---

## Cmdlet Reference

| Cmdlet | What it does |
|---|---|
| `New-OktaToEntraProject` | Create project, store credentials securely, test connections |
| `Get-OktaToEntraProject` | List all local projects with stats |
| `Select-OktaToEntraProject` | Set the active project for this session |
| `Update-ProjectSettings` | Update project name, Okta domain, or credentials |
| `Test-OktaConnection` | Validate Okta API token |
| `Sync-OktaApps` | Pull all apps from Okta, upsert to local DB |
| `Get-OktaAppDetail` | Get raw Okta app data by label or ID |
| `Get-OktaAppUsage` | Pull 90-day sign-in history from Okta logs |
| `Show-AppUsageReport` | Display usage summary table in the console |
| `Get-AppUsageHistory` | View historical usage pulls for a specific app |
| `Clear-AppUsageData` | Remove usage data for one or all apps |
| `Test-EntraConnection` | Validate Graph API credentials |
| `New-EntraAppStub` | Create Entra App Registrations |
| `New-EntraServicePrincipal` | Create Enterprise Apps for assignment |
| `Add-EntraAppAssignment` | Push user/group assignments to Entra |
| `Get-MigrationStatus` | View per-app status table + dashboard |
| `Update-MigrationItem` | Update status, owner, priority, notes |
| `Get-AppUsernameAttributes` | Show Okta username attribute config per app |
| `Set-MigrationClaimMapping` | Record the Entra claim mapping for an app |
| `Get-AttributeRiskSummary` | Summarise attribute risk flags across all apps |
| `Set-AppGroupMapping` | Map an Okta group to a specific Entra group |
| `Get-AppGroupMapping` | List all group mappings for an app |
| `Export-MigrationReport` | Generate CSV + HTML report |
| `Export-AppConfigPack` | Export per-app JSON config for engineers |
| `Start-OktaToEntra` | Interactive console menu |

---

## Credential Security

Credentials are **always encrypted** — they are never stored in plaintext anywhere on disk.

When you provide an Okta API token or Entra client secret, the module immediately stores it in the **Microsoft.PowerShell.SecretStore** vault (encrypted by Windows). The SQLite database, config files, and logs never contain secrets.

The `New-OktaToEntraProject` cmdlet accepts credentials as `[SecureString]`. Use `Read-Host -AsSecureString` for interactive sessions or `ConvertTo-SecureString` when loading from environment variables in scripted/CI scenarios.

---

## Setting Up the Entra App Registration

1. Go to **Azure Portal → Entra ID → App registrations → New registration**
2. Name it `OktaToEntra-MigrationTool`
3. Select **Accounts in this organizational directory only**
4. Go to **API permissions → Add permission → Microsoft Graph → Application permissions**
5. Add:
   - `Application.ReadWrite.All`
   - `AppRoleAssignment.ReadWrite.All`
   - `Group.Read.All`
   - `Organization.Read.All`
6. Click **Grant admin consent**
7. Go to **Certificates & secrets → New client secret**
8. Copy the **Tenant ID**, **Application (client) ID**, and the secret value for use in `New-OktaToEntraProject`

---

## File Structure

```
OktaToEntra/
├── OktaToEntra.psd1                 # Module manifest (single source of truth for version)
├── OktaToEntra.psm1                 # Module loader
├── Install-OktaToEntra.ps1          # One-time setup + schema migration
├── Update-ModuleVersion.ps1         # Developer helper: bump version in psd1
├── README.md
├── BACKLOG.md                       # Ideas and future improvements
├── Private/
│   ├── Database.ps1                 # SQLite schema, migrations, query helpers
│   ├── Vault.ps1                    # SecretStore credential management
│   └── Helpers.ps1                  # HTTP wrappers, console output, pagination
└── Public/
    ├── Project/
    │   ├── New-OktaToEntraProject.ps1
    │   ├── Get-OktaToEntraProject.ps1
    │   └── Update-ProjectSettings.ps1
    ├── Okta/
    │   ├── OktaConnector.ps1        # Sync-OktaApps, Get-OktaAppDetail
    │   └── AppUsage.ps1             # Get-OktaAppUsage, Show-AppUsageReport, etc.
    ├── Entra/
    │   └── EntraConnector.ps1
    ├── Migration/
    │   ├── MigrationPlanner.ps1     # Status, assignments, group mappings
    │   └── AttributeMapping.ps1     # Username attributes, claim mapping, risk flags
    ├── Reports/
    │   └── Reports.ps1              # CSV, HTML, config packs
    └── Scripts/
        └── Start-OktaToEntra.ps1   # Interactive menu
```

---

## Troubleshooting

**"No active project" error**
```powershell
Get-OktaToEntraProject          # list projects
Select-OktaToEntraProject -ProjectId "<guid>"
```

**Okta API 401 Unauthorized**
- Check the API token hasn't expired
- Ensure the token has `okta.apps.read` scope
- Verify the domain format: `yourorg.okta.com` (no `https://`)

**Okta API 429 Too Many Requests**
- Occurs when pulling usage data for large numbers of apps
- The module automatically retries with the wait time from the `X-Rate-Limit-Reset` header
- For very large tenants, consider pulling usage in smaller batches using `-OktaAppId`

**Graph API 403 Forbidden**
- Ensure admin consent was granted for all four permissions
- Verify the client secret hasn't expired
- Check the tenant ID matches the app registration

**Group assignments skipped ("not found in Entra")**
- Group names must match exactly (Okta display name = Entra display name)
- Use `Set-AppGroupMapping` for groups with different names

---

## Future Plans

A browser-based web application version is planned as a separate project.

See `BACKLOG.md` for ideas and planned improvements.

---

## License

MIT License — see [LICENSE](LICENSE) for full terms.

---

## Disclaimer

**No warranty.** This solution/script is provided "as is", without warranty of any kind. The authors make no guarantees about correctness, completeness, or fitness for any particular purpose. Use it at your own risk.

**Not affiliated with Okta or Microsoft.** OktaToEntra is an independent open-source project. It is not endorsed by, affiliated with, or supported by Okta, Inc. or Microsoft Corporation. Okta and Microsoft Entra ID are trademarks of their respective owners.

**You are responsible for changes made to your tenants.** This tool creates app registrations, service principals, and assignments in your Microsoft Entra tenant, and reads data from your Okta organization. All changes are made under the credentials and permissions you provide. Review what the tool will do before running any operation in a production environment. The authors accept no liability for unintended changes, data loss, access disruptions, or security incidents resulting from use of this software.
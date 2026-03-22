# OktaToEntra — Phase 1: PowerShell Migration Tool

> A PowerShell module for discovering, planning, and tracking application migrations from Okta to Microsoft Entra ID.

---

## What This Does

| Capability | Detail |
|---|---|
| **Okta Discovery** | Pulls all apps with protocol, SSO config, user/group counts |
| **Entra Stub Creation** | Creates App Registrations in Entra via Graph API |
| **Service Principals** | Creates Enterprise Apps ready for assignment |
| **Assignment Push** | Replicates Okta user/group assignments to Entra (1:1 default, mappable) |
| **Status Tracking** | Per-app lifecycle: DISCOVERED → READY → STUB_CREATED → IN_PROGRESS → VALIDATED → COMPLETE |
| **Reports** | CSV + HTML dashboard, JSON config packs per app |
| **Credential Security** | SecretStore vault (DPAPI fallback) — no plaintext secrets ever |

**What it does NOT do:** Configure SAML/OIDC SSO settings. That stays manual — this tool generates config packs to make it easy.

---

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- An **Okta API token** with read permissions:
  - `okta.apps.read`
  - `okta.groups.read`
  - `okta.users.read`
- An **Entra App Registration** for Graph API with:
  - `Application.ReadWrite.All` *(application permission)*
  - `AppRoleAssignment.ReadWrite.All` *(application permission)*
  - `Group.Read.All` *(application permission)*
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

---

## Quick Start (CLI)

### 1. Create a project
```powershell
New-OktaToEntraProject `
    -Name          "Contoso Migration Q2 2026" `
    -OktaDomain    "contoso.okta.com" `
    -OktaApiToken  "00abc123..." `
    -EntraTenantId "11111111-2222-3333-4444-555555555555" `
    -EntraClientId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" `
    -EntraClientSecret "your-client-secret-here"
```

### 2. Sync all apps from Okta
```powershell
Sync-OktaApps
# Add -IncludeInactive to also pull inactive apps
```

### 3. Review what was found
```powershell
Get-MigrationStatus
Get-MigrationStatus -Status DISCOVERED
Get-MigrationStatus -Protocol SAML_2_0
```

### 4. Mark apps as ready, assign owners, set priorities
```powershell
Update-MigrationItem -Label "Salesforce" -Status READY -Owner "alice@contoso.com" -Priority HIGH
Update-MigrationItem -Label "Slack"      -Status READY -Owner "bob@contoso.com"   -Priority MEDIUM

# Bulk: mark all DISCOVERED as READY (careful!)
# Use Get-MigrationStatus -Status DISCOVERED to review first
```

### 5. Create Entra stub app registrations
```powershell
# All READY apps at once
New-EntraAppStub -All

# Or a specific app
New-EntraAppStub -OktaAppId "0oa1bcdef..."
```

### 6. Create Service Principals (needed before assignments)
```powershell
New-EntraServicePrincipal -All
```

### 7. Push assignments from Okta → Entra
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

### 8. Export reports
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
        └── MigrationItem
              ├── status: DISCOVERED → READY → STUB_CREATED → IN_PROGRESS → VALIDATED → COMPLETE
              ├── owner_email
              ├── priority: HIGH | MEDIUM | LOW
              ├── entra_app_id (populated after New-EntraAppStub)
              ├── entra_sp_id  (populated after New-EntraServicePrincipal)
              ├── notes / blockers
              └── Assignments (users and groups pushed to Entra)

GroupMappings (per project, per app: Okta group ID → Entra group ID)
AuditLog      (immutable record of all changes)
```

All data lives in `%APPDATA%\OktaToEntra\<project-guid>\project.db` (SQLite).
Secrets are stored in the SecretStore vault, never in the database or config file.

---

## Cmdlet Reference

| Cmdlet | What it does |
|---|---|
| `New-OktaToEntraProject` | Create project, store credentials, test connections |
| `Get-OktaToEntraProject` | List all local projects with stats |
| `Select-OktaToEntraProject` | Set the active project for this session |
| `Test-OktaConnection` | Validate Okta API token |
| `Sync-OktaApps` | Pull apps from Okta, upsert to local DB |
| `Get-OktaAppDetail` | Get raw Okta app data by label or ID |
| `Test-EntraConnection` | Validate Graph API credentials |
| `New-EntraAppStub` | Create Entra App Registrations |
| `New-EntraServicePrincipal` | Create Enterprise Apps for assignment |
| `Add-EntraAppAssignment` | Push user/group assignments to Entra |
| `Get-MigrationStatus` | View per-app status table + dashboard |
| `Update-MigrationItem` | Update status, owner, priority, notes |
| `Set-AppGroupMapping` | Map an Okta group to a specific Entra group |
| `Get-AppGroupMapping` | List all group mappings |
| `Export-MigrationReport` | Generate CSV + HTML report |
| `Export-AppConfigPack` | Export per-app JSON config for engineers |
| `Start-OktaToEntra` | Interactive console menu |

---

## Credential Security

| Phase | Storage |
|---|---|
| SecretStore available | Windows Credential Manager via `Microsoft.PowerShell.SecretStore` |
| SecretStore unavailable | DPAPI-encrypted string in `%APPDATA%\OktaToEntra\<id>\secrets.json` |

**Never stored:** API tokens or client secrets in plaintext, in config.json, or in the SQLite database.

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
6. Click **Grant admin consent**
7. Go to **Certificates & secrets → New client secret**
8. Copy the **Tenant ID**, **Application (client) ID**, and the secret value for use in `New-OktaToEntraProject`

---

## File Structure

```
OktaToEntra/
├── OktaToEntra.psd1                 # Module manifest
├── OktaToEntra.psm1                 # Module loader
├── Install-OktaToEntra.ps1          # One-time setup script
├── README.md
├── Private/
│   ├── Database.ps1                 # SQLite schema + query helpers
│   ├── Vault.ps1                    # SecretStore credential management
│   └── Helpers.ps1                  # HTTP wrappers, console output
└── Public/
    ├── Project/
    │   └── Get-OktaToEntraProject.ps1
    │   └── New-OktaToEntraProject.ps1
    ├── Okta/
    │   └── OktaConnector.ps1
    ├── Entra/
    │   └── EntraConnector.ps1
    ├── Migration/
    │   └── MigrationPlanner.ps1
    ├── Reports/
    │   └── Reports.ps1
    └── Scripts/
        └── Start-OktaToEntra.ps1
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

**Graph API 403 Forbidden**
- Ensure admin consent was granted for all three permissions
- Verify the client secret hasn't expired
- Check the tenant ID matches the app registration

**Group assignments skipped ("not found in Entra")**
- Group names must match exactly (Okta display name = Entra display name)
- Use `Set-AppGroupMapping` for groups with different names

---

## Phase Roadmap

- **Phase 1 (current):** PowerShell local tool ← *you are here*
- **Phase 2:** Self-hosted Next.js web application with team UI
- **Phase 3:** Multi-tenant Azure SaaS

See the product plan document for the full roadmap.

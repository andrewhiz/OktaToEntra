# OktaToEntra — Backlog

Ideas and future improvements captured during development and testing.
Add new items here as they come up. Items are loosely grouped by area — no priority order within groups.

---

## Entra Actions

- **New-EntraBookmarkApp** — Create Entra My Apps bookmark apps for Okta bookmark/SWA apps the user decides to migrate. All required data (`appUrl`, `loginUrl`, `usernameField`, `passwordField`) is already captured in the config pack `swaData` section, ready for this implementation.

---

## Menu / UX

- **Group mapping UI (option 8)** — Still prompts for raw Okta App IDs. Apply the same search → numbered list → pick flow used in options 7 and 11.

---

## Connections / Setup

- **Entra `Organization.Read.All` permission** — App registration needs this permission added for `Test-EntraConnection` to work fully. Pending user action in Azure Portal.

---

## Reports

- **HTML report improvements** — Keep as a single self-contained HTML file but add:
  - Column filtering (dropdowns / search per column)
  - Column sorting (click header to sort asc/desc)
  - Show/hide column toggles
  - Pie charts at the top: one by migration status, one by protocol/sign-on mode, one by usage flag

---

## Phase D — Web Application (Cloudflare)

- Cloudflare Pages + Workers + D1 (SQLite-compatible) + R2 + Queues
- Multi-tenant Entra authentication — one app registration, admin consent flow per customer tenant
- `arctic` library for OAuth2 (MSAL does not run in V8 isolates)
- Mirror PS module functionality in a browser-based UI

---

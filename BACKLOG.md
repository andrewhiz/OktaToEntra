# OktaToEntra — Backlog

Ideas and future improvements captured during development and testing.
Add new items here as they come up. Items are loosely grouped by area — no priority order within groups.

---

## Entra Actions

- **New-EntraBookmarkApp** — Create Entra My Apps bookmark apps for Okta bookmark/SWA apps the user decides to migrate. All required data (`appUrl`, `loginUrl`, `usernameField`, `passwordField`) is already captured in the config pack `swaData` section, ready for this implementation.

---

## Authentication Policies

- **Okta Authentication Policy Discovery** — Pull global and app-specific Okta authentication policies (sign-on policies, MFA requirements, network zones, device conditions) via the Okta API. Surface them per app in the migration item and config pack so engineers know what access controls are currently in place before migrating.
- **Entra Conditional Access Policy summary** — Generate a human-readable summary per app mapping Okta policy conditions (MFA required, trusted networks, device trust) to their Entra CAP equivalents, as a migration guide for the engineer doing the manual CAP configuration.
- **Entra CAP creation (stretch)** — Optionally create draft Conditional Access Policies in Entra via Graph API based on the Okta policy mapping. Policies would be created in **report-only mode** (never enforced automatically) so the admin can review and enable them manually. Requires `Policy.ReadWrite.ConditionalAccess` Graph permission.

---

## Menu / UX

- **Group mapping UI (option 8)** — Still prompts for raw Okta App IDs. Apply the same search → numbered list → pick flow used in options 7 and 11.


## Reports

- **HTML report improvements** — Keep as a single self-contained HTML file but add:
  - Column filtering (dropdowns / search per column)
  - Column sorting (click header to sort asc/desc)
  - Show/hide column toggles
  - Pie charts at the top: one by migration status, one by protocol/sign-on mode, one by usage flag


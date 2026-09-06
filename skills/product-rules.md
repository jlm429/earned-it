# Earned It Product Rules

- The authoritative domain, history, sharing, and credit rules are in `docs/shared-household-architecture.md`.
- A household has seven canonical shared weekday lists. Calendar-date completions never recur with a weekday list.
- Members have explicit parent/child roles. Device installations and CloudKit participants are separate identities.
- Parent screens prioritize who did what on the shared daily list. Children see their own work and relevant household contributions.
- Keep authorization and mutation logic in `HouseholdStore` and `PermissionService`; never mutate domain facts from views.
- Retain streaks, excused-day neutrality, Monday to Sunday weeks, and the 85 percent allowance threshold. Never invent payments or amounts.

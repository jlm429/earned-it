# Earned It Agent Guide

## Working standard

- Keep changes small, direct, reviewable, and native to Apple platforms.
- Do not add features, dependencies, analytics, advertising, AI, or a custom backend without explicit approval.
- Do not use em dashes in prose, comments, documentation, commits, or PR text.
- Reproduce bugs end to end before changing code. Fix every lint, test, or flake failure encountered.
- Never add an agent name as a commit co-author.

## Product invariants

- `docs/shared-household-architecture.md` is authoritative for civil dates, recurrence, alternating turns, history, identity, permissions, synchronization, scoring, streaks, and allowance.
- Preserve stable family, member, device, participant, chore, occurrence, and fact identities.
- Persist source facts, then derive daily state, history, scores, streaks, and allowance outcomes.
- Children can act only as their invited profile. Parent permissions remain centralized in `HouseholdStore.swift` and `PermissionService.swift`.
- A CloudKit read/write participant has broader transport access than app-level role permissions. Never describe client checks as server-enforced authorization.
- Preserve exact invitation claims, one-time link binding, account membership recovery, and owner-only CloudKit participant management.
- Never rewrite historical outcomes through a configuration edit, recurrence change, rotation change, or migration.

## Data and release safety

- Never read, print, summarize, copy, commit, or expose `.env`, `.env.*`, keys, tokens, credentials, provisioning profiles, or service-account files.
- Keep family data in the local journal and the invited household's private/shared CloudKit zone. Never hard-code real family information.
- Never delete an actual store, create or revoke a live invitation for testing, mutate production CloudKit data, or deploy a CloudKit schema during agent work.
- Production must not seed sample families or expose debug clocks, reset flags, fixtures, or diagnostic-only controls.
- Do not change bundle IDs, signing identities, teams, certificates, profiles, entitlements, CloudKit containers, production schema, App Store Connect settings, or release pricing without explicit human approval.
- Treat App Store metadata, privacy answers, screenshots, asset rights, signing, schema promotion, TestFlight distribution, and submission as human-confirmed release inputs.

## Implementation and UI

- Use SwiftUI, SwiftData, CloudKit, XCTest, and XCUITest. Keep business rules in focused services and UI in small views.
- Use stable identifiers and calendar-aware normalization. Keep the explicit CloudKit transport boundary.
- Support Dynamic Type, VoiceOver, dark mode, sufficient contrast, reduced motion, and 44-point touch targets.
- Pair color with text or symbols and add stable accessibility identifiers to critical controls and test targets.

## Verification and delivery

- Build and test with the selected full Xcode installation and an available iPhone Simulator runtime.
- Run unit tests and no more than three focused UI flows. Check launch, relaunch persistence, confirmed local reset, and parent/child experiences when relevant.
- Simulator and transport-double tests do not prove signed, two-account CloudKit behavior. Follow the production evidence and limits in `docs/production-invitation-crash/`, `docs/production-invitation-package/`, and `docs/production-membership-recovery/`.
- Commit focused milestones on a feature branch. Run the configured no-mistakes pipeline, stop at a review-ready PR, and never merge without human approval.

## Task-specific guides

Read only the guides relevant to the change:

- `skills/product-rules.md` for product behavior
- `skills/swiftdata.md` for journal and persistence work
- `skills/swiftui-ui.md` for interface work
- `skills/testing.md` for verification
- `skills/earned-it-cloudkit-lifecycle/SKILL.md` for CloudKit family deletion, membership recovery, and invitation issuance or acceptance

Keep this file compact and useful across future tasks. Point to authoritative code or documentation instead of recording temporary branch history.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

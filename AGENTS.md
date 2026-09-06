# Earned It Agent Guide

## Engineering

- Keep changes small, direct, reviewable, and native to Apple platforms.
- Do not use em dashes in prose, comments, documentation, commits, or PR text.
- Fix every lint or test failure encountered, including unrelated failures and flakes.
- Reproduce bugs end to end before changing code.
- Do not add agent co-authors to commits.

## Architecture and Scope

- Build with SwiftUI, SwiftData, CloudKit, XCTest, and XCUITest. Keep sharing native.
- Keep business rules in focused services and UI in small views.
- Persist source data, then derive scores, streaks, and daily presentation state.
- Use stable identifiers and calendar-aware date normalization.
- Use the explicit CloudKit sharing boundary; do not add a backend, passwords, analytics, AI, external dependencies, or non-native frameworks.
- Follow `docs/shared-household-architecture.md` for recurrence, civil dates, history, identity, and allowance rules.

## Security and Data

- Never read, print, summarize, copy, commit, or expose `.env`, `.env.*`, keys, tokens, credentials, or service account files.
- Document required secrets only by variable name in `.env.example`.
- Keep family data in the local journal and the invited household’s private/shared CloudKit zone. Never hard-code real family information.
- Never delete existing actual stores or provision a live CloudKit schema during agent work. The preproduction journal uses its own named store.

## Accessibility and UI

- Support Dynamic Type, VoiceOver, dark mode, sufficient contrast, and reduced motion.
- Pair color with text or symbols, use semantic system colors, and label controls clearly.
- Add stable accessibility identifiers to critical controls and test targets.
- Verify layout and interactions on an iPhone Simulator.

## Verification and Delivery

- Build and test with the selected full Xcode installation and an available iPhone Simulator runtime.
- Run unit tests, no more than three focused UI flows, and manual checks for critical product rules.
- Confirm launch, relaunch persistence, first-run setup, confirmed local-data reset, and role-specific experiences.
- Production never seeds households. `HouseholdStore.swift` centralizes actions and profile permissions; `EarnedItApp.swift` configures the separate debug-only UI test store.
- Distinguish transport-double tests from signed, two-account CloudKit validation. CKShare write access is broader than app profile permissions.
- Use automatic signing only when needed for a physical device. Simulator work must not require a paid developer account.
- Commit focused milestones on a feature branch.
- Run the configured no-mistakes pipeline after implementation, stop at a review-ready PR, and never merge without captain approval.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

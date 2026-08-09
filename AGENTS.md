# Earned It Agent Guide

## Engineering

- Keep changes small, direct, reviewable, and native to Apple platforms.
- Do not use em dashes in prose, comments, documentation, commits, or PR text.
- Fix every lint or test failure encountered, including unrelated failures and flakes.
- Reproduce bugs end to end before changing code.
- Do not add agent co-authors to commits.

## Architecture and Scope

- Build with SwiftUI, SwiftData, XCTest, and XCUITest only.
- Keep business rules in focused services and UI in small views.
- Persist source data, then derive scores, streaks, and daily presentation state.
- Use stable identifiers and calendar-aware date normalization.
- Do not add networking, backends, authentication, cloud sync, notifications, analytics, AI, external dependencies, or non-native frameworks.
- Do not add scheduling or recurrence UI.

## Security and Data

- Never read, print, summarize, copy, commit, or expose `.env`, `.env.*`, keys, tokens, credentials, or service account files.
- Document required secrets only by variable name in `.env.example`.
- Keep all family data local. Never hard-code real family information.
- Preserve existing SwiftData records during model and migration changes.

## Accessibility and UI

- Support Dynamic Type, VoiceOver, dark mode, sufficient contrast, and reduced motion.
- Pair color with text or symbols, use semantic system colors, and label controls clearly.
- Add stable accessibility identifiers to critical controls and test targets.
- Verify layout and interactions on an iPhone Simulator.

## Verification and Delivery

- Build and test with the selected full Xcode installation and an available iPhone Simulator runtime.
- Run unit tests, no more than three focused UI flows, and manual checks for critical product rules.
- Confirm launch, relaunch persistence, first-run setup, sample-data reset, and role-specific experiences.
- Use automatic signing only when needed for a physical device. Simulator work must not require a paid developer account.
- Commit focused milestones on a feature branch.
- Run the configured no-mistakes pipeline after implementation, stop at a review-ready PR, and never merge without captain approval.

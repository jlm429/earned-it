# Earned It Technical Overview

This document keeps implementation context out of the public README. The authoritative rule specification remains [shared-household-architecture.md](shared-household-architecture.md).

## Storage and synchronization

Earned It persists immutable typed facts in a local SwiftData journal. The local store is `shared-household-v1.store`. SwiftData CloudKit mirroring is disabled. `CloudKitHouseholdTransport` explicitly exchanges the same facts through one custom zone in the owner's private database and invited participants' shared database.

Synchronization is eventual. Foreground activity, local changes, and pull to refresh initiate synchronization. Offline facts remain pending for retry. Production never seeds a household. Debug UI tests use a separate store and compile-gated fixtures.

The CloudKit schema used by the current transport includes the fact journal envelope and private account-membership records. The exact implementation is in `CloudKitHouseholdTransport.swift`. Production schema changes are manual release operations.

## Identity and invitations

Family members, app installations, CloudKit participants, and iCloud accounts are distinct identities. A validated claim binds a participant and device to one exact household member and role. Invitation records retain only a digest of the human-entered code and a digest binding the issued share URL.

Invitations use private one-time CloudKit participants. The app retains unfinished invitation packages locally so Apple verification and exact profile claiming can continue after interruption. CloudKit share write permission remains broader than parent and child permissions enforced by the app.

See the production invitation and membership reports under `docs/production-*` for signed-distribution evidence and remaining physical-device proof boundaries.

## Dates, recurrence, and history

Family dates use a fixed Gregorian timezone chosen at household creation. Facts store civil date keys rather than relying on the device's current timezone. Recurring chore configuration, dated completions, occurrence dispositions, excuses, assignments, and allowance revisions remain separate so edits do not rewrite history.

Scheduled chores recur by weekday. As-needed chores appear only after a parent activates an occurrence. Alternating chores use persisted participant order. A parent can mark a scheduled occurrence not needed and explicitly decide whether an alternating turn advances.

## Progress and allowance

Weeks run Monday through Sunday. Required work is scored per required child. Optional any-one contributions credit the contributor without penalizing other eligible children. Excused and not-needed occurrences are neutral. Children have the scheduled day and the following family calendar day to complete their own work.

Allowance tracking is optional and records eligibility and an amount for a week. It does not transfer money or record payment. Finished weeks retain the allowance revision that applied to them.

## Development boundaries

Unsigned Simulator builds do not prove CloudKit behavior. Domain tests use in-memory transport doubles. Release validation still requires signed devices, separate iCloud accounts, the distribution entitlement, the production schema, and the scenarios listed in [release-readiness.md](app-store/release-readiness.md).

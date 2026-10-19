# Earned It Technical Overview

This document keeps implementation context out of the public README. The authoritative rule specification remains [shared-household-architecture.md](shared-household-architecture.md).

## Storage and synchronization

Earned It persists immutable typed facts in a local SwiftData journal. The local store is `shared-household-v1.store`. SwiftData CloudKit mirroring is disabled. `CloudKitHouseholdTransport` explicitly exchanges the same facts through one custom zone in the owner's private database and invited participants' shared database.

Synchronization is eventual; offline facts remain pending for retry. This section owns synchronization triggers, work ownership, and recovery. The [Activity guide](punt-notifications.md#communication-coverage-and-privacy) owns background delivery configuration, alert behavior, and their release prerequisites. Production never seeds a household. Debug UI tests use a separate store and compile-gated fixtures.

The [marketing capture guide](../marketing-assets/1.1.0/README.md#reproduce) owns the opt-in Simulator demo journal and capture recipe.

The CloudKit schema used by the current transport includes the fact journal envelope and private account-membership records. The exact implementation is in `CloudKitHouseholdTransport.swift`. Production schema changes are manual release operations.

### Work ownership and recovery

The store registers accepted synchronization before waiting for the exclusive cloud mutation boundary. Cancelling a caller releases only that caller's continuation, promptly and exactly once. The accepted job remains owned by the store; lifecycle mutations retain their existing exclusive boundary and reentrant task-local token. Calls waiting for the same job coalesce. A request received during a fetch reserves one trailing pass, so remote edits arriving after that fetch's snapshot or newly queued local facts are not silently omitted. Automatic scheduling shares this same job and still defers behind independent lifecycle work.

All live callers await completion of the required passes. A failed pass can recover through an already queued pass; without queued work, its actual error returns. This adds no polling loop or unsolicited retry. View and debounce callers whose tasks were cancelled do not present stale errors. A `CancellationError` from incomplete transport work on a live caller displays an interrupted-update retry message. Other errors retain their existing descriptions, access classification and journal retention. A successful later retry is never evidence that an earlier interrupted pass finished.

### Automatic synchronization triggers

| Trigger | Current behavior |
| --- | --- |
| Launch / installation session task | Refreshes the civil date and schedules a debounced sync for an attached household, alongside guarded membership reconciliation and invitation recovery. |
| Scene becomes active | Refreshes the date and schedules sync; rechecks alert authorization. Returning from iOS Settings follows this path. |
| Local source-fact mutation | The existing commit boundary schedules sync. Multiple arrivals use the 350 ms debounce, or reserve a trailing pass during active work. |
| iCloud account change | Invalidates account generation/recovery candidates, refreshes date and schedules guarded sync. |
| Calendar day / significant time change | Refreshes the household date and schedules sync. Significant-time changes also reset the midnight timer. |
| Foreground household midnight | One calendar-aware sleep refreshes the date and schedules sync; scene inactivity cancels the timer. |
| Connect, join, invitation and lifecycle operations | Existing explicit synchronization remains within the corresponding identity and lifecycle checks. |
| CloudKit database silent change hint | The enabled app delegate invokes validated synchronization and Activity processing, in foreground or background, with a 25-second callback watchdog. |
| Manual action | Parent home, child home, Activity pull-to-refresh and root retry controls use the same synchronization boundary. |

Opening Activity processes the current local feed and authorization; it does not itself fetch remote facts. Foreground devices can receive updates without manual refresh when a CloudKit database hint is delivered, or when another listed trigger runs. There is no continuous foreground listener or periodic polling. APNs hints are best effort and may be coalesced, delayed, throttled or dropped. A device remaining foreground with no delivered hint or local trigger can remain stale until a refresh or foreground transition. Notifications being off or denied does not disable sync, Activity or turn decisions. Background delivery also depends on system scheduling, Background App Refresh and process availability. Force quit can prevent wake.

## Identity and invitations

Family members, app installations, CloudKit participants, and iCloud accounts are distinct identities. A validated claim binds a participant and device to one exact household member and role. Invitation records retain only a digest of the human-entered code and a digest binding the issued share URL.

Invitations use private one-time CloudKit participants. The app retains unfinished invitation packages locally so Apple verification and exact profile claiming can continue after interruption. CloudKit share write permission remains broader than parent and child permissions enforced by the app.

See the production invitation and membership reports under `docs/production-*` for signed-distribution evidence and remaining physical-device proof boundaries.

## Dates, recurrence, and history

Family dates use a fixed Gregorian timezone chosen at household creation. Facts store civil date keys rather than relying on the device's current timezone. Recurring chore configuration, scheduled and occurrence-scoped completion and control facts, excuses, assignments, and allowance revisions remain separate so edits do not rewrite history.

Scheduled chores recur by weekday. Parents explicitly activate as-needed availability. The authoritative rules for distinct same-day occurrences, withdrawal, correction, scheduled restoration, and alternating-turn advancement are in [shared-household-architecture.md](shared-household-architecture.md).

## Progress and allowance

Weeks run Monday through Sunday. Required work is scored per required child. Optional any-one contributions credit the contributor without penalizing other eligible children. Excused and not-needed occurrences are neutral. Children have the scheduled day and the following family calendar day to complete their own work.

Allowance tracking is optional and records eligibility and an amount for a week. It does not transfer money or record payment. Finished weeks retain the allowance revision that applied to them.

## Development boundaries

Unsigned Simulator builds do not prove CloudKit behavior. Domain tests use in-memory transport doubles. Release validation still requires signed devices, separate iCloud accounts, the distribution entitlement, the production schema, and the scenarios listed in [release-readiness.md](app-store/release-readiness.md).

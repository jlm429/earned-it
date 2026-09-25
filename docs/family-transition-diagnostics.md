# Family transition diagnostics

## Scope

The diagnostic trace covers an owner's first invitation after replacing a deleted family. It begins before `connect` and reports the read-only preflight, participant lookup, membership validation time, lock acquisition, zone creation, lifecycle authority preparation, journal fetch and upload, lock activation, invitation validation time, share fetch or creation, participant creation, invitation append, and invitation fact upload.

Every event contains only stage names, states, counts, equality results, CloudKit error codes, error source, and retry timing. It never logs family, member, device, participant, invitation, record, zone, or attempt identifiers. It never logs names, URLs, codes, digests, payloads, credentials, or secrets.

The invitation failure surface exposes Copy Diagnostics only after an issuance error. The copied trace uses the same typed allow-list and is not shown as a routine debug console. Recipient and lifecycle failures may add equivalent copy actions only when a user can preserve a bounded failure trace without exposing invitation material or CloudKit identity.

The in-memory trace is bounded to 200 events and is also written to unified logging with subsystem `com.jlm429.EarnedIt` and category `FamilyTransition`. No diagnostic receipt is persisted in the family journal or device session. The diagnostic path adds no schema. The deletion correctness fix separately requires the `FamilyLifecycleAuthority` type documented in `docs/family-lifecycle-authority.md`.

## Read-only preflight contract

`HouseholdStore.collectOwnerTransitionPreflight()` reads local facts and calls the transport's read-only snapshot operation. The CloudKit implementation performs only these reads:

1. Current participant lookup.
2. Current private account membership lock fetch.
3. Direct public lifecycle authority fetch by an opaque deterministic record name.
4. Private record-zone listing for the local Family B identity.
5. Family B zone-change reads when that zone exists.
6. Family B zone-wide share record fetch when that zone exists.

It does not synchronize or import facts. It does not write validation-time records, retry a failed operation, create or revoke an invitation, create or delete a zone or share, upload facts, clean up access, or acquire, activate, release, or otherwise transition membership.

The snapshot reports:

- Lock state, whether it matches Family B or another household, whether its attempt matches local state, whether its claim matches Family B, and whether its owner-authority binding matches the current owner.
- Lifecycle state when a valid creator-bound record exists.
- Whether Family B's local location is absent, owner-controlled, shared, or for another household.
- Whether the current participant equals the locally recorded participant and whether the account generation stayed stable during collection.
- Local and CloudKit fact counts, household root and member fact counts, and Family B zone existence.
- Share existence plus total, pending, and accepted participant counts.
- Invitation, claim, and revocation counts.
- Child member, child invitation, child claim, child grant-reference, and internally consistent exact-child recovery-binding counts.
- Exact `CKError.Code`, top-level or partial-item source, grouped item count, and retry-after seconds when CloudKit supplies it.

Invitation trace format 2 also records the lifecycle-authority attempt and fetch or save phase. A fetched record is represented only by typed comparisons for record type, format version, recognized lifecycle state, creator presence and current-account match, modifier presence and current-account match, and requested-state match. Internally retried missing-record or record-conflict errors retain only their allow-listed CloudKit codes and retry timing. The trace never includes the public record name, creator or modifier identifiers, or the opaque owner-authority binding.

The September 24, 2026 Production trace showed four exact cycles of an absent initial authority record followed by `CKError.unknownItem` from the redundant post-save verification fetch. Xcode 27 defines that CloudKit error as code 11. Lifecycle mutations now validate the server-returned record in the save result, matching the transport's other confirmed-save paths. The exact record, state, creator, modifier, current-account, and account-generation checks remain unchanged.

An absent or inaccessible value remains unknown rather than being inferred. A lock for another household is the privacy-safe observable for the released Family A candidate when Family A's identity is no longer local.

## Current physical-device evidence

The read-only host check on September 23, 2026 saw one paired wired iPhone 13 running iOS 26.6. Developer Mode was disabled, and the second device was not visible. No app was launched and no CloudKit request was made.

Before Developer Mode is enabled, the safe evidence is limited to that connection, model, OS, and Developer Mode state. The installed build cannot produce the new snapshot, and no app-side current-state claim should be made. Do not launch Earned It, retry the invitation, refresh, relaunch, delete, reinstall, clean up, or change either account to obtain more evidence.

## Current broken-state collection sequence

Use this sequence only after the captain separately authorizes a signed development build and Developer Mode is already available. Do not uninstall the existing app. Stop if Xcode proposes deleting app data, uses a different application identifier or team, or cannot install over the existing application while preserving its container.

1. Keep Earned It closed on both devices. Do not operate the child device.
2. Connect only the owner device by cable.
3. On the Mac, open Console, select the owner iPhone, start streaming, and filter for subsystem `com.jlm429.EarnedIt` and category `FamilyTransition`.
4. In Xcode's Run scheme, use the Debug configuration and add the launch argument `--owner-transition-preflight`.
5. Run that signed Debug build on the owner device without uninstalling first. This Debug-only mode blocks local migrations and test fixtures plus normal startup reconciliation, synchronization, invitation continuation, cleanup, URL handling, and account-change refresh. It performs the read-only preflight once.
6. Wait for the device to show `Snapshot Captured`. Save only the `family-transition` log lines from `invitationStart`, `preflight`, and `completed`.
7. Stop the owner app. Do not tap an invitation control, pull to refresh, reopen the app normally, or change either account.
8. Save and review the owner snapshot before touching the child device. It cannot observe the child's private membership lock or exact child resolution.
9. Connect only the child device. Keep the owner app closed. In Console, switch the device stream to the child iPhone and retain the same subsystem and category filter.
10. Replace the owner launch argument with `--child-recovery-preflight`, then run the signed Debug build over the existing child installation without uninstalling. Stop if its application identifier, team, or data-container preservation differs.
11. Wait for `Snapshot Captured`, save only the `family-transition` lines from `invitationStart`, `childRecoveryPreflight`, and `completed`, then stop the app.
12. Review both snapshots before authorizing any retry or state change. If collection reports a CloudKit error, preserve its exact code, source, count, and retry-after value. Do not retry collection automatically.

Both Debug-only launch arguments are compiled out of Release behavior and display no identifiers or payloads. The child mode reads its private membership lock, local equality state, old Family A shared-zone visibility, zone-wide share visibility and permission booleans, invitation and validation fact counts, and any committed exact membership that can be derived without authoritative-time writes.

The child snapshot deliberately stops before Production recovery's authoritative validation-time write, lock activation, and local attach. `productionResolveCompleted` therefore remains false. Its `furthestStage` and `readOnlyResult` report whether collection reached the participant, lock, shared zone, journal, share, or exact committed membership boundary. If the zone is absent, the furthest result is `sharedZoneMissing`. If exact committed membership and the private lock agree, it reports `exactCommittedMembershipMatchesLock`, but this is not a claim that the complete Production recovery would succeed.

## Capturing the next first failure

For a future signed build with this instrumentation, connect Console before the owner starts Family B's first invitation. Keep the same subsystem and category filter. Perform the first invitation attempt once. Stop after success or the first error and export the `family-transition` lines before any retry, refresh, relaunch, cleanup, or second invitation attempt. The first failed stage and its CloudKit error evidence remain primary. A later 503 is secondary unless the stage trace places the first failure at that boundary.

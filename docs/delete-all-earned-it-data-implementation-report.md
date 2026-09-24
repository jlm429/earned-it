# Delete All Earned It Data Implementation Report

## Outcome

`Delete All Earned It Data` is a permanent, account-wide destructive escape hatch for owners, invited parents, children, connected installations, recovery states, profile selection, and Welcome. Settings and recovery UI call the same `AccountDataResetCoordinator`. The action uses one confirmation:

> Delete All Earned It Data? This permanently deletes your Earned It family data, membership, invitations, and local app data from iCloud and this device. This cannot be undone.

The invitation diagnostics button remains in place. Invitation creation behavior was not changed to compensate for Production schema state.

## Deletion boundaries

### Owner account

The coordinator enumerates every custom zone in the current account's private CloudKit database. It deletes a zone only when its name is exactly `EarnedIt-<UUID>`. Deleting the zone removes every household fact, temporary record, zone-wide `CKShare`, invitation metadata, and participant entry in that zone. The coordinator does not depend on the household cached on this device, so stale zones for multiple old households are included.

It also deletes:

- the exact `AccountMembershipLock/current-membership` record after verifying its type;
- all `AccountMembershipValidationTime` and defensive `_defaultZone` `InvitationValidationTime` matches;
- every `FamilyLifecycleAuthority` whose CloudKit creator is the current participant and that the current account is authorized to delete;
- all current and historical local persistence described in the historical inventory.

Malformed `EarnedIt-` names and unrelated private zones are never guessed or deleted.

### Participant parent or child

The same coordinator deletes the current participant account's private lock and validation records for provisional, active, released, stale, interrupted, and recovery states. It enumerates every exact Earned It zone in the shared database and deletes that zone's shared-database zone-wide share reference to relinquish the current account's participation.

CloudKit does not give a participant authority to delete the owner's private zone, owner-side `CKShare`, other participants, or server-side share material that is not exposed in the participant's shared database. A participant reset therefore means verified loss of that account's visible Earned It shared access, not deletion of the former owner's household. If owner-side stale participant metadata remains, the owner must remove it or delete the owner zone. The app does not claim otherwise.

## Phases, durability, and atomicity

1. **Bind identity.** The coordinator reads the current CloudKit participant and account-generation value. It persists an `AccountDataResetProgress` receipt in the existing SwiftData session before any cloud mutation. The receipt binds the operation to the exact participant.
2. **Discover.** It rechecks participant and generation, enumerates exact owner and shared zones, queries the historical private-record allow-list, and queries public lifecycle records by creator. The deterministically ordered target plan is persisted.
3. **Delete and checkpoint.** Targets are processed in order: owned zones, shared participation, public records, then private records. After each successful deletion, the target is removed from the persisted plan. Exact record or zone not-found is success. Record type and public creator are checked before individual deletion.
4. **Verify absence.** The coordinator repeats full discovery after the target plan is exhausted. It cannot report success while a target remains. Up to four verification passes bound eventual-consistency retries. A still-visible target or a real CloudKit error leaves the receipt and remaining targets intact and surfaces a retryable error.
5. **Clear nonjournal local state.** Only after an empty cloud discovery pass does the app remove obsolete historical stores and sidecars, app cache contents, the app's UserDefaults domain, and in-memory diagnostic receipts.
6. **Replace the active journal.** The repository verifies that the durable receipt is present, saves and releases the active SwiftData container without erasing it, checkpoints SQLite so the receipt is in the main journal, removes its WAL, SHM, and support artifacts, and removes the receipt-bearing `shared-household-v1.store` last. Any failure before that final unlink reopens the original journal with its receipt. A successful unlink is the atomic local completion boundary, after which the repository opens a clean replacement containing only a new empty `DeviceSession`.
7. **Navigate.** The observable store reloads as an empty installation and the root route becomes Welcome.

If the app terminates or a deletion fails, startup sees the receipt before membership recovery and resumes the same coordinator. Cloud cleanup always precedes final local cleanup. Local cleanup steps are idempotent, so an interruption between them can safely retry. A CloudKit account notification, participant mismatch, or generation change fails with `wrongAccount` before further deletion and preserves the receipt. Switching back to the bound account permits a new generation-safe retry.

## No-resurrection behavior

Owned zones are deleted before lifecycle and private lock records. An interruption therefore leaves conservative evidence that blocks ordinary recovery until reset resumes. On full completion, no obsolete lock, lifecycle record, local invitation continuation, recovery receipt, or journal remains to reconstruct active membership.

A stale offline installation can retain an old local journal, but it cannot recreate a deleted custom zone. Synchronization fetches the existing zone before upload, and zone creation is limited to explicit new-family connection. When the stale participant comes online, missing access produces the recovery screen with `Try Reconnecting` and the explicit destructive action. Reset then removes that participant account's private membership and shared access before clearing the stale local journal.

## UI and accessibility

- Settings contains the same destructive action for owner parents, invited parents, children, unselected profiles, and a clean Welcome installation.
- The pending Apple invitation-verification route is scrollable and retains the same destructive action.
- Recovery screens always retain `Try Reconnecting` and add `Delete All Earned It Data`. A reconnect failure never starts reset automatically.
- A pending reset has a dedicated progress route. It retries on launch and offers `Retry Deletion` after an error.
- The confirmation is one system alert with a destructive button and Cancel. There is no phrase entry or second confirmation.
- Stable accessibility identifiers cover the destructive action, retry action, recovery actions, and progress route.
- Automatic membership reconciliation is owned by the store. Explicit retry or reset cancels and awaits that task before starting the selected operation, preserving one cloud mutation at a time.
- The creator-only `Delete Family and Cloud Data` flow and stale-owner `Release My Membership` flow remain available beside the account-wide escape hatch.
- Child navigation exposes Settings and the account-wide reset without exposing the parent-only local disconnect control.

## CloudKit safety properties

- Every operation is scoped to `iCloud.com.jlm429.EarnedIt` through the existing transport.
- Private record operations run only in the currently authenticated account's databases.
- Owner zone selection requires both the exact prefix and a valid UUID suffix.
- Public deletion verifies the exact known record type and current participant creator.
- Shared deletion uses only zones CloudKit exposes to the current participant.
- No code resets a CloudKit environment, modifies a schema, deploys a schema, or enumerates unrelated containers.
- Simulator and unit tests use the injected transport double. No Production data was written or deleted during implementation or testing.

## `FamilyLifecycleAuthority` Production finding

### What is observed

The supplied Production trace has stable account identity, a matching provisional lock and nonce, successful membership validation, lock acquisition, and zone creation. Its first failure is `lifecycleAuthorityPrepare` at `CKDatabase.fetchSave.FamilyLifecycleAuthority`. Fetch reports the deterministic record absent. Save then returns `CKErrorDomain` code 12 with `Cannot create new type FamilyLifecycleAuthority in production schema`. Share and participant creation are never reached.

That trace is evidence that the running Production schema did not permit creation of this record type at the time of the attempt. It is separate from the account reset implementation and is not evidence of a nonce, membership, share, or participant bug.

### Direct inspection limitation

The available `cktool` installation was used only for a read-only authentication check. `xcrun cktool get-teams` reported that no management token was available. No authenticated CloudKit Console session or management token was available in this worktree, so the Production schema was not directly inspected. No schema or Production data mutation was attempted.

### Captain action in CloudKit Console

In Apple's CloudKit Console for `iCloud.com.jlm429.EarnedIt`:

1. Select the Development environment and open Schema, Record Types.
2. Verify `FamilyLifecycleAuthority` exists with `formatVersion` of type Int64 and `state` of type String.
3. Configure public-database security so authenticated iCloud users can read and create, the record creator can read and write, and world access is disabled. This lets invited participants validate lifecycle state while only the creator can change or delete it.
4. Ensure the system creator field is queryable. The reset enumerates the current account's lifecycle records by `creatorUserRecordID`. Keep record-name lookup available for deterministic direct fetches. No app-field query index is required by current code.
5. Review all pending Development schema changes. Use the CloudKit Console deployment workflow to deploy the approved schema changes to Production. Do not create a one-off Production data record as a substitute for schema deployment.
6. Switch the console to Production and confirm `FamilyLifecycleAuthority`, both fields, the creator query index, and the security roles are present.
7. Retry invitation creation on a clean signed owner device and confirm the trace advances past lifecycle authority preparation to share and participant creation.

Apple documents schema inspection and editing at [Inspecting and editing an iCloud container's schema](https://developer.apple.com/documentation/cloudkit/inspecting-and-editing-an-icloud-container-s-schema) and deployment at [Deploying an iCloud container's schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema).

The reset's creator query also depends on the Production query index in step 4. Until the deployed schema supports that query, a real cloud reset may fail and retain its local reset receipt. That is intentional. The app must not report complete cleanup after a partial cloud operation.

## Focused executable coverage

`EarnedItTests/AccountDataResetTests.swift` uses the injected `HouseholdTransport` and `AccountLocalDataResetting` boundaries to exercise behavior rather than scan source text.

| Requirement | Executable coverage |
| --- | --- |
| Clean owner reset | Connected owner zone, lock, facts, lifecycle authority, and local state are removed. |
| Multiple stale owner zones | Multiple exact UUID zones are deleted while malformed and unrelated zones remain. |
| Participant or child reset | Private lock and shared participation are removed without deleting the owner zone, owner lock, or lifecycle record. |
| Lock forms | Provisional, active, and released `current-membership` records are each deleted. |
| Missing targets | A repeated reset and missing record or zone conditions are idempotent. |
| Interruption and resume | A deletion failure retains progress and local data; a relaunched store resumes and completes. |
| Offline then online | Discovery fails offline, retains progress, and succeeds after retry. |
| Stale local data | Cloud cleanup is verified before current journal and session data are atomically cleared. |
| Active store interruption | Auxiliary-cleanup failure leaves the receipt-bearing main store readable, while successful teardown removes the main store last. |
| Fresh installation and relaunch | An empty repository remains at Welcome after server reset and repeated recovery checks. |
| Recovery invocation | The recovery UI confirms the action through an injected non-Production cloud boundary, reaches Welcome, and remains there after relaunch. |
| Recovery operation ownership | Reset cancels and awaits an active automatic membership reconciliation before deleting. |
| Account change | Participant or generation changes fail closed and retain the reset receipt. |
| No resurrection and orphan sequence | A connected parent deletes while the child is offline; child reconnect fails without recreating the zone; child resets; Welcome survives relaunch; child accepts a fresh invitation into a new family. |
| Historical local artifacts | Known historical and active store files, sidecars, support directories, cache contents, and the bundle preference domain are removed through the managed store lifecycle. |

The focused recovery UI flows verify that reconnect and reset remain scroll-reachable during automatic recovery, that stale-owner release remains available, and that the exact reset confirmation is accessible at large Dynamic Type. Real signed two-account CloudKit behavior still requires the device procedure below.

## Real-device captain procedure

Complete the Production schema check and deployment above before using the new reset in Production.

1. Reset each account independently through `Delete All Earned It Data`, wait for completion, delete and reinstall Earned It, and launch online. Confirm Welcome appears. Relaunch each device and confirm Welcome remains.
2. On a clean parent account, create a new family. Reset the child account, send a new invitation, accept it on the child, and confirm normal two-way sync.

For the orphan sequence, keep the child offline while the old parent resets. Bring the child online, confirm reconnect cannot restore the deleted family and both recovery actions are offered, choose the explicit destructive action, then perform the child portion of steps 1 and 2.

## Verification record

Validation used one explicitly booted iPhone 17e simulator with parallel testing disabled:

- `AccountDataResetTests`: 14 tests passed, including owner, participant, interruption, offline retry, identity changes, mutation exclusion, active-store ordering, historical local artifacts, and the full orphan sequence.
- Focused recovery UI flows: 2 tests passed, verifying recovery-progress actions, stale-owner release, and the exact destructive confirmation at an accessibility text size.
- Complete `EarnedItCI` suite: 306 tests passed with 0 failures.
- Release simulator build: succeeded. Release device-family metadata, build-number semantics, and App Store profile entitlement semantics all passed their repository validation scripts.

No signed two-account Production deletion was run. The captain will perform the first real account cleanup only through the completed UI. The no-mistakes delivery report will be added when Firstmate requests the shipping gate.

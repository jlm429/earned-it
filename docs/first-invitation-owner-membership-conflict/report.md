# First invitation owner membership conflict

Date: 2026-09-23. Implementation baseline: `origin/main` at `4f66e2b`. Uploaded 1.0.2 source path used for comparison: `origin/release/earned-it-1.0.2` at `7790176`. No Production CloudKit data, schema, signing, entitlement, version, or build-number setting was read or changed.

## Finding and proof boundary

The authoritative membership-lock contract is in [Shared household architecture](../shared-household-architecture.md#identity-and-sharing). This report records the incident-specific diagnosis, correction, and evidence boundary.

Invitation bootstrap rejected an active owner membership when the private lock's acquisition `attemptID` differed from the attempt cached in the device session. The lock still had the same household, active state, deterministic owner claim binding, and exact owner-authority binding for the current CloudKit participant. `attemptID` guards its acquisition generation and conditional transitions. It is not, by itself, the identity of an already active owner membership.

The current implementation now accepts that one exact active-owner case, conditionally validates the unchanged active lock, adopts its retained attempt locally, and continues invitation creation. It does not release or replace the lock. Different households, changed accounts, provisional or released locks, non-owner claims, wrong owner authority, and conflicting local claim bindings remain rejected.

A signed iPhone with Production CloudKit was not available for safe reproduction. The behavioral regression uses the public `HouseholdStore` create, connect, profile, invitation, synchronization, and redemption interfaces with the repository and transport double. It preserves all active owner fields and changes only the private lock's retained acquisition nonce.

The exact clean in-process control succeeds before this fix when the local and private attempts agree. An audit found no current in-process setup, reconstruction, or post-activation path that naturally changes or clears that attempt: startup recovery finishes before Welcome, setup has no cloud location, `connect()` persists the returned attempt before creating the zone, and owner recovery restores the private lock's attempt. The missing evidence boundary is the signed iPhone and CloudKit transition that produced the differing durable values observed before the first invitation. The fixture faithfully models the observed comparison point, but it does not claim to reproduce that unmeasured native transition.

## Exact path and earliest divergence

1. `FamilyInvitationView.createInvitation()` calls `HouseholdStore.createChildInvitation(memberID:)`.
2. `issueInvitation(for:adding:)` starts the transition, connects when needed, then synchronizes before creating invitation access.
3. `connect()` looks up the participant, acquires the account membership lock, persists the provisional session route, creates the household zone, verifies lifecycle authority, uploads the initial journal, and activates the deterministic owner membership.
4. `performSynchronization()` fetches the remote journal before any upload and calls `reconcileAccountMembershipLock(imported:location:participant:)`.
5. Before the fix, reconciliation compared the private lock `attemptID` to `session.accountMembershipLockAttemptID` before recognizing the lock as the same valid active owner membership. A mismatch threw `HouseholdError.accountMembershipConflict`.
6. `PermissionService` maps that error to: "This iCloud account already belongs to an Earned It family member. Use that member, or ask the family owner to remove this account before joining again."
7. The failure precedes `invitationValidationTime`, `createInvitationAccess`, CKShare fetch or creation, one-time participant creation, and invitation fact generation.

The earliest divergence from the intended path is therefore the membership reconciliation guard after fetch and lifecycle verification. The successful path should recognize the active owner membership semantically and retain it. The failing path treated its acquisition nonce as active membership identity and stopped before share work.

## State at the failure

The focused fixture establishes the following state immediately before the first invitation synchronization:

| Field | Private lock or local state |
| --- | --- |
| Household | Same synthetic household B in lock, local session, owner location, and journal |
| Profile | Selected active parent from household B; the private lock intentionally contains no profile identifier |
| Role | Parent in the journal; owner in the CloudKit location |
| Participant | Current synthetic owner participant in the session and transport |
| Account generation | Stable at `0` for the success case |
| Lock state | `active` |
| Claim binding | Exact `AccountMembershipBinding.owner(householdID: B)` |
| Owner authority | Exact `AccountMembershipBinding.ownerAuthority(participantID: owner)` |
| Private attempt | Retained active attempt A |
| Local attempt | Different cached attempt B |

Reconciliation tries to validate or reacquire the same deterministic owner binding for household B. Before the fix, `currentLock.attemptID == localAttemptID` classified A versus B as a conflicting family member even though every authority-bearing field agreed.

## Trigger, masking condition, and symptom

- Initiating trigger: first exact-child invitation synchronization with a valid same-household active owner lock whose retained acquisition nonce differs from the local cached nonce.
- Independent masking condition: the ordinary in-memory happy path creates and retains one nonce on both sides. Existing `TestFamily` invitation tests therefore never entered the divergent comparison state. The clean matching-attempt control continues to pass.
- Visible symptom: `accountMembershipConflict` becomes the "Unable to Create Invitation" alert on the parent device. The child device is not involved.

The smallest counterfactual keeps household, participant, generation, lock state, claim binding, owner authority, selected parent, child, and journal unchanged, and makes only the active lock attempt equal the local attempt. The pre-fix path succeeds. A disconfirming clean control also succeeds without injecting any divergence, which proves that family creation or first invitation alone is insufficient to trigger this concrete guard.

## History

Commit `e40ac06` added the strict retained-attempt comparison while completing family lifecycle transition handling. The earlier reconciliation in `59f3c67` did not use acquisition-attempt equality as active owner identity. The comparison protected stale and replaced membership generations, which remains required for shared-member and provisional paths. Its application to an exact active owner lock was broader than that invariant.

Both the uploaded 1.0.2 commit `7790176` and current main before this change contain the same comparison and fail the divergent active-owner regression with `accountMembershipConflict`. Main's later lifecycle recovery changes do not correct this case. Main does already preserve and pass the uninterrupted clean matching-attempt first-invitation path. Those post-release changes are retained but are not attributed as causes or fixes for this bug.

## Correction and regression coverage

The correction is confined to account membership reconciliation:

- Pin and recheck the CloudKit account generation and participant.
- Derive the same owner binding from fetched household B.
- Require owner location, matching local route, an active selected parent present in the fetched journal, active lock state, same household, exact owner claim, and exact owner-authority binding.
- Revalidate through the existing conditional activation operation using the private lock's retained attempt.
- Persist that retained attempt locally and continue, without reacquiring, releasing, or replacing membership.
- Preserve the original strict attempt check for provisional, released, shared-member, revoked-generation, missing-binding, and all other non-reuse cases.

Focused behavioral coverage proves:

1. Clean account, family, parent, child, and first invitation creates one active owner membership and succeeds.
2. Same owner, same household, stable generation, and exact active owner authority succeeds even when only the retained attempt differs.
3. A different active household remains `accountMembershipConflict` before share creation.
4. A same-household lock with the wrong owner claim or owner-authority binding remains `accountMembershipConflict` before share creation.
5. A same-household account-generation change remains `wrongAccount` before share creation.
6. Released and stale provisional memberships cannot regain authority.
7. The issued invitation still binds only the selected child. Redemption exposes neither the owner parent nor a sibling profile.
8. The owner lock is active at every conditional validation, is unchanged after issuance and child redemption, and incurs no reacquisition. No broadly unassociated interval is introduced.
9. The existing interrupted revoked-generation replacement regression still prevents an old attempt from reactivating a replacement provisional lock.

## Evidence and remaining uncertainty

Pre-fix on current main: the focused regression failed with unexpected `accountMembershipConflict` in `.artifacts/first-invitation-conflict-before.xcresult`.

Pre-fix on exact uploaded source `7790176`: the same regression failed with `accountMembershipConflict` in `.artifacts/release-7790176-conflict.xcresult`.

After the correction, five focused tests passed in `.artifacts/first-invitation-after-focused.xcresult`. The first broader invitation run found an ordering regression in the retained stale-attempt check. The implementation was corrected, and the exact active-owner plus interrupted revoked-generation tests passed together in `.artifacts/first-invitation-stale-generation.xcresult`.

The final invitation suite passed all 74 tests in `.artifacts/first-invitation-final-invitation-suite.xcresult`. After adding the exact claim and owner-authority negative control, the final complete unit suite passed all 280 tests in `.artifacts/first-invitation-final-full-unit.xcresult` on an iPhone 17 Pro Simulator running iOS 26.5 with Xcode 26.6.

These Simulator and transport-double results do not prove signed CloudKit behavior. The remaining uncertainty is whether a fresh current-version parent iPhone and TestFlight first invitation produces the same private-versus-local attempt divergence and whether the conditional active-owner validation succeeds against Production CloudKit. That retest should create one fresh family and its first exact-child invitation without another reset, then confirm invitation presentation, exact-child redemption on the intended second account, synchronization, and relaunch persistence.

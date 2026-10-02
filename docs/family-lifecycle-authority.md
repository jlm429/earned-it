# Family lifecycle authority

## Why it exists

A child must not treat loss of a shared CloudKit zone as proof that the owner deleted the family. The same visible absence can follow participant removal or revocation. CloudKit's database-change deletion callback reports the removed zone identity, not an application-level reason for loss. A durable owner-authenticated authority outside the deleted zone is therefore required before the app may release a child's active account membership lock.

The authority is correctness state, not a diagnostic receipt. Diagnostic collection remains read-only and does not create or modify it.

## Record contract

The record is stored in the public database so an authenticated former participant can fetch it after the shared zone is gone.

- Record type: `FamilyLifecycleAuthority`
- Family record name: SHA-256 of a domain-separated household UUID.
- Membership-revocation record name: SHA-256 of the household UUID and the already opaque invitation-claim binding, with a separate domain prefix.
- `formatVersion`: Int64, currently `1`
- `state`: String, one of `active`, `deleting`, or `deleted`
- System metadata: `creatorUserRecordID` and `lastModifiedUserRecordID`

There are no family names, member names, invitation values, URLs, codes, zone names, participant identifiers, payloads, or journal facts in the record. A membership-revocation record exposes only a second one-way record-name digest derived from an already opaque claim binding. The private `AccountMembershipLock` payload gains only an optional opaque hash of the exact owner participant. That is an existing Bytes payload and does not add an `AccountMembershipLock` schema field.

CloudKit can represent creator and modifier metadata as a stable unique record name or as the current-user sentinel. The app accepts each stable unique name only when its derived owner-authority binding matches the exact binding retained in the private lock. It accepts the sentinel only when its record name is `CKCurrentUserDefaultName`, its zone is the default record zone, its zone owner is `CKCurrentUserDefaultName`, and the current reader's derived binding matches the retained owner binding. A missing identity, a foreign unique name, a non-owner reader sentinel, or a sentinel with another zone name or owner fails closed. The current account and account generation are checked around every mutation.

Account-wide cleanup does not discover or delete lifecycle records. Every owned Earned It zone is instead taken through the same authenticated `deleting` and `deleted` transition as the focused family workflow. A persisted legacy public-record reset target is treated as complete without deleting its tombstone.

After a lifecycle mutation, the app validates the server-returned saved record directly. It requires the exact requested record ID and lifecycle state plus the same creator and last-modifier ownership checks. It does not depend on a second immediate fetch to confirm a write that CloudKit has already returned.

## State transitions

The family record's `active` state is created during owner bootstrap or backfilled while recovering an accessible owner family. It can move only to `deleting`. `deleting` can move only to `deleted`. No path returns a family record to `active`.

Before removing a claimed invitation's CloudKit participant, the owner writes an immutable claim-scoped record in `deleted` state. The owner then removes share access and appends the journal revocation. This record uses the existing schema and creator checks. It lets a participant authenticate revocation even when share removal prevents that device from downloading the final journal fact. A failure to publish the record stops revocation before access is removed.

Owner deletion persists local pending state before publishing `deleting`, deletes the exact owner zone, publishes `deleted`, conditionally releases the exact owner lock, and then purges that household's local data. Repeating any completed phase is safe.

A child releases an active lock only when all of these conditions hold:

1. Household, attempt, current participant, and account generation still match.
2. The lock contains the exact owner-authority binding, or an installed exact location supplies it for legacy backfill.
3. The creator-bound lifecycle state is `deleted`.
4. The exact shared zone is absent.
5. The private lock is unchanged immediately before conditional release.

An active marker plus revoked access does not release. Offline, permission, wrong-account, malformed-authority, wrong-owner, stale-household, and ambiguous-location results retain the lock and local read-only data. Released locks preserve the opaque claim and owner-authority evidence but cannot authorize recovery.

After an installed participant confirms both creator-authenticated `deleted` family authority and exact zone absence, it persists a generation-scoped unavailable-family receipt and conditionally releases only the matching lock. An exact creator-authenticated membership-revocation record, or exact journal revocation evidence while access remains, establishes the same route only for the lock's claim binding. The participant remains on a `Family No Longer Available` screen until confirming `Reset App`. Reset clears that household's ordinary local journal, profiles, invitation state, bindings, preferences, and caches, then returns to Welcome. A minimal completed-generation receipt remains so the same released private lock cannot make the cleaned installation enter recovery again. A new family or invitation uses a different membership generation. Revocation ambiguity, permission loss, validation failure, and offline failures never set it.

An empty-session active lock with the exact deterministic owner claim is classified separately from invited and legacy-shared memberships. If that owner lock predates `ownerAuthorityBinding`, the app derives a candidate authority only from the stable current CloudKit participant and the exact owner claim. Terminal cleanup still requires the lifecycle record creator and last modifier to match that candidate, the state to be `deleted`, exact no-location evidence, and the complete lock to remain unchanged. This is not a general backfill or migration.

If terminal deletion cannot be authenticated, a positively classified owner may explicitly release only that account's unchanged private lock after another exact no-location check. Owner self-release does not create or modify this lifecycle record and does not mean the family was deleted. It does not delete or recreate a zone, touch family facts, invitations, shares, or participants, release any other membership, grant recovery access, or produce the family-deleted notice. Invitation-bound, legacy-shared, revoked, archived, provisional, conflicting, wrong-account, changed-generation, and ambiguous-location states never receive this action.

## CloudKit schema and security

This change requires a human-reviewed Development schema update and later human promotion to Production. Agent work must not deploy it or modify Production data.

Configure `FamilyLifecycleAuthority` in the public database with only the two application fields above. Permit authenticated users to read and create. Permit updates only by the record creator. Do not enable public unauthenticated access. Lifecycle validation fetches the deterministic record ID directly. No application-field query index is required by the app.

The durable Production dependency is therefore the public `FamilyLifecycleAuthority` type, with `formatVersion` as Int64 and `state` as String. This repository documents and validates the contract but never deploys the schema.

Before a signed build is distributed, verify in CloudKit Console that the record type, field types, database scope, and creator-only write rules match this document. Promote through the existing authorized release process only after Development two-account deletion, revocation, reinstall, and account-switch checks pass. The observed Production deployment finding and captain procedure are in `docs/delete-all-earned-it-data-implementation-report.md`.

Relevant Apple contracts are [CKRecord creator metadata](https://developer.apple.com/documentation/cloudkit/ckrecord/creatoruserrecordid), [CKRecord last-modifier metadata](https://developer.apple.com/documentation/cloudkit/ckrecord/lastmodifieduserrecordid), and [record-zone deletion change reporting](https://developer.apple.com/documentation/cloudkit/ckfetchdatabasechangesoperation/recordzonewithidwasdeletedblock).

# Family lifecycle authority

## Why it exists

A child must not treat loss of a shared CloudKit zone as proof that the owner deleted the family. The same visible absence can follow participant removal or revocation. CloudKit's database-change deletion callback reports the removed zone identity, not an application-level reason for loss. A durable owner-authenticated authority outside the deleted zone is therefore required before the app may release a child's active account membership lock.

The authority is correctness state, not a diagnostic receipt. Diagnostic collection remains read-only and does not create or modify it.

## Record contract

The record is stored in the public database so an authenticated former participant can fetch it after the shared zone is gone.

- Record type: `FamilyLifecycleAuthority`
- Record name: SHA-256 of a domain-separated household UUID. The UUID is never stored as a field.
- `formatVersion`: Int64, currently `1`
- `state`: String, one of `active`, `deleting`, or `deleted`
- System metadata: `creatorUserRecordID` and `lastModifiedUserRecordID`

There are no family names, member names, invitation values, URLs, codes, digests, zone names, participant identifiers, payloads, or journal facts in the record. The private `AccountMembershipLock` payload gains only an optional opaque hash of the exact owner participant. That is an existing Bytes payload and does not add an `AccountMembershipLock` schema field.

CloudKit can represent the current user in creator and modifier metadata in two equivalent forms. The app accepts each identity independently when it is either the exact unique record name returned for the current account or the exact well-formed current-user sentinel. A well-formed sentinel has record name `CKCurrentUserDefaultName`, the default record-zone name, and zone owner `CKCurrentUserDefaultName`. A missing identity, a foreign unique name, or a sentinel with another zone name or owner fails closed. Only an accepted representation is hashed into the owner-authority binding retained in the exact private lock. The current account and account generation are checked around every mutation.

After a lifecycle mutation, the app validates the server-returned saved record directly. It requires the exact requested record ID and lifecycle state plus the same creator and last-modifier ownership checks. It does not depend on a second immediate fetch to confirm a write that CloudKit has already returned.

## State transitions

`active` is created during owner bootstrap or backfilled while recovering an accessible owner family. It can move only to `deleting`. `deleting` can move only to `deleted`. No path returns a record to `active`.

Owner deletion persists local pending state before publishing `deleting`, deletes the exact owner zone, publishes `deleted`, conditionally releases the exact owner lock, and then purges that household's local data. Repeating any completed phase is safe.

A child releases an active lock only when all of these conditions hold:

1. Household, attempt, current participant, and account generation still match.
2. The lock contains the exact owner-authority binding, or an installed exact location supplies it for legacy backfill.
3. The creator-bound lifecycle state is `deleted`.
4. The exact shared zone is absent.
5. The private lock is unchanged immediately before conditional release.

An active marker plus revoked access does not release. Offline, permission, wrong-account, malformed-authority, wrong-owner, stale-household, and ambiguous-location results retain the lock and local read-only data. Released locks preserve the opaque claim and owner-authority evidence but cannot authorize recovery.

After an installed participant confirms both creator-authenticated `deleted` authority and exact zone absence, it conditionally releases only the matching lock, purges only that household's local journal and session cache, and returns to normal onboarding. A local identifier-free pending or acknowledged notice state makes `Family data was deleted` one-shot across relaunches. This small local UX receipt is required for the explicit terminal message; it carries no household, account, participant, or CloudKit value and is reset to pending only by another confirmed deletion. Revocation, permission loss, and offline failures never set it.

An empty-session active lock with the exact deterministic owner claim is classified separately from invited and legacy-shared memberships. If that owner lock predates `ownerAuthorityBinding`, the app derives a candidate authority only from the stable current CloudKit participant and the exact owner claim. Terminal cleanup still requires the lifecycle record creator and last modifier to match that candidate, the state to be `deleted`, exact no-location evidence, and the complete lock to remain unchanged. This is not a general backfill or migration.

If terminal deletion cannot be authenticated, a positively classified owner may explicitly release only that account's unchanged private lock after another exact no-location check. Owner self-release does not create or modify this lifecycle record and does not mean the family was deleted. It does not delete or recreate a zone, touch family facts, invitations, shares, or participants, release any other membership, grant recovery access, or produce the family-deleted notice. Invitation-bound, legacy-shared, revoked, archived, provisional, conflicting, wrong-account, changed-generation, and ambiguous-location states never receive this action.

## CloudKit schema and security

This change requires a human-reviewed Development schema update and later human promotion to Production. Agent work must not deploy it or modify Production data.

Configure `FamilyLifecycleAuthority` in the public database with only the two application fields above. Permit authenticated users to read and create. Permit updates and deletion only by the record creator. Do not enable public unauthenticated access. Normal lifecycle validation fetches the deterministic record ID directly. Account-wide deletion also queries the CloudKit system creator field so it can find stale records for households absent from the device. Make `creatorUserRecordID` queryable. No application-field query index is required.

The durable Production dependency is therefore the public `FamilyLifecycleAuthority` type, `formatVersion` as Int64, `state` as String, and a queryable system `creatorUserRecordID` metadata field. This repository documents and validates the contract but never deploys the schema.

Before a signed build is distributed, verify in CloudKit Console that the record type, field types, database scope, creator query index, and creator-only write and delete rules match this document. Promote through the existing authorized release process only after Development two-account deletion, revocation, reinstall, and account-switch checks pass. The observed Production deployment finding and captain procedure are in `docs/delete-all-earned-it-data-implementation-report.md`.

Relevant Apple contracts are [CKRecord creator metadata](https://developer.apple.com/documentation/cloudkit/ckrecord/creatoruserrecordid), [CKRecord last-modifier metadata](https://developer.apple.com/documentation/cloudkit/ckrecord/lastmodifieduserrecordid), and [record-zone deletion change reporting](https://developer.apple.com/documentation/cloudkit/ckfetchdatabasechangesoperation/recordzonewithidwasdeletedblock).

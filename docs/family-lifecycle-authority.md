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

The app accepts a lifecycle record only when both CloudKit system identities hash to the owner-authority binding retained in the exact private lock. The current account and account generation are checked around every mutation. A mismatched, malformed, or missing record fails closed.

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

## CloudKit schema and security

This change requires a human-reviewed Development schema update and later human promotion to Production. Agent work must not deploy it or modify Production data.

Configure `FamilyLifecycleAuthority` in the public database with only the two application fields above. Permit authenticated users to read and create. Permit updates only by the record creator. Do not enable public unauthenticated writes. No custom query index is required because the app fetches the deterministic record ID directly.

Before a signed build is distributed, verify in CloudKit Console that the record type, field types, database scope, and creator-only write rule match this document. Promote through the existing authorized release process only after Development two-account deletion, revocation, reinstall, and account-switch checks pass.

Relevant Apple contracts are [CKRecord creator metadata](https://developer.apple.com/documentation/cloudkit/ckrecord/creatoruserrecordid), [CKRecord last-modifier metadata](https://developer.apple.com/documentation/cloudkit/ckrecord/lastmodifieduserrecordid), and [record-zone deletion change reporting](https://developer.apple.com/documentation/cloudkit/ckfetchdatabasechangesoperation/recordzonewithidwasdeletedblock).

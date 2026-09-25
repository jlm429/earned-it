# Production boundaries

Read the repository sources first:

- `docs/family-lifecycle-authority.md` owns the lifecycle schema and deletion authority contract.
- `docs/family-transition-diagnostics.md` owns the privacy-safe trace contract.
- `docs/shared-household-architecture.md` owns invitation, membership, deletion, and synchronization invariants.
- `CloudKitHouseholdTransport.swift` owns native CloudKit representation checks.
- `HouseholdStore.swift` owns product authorization, lifecycle sequencing, claim, cleanup, and local attach.

## Lifecycle schema and identity

`FamilyLifecycleAuthority` is in the public database. Its application fields are exactly `formatVersion: Int64` and `state: String`. The CloudKit system `creatorUserRecordID` metadata must be queryable because account-wide deletion discovers authorities absent from the device. No application-field query or sort index is required.

CloudKit may return creator and modifier metadata as either the fetched current user's unique record name or the exact current-user sentinel. The sentinel is well formed only when:

- record name is `CKCurrentUserDefaultName`;
- zone name is `CKRecordZone.ID.default.zoneName`;
- zone owner is `CKCurrentUserDefaultName`.

Validate creator and modifier independently. Accept each only as the exact unique current-user name or that exact sentinel. Reject a missing identity, a sentinel in another zone, a sentinel with another zone owner, or any foreign record name. Hash only an accepted identity representation into the retained owner-authority binding.

## Permanent deletion and restart

Permanent Delete Family is creator-only. It persists pending intent, publishes `deleting`, deletes the exact owner zone, publishes `deleted`, conditionally releases the unchanged exact owner membership lock, and then purges only that household locally. Each phase is idempotent. A failure retains enough state to retry and must not report success.

A child may release its lock and purge locally only after creator-authenticated `deleted` authority and exact zone absence. Revocation, access loss, offline state, a missing or malformed authority, or `active` or `deleting` state is not deletion proof.

After terminal cleanup, fresh family creation must use new household, zone, lock attempt, and lifecycle identities. Old facts, pending invitation state, locks, or deletion receipts must not attach to the replacement.

## Invitation side effects and recovery

Participant creation, invitation-fact persistence, upload, and presentation are separate effects. A later failure must not cause blind participant recreation. Recovery is valid only for the exact pending private read/write participant and only when the recovered URL digest matches the persisted digest.

Do not start an ordinary delayed sync for an invitation fact that the foreground invitation operation uploads itself. Otherwise the timer can cross the foreground await, race the same mutation, and surface a global pending-changes error after durable invitation effects exist.

For recipients, a custom `earnedit-invitation://join` package proves the code and URL digests together. A raw Apple URL has no recoverable clear code, so it must bind through the current accepted participant to exactly one persisted invitation and use that invitation's digest for the atomic claim. In both paths, revalidate household, member, role, revocation, authoritative expiry, write access, one-time claim absence, and account membership lock before attaching the exact profile.

## Privacy-safe diagnostics

Allow-list categorical fields only: stage, outcome, lifecycle state, lock state, known/unknown booleans, equality results, counts, CloudKit error codes and source, bounded retry timing, and account-generation stability.

Never include invitation codes, raw URLs, URL or code digests, CloudKit record names, user record names, participant IDs, zone names, family or member names, payloads, facts, attempt IDs, credentials, or opaque bindings. A Copy Diagnostics action belongs at a specific recoverable failure surface, not in routine production UI.

Capture the first failing trace before retry, refresh, relaunch, or cleanup changes the state. A later error is secondary unless the staged trace shows it was the first failed boundary.

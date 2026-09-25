# Production boundaries

Read the repository sources first:

- `docs/family-lifecycle-authority.md` owns the lifecycle schema and deletion authority contract.
- `docs/family-transition-diagnostics.md` owns the privacy-safe trace contract.
- `docs/shared-household-architecture.md` owns invitation, membership, deletion, and synchronization invariants.
- `CloudKitHouseholdTransport.swift` owns native CloudKit representation checks.
- `HouseholdStore.swift` owns product authorization, lifecycle sequencing, claim, cleanup, and local attach.

## Lifecycle schema and identity

`FamilyLifecycleAuthority` is in the public database. Its application fields are exactly `formatVersion: Int64` and `state: String`. The CloudKit system `creatorUserRecordID` metadata must be queryable because account-wide deletion discovers authorities absent from the device. No application-field query or sort index is required.

CloudKit may return creator and modifier metadata as either a stable unique record name or the exact current-user sentinel. A stable unique name is accepted through the retained owner-authority binding, including when a non-owner reader observes owner deletion. The sentinel is accepted only when the current reader derives that same owner binding and its shape is well formed:

- record name is `CKCurrentUserDefaultName`;
- zone name is `CKRecordZone.ID.default.zoneName`;
- zone owner is `CKCurrentUserDefaultName`.

Validate creator and modifier independently. Reject a missing identity, a unique name with another owner binding, a sentinel read by a non-owner, a sentinel in another zone, or a sentinel with another zone owner.

Account-wide reset queries lifecycle creator metadata under both the resolved current-user record ID and the exact sentinel. Discovery and deletion pass every result through the same sentinel-shape and owner-binding validator, so Production sentinel representation cannot hide an owned authority and a malformed sentinel cannot broaden deletion.

## Permanent deletion and restart

Permanent Delete Family is creator-only. It persists pending intent, publishes `deleting`, deletes the exact owner zone, publishes `deleted`, conditionally releases the unchanged exact owner membership lock, and then purges only that household locally. Each phase is idempotent. A failure retains enough state to retry and must not report success.

A child may release its lock and purge locally only after creator-authenticated `deleted` authority and exact zone absence. Revocation, access loss, offline state, a missing or malformed authority, or `active` or `deleting` state is not deletion proof.

After terminal cleanup, fresh family creation must use new household, zone, lock attempt, and lifecycle identities. Old facts, pending invitation state, locks, or deletion receipts must not attach to the replacement.

## Invitation side effects and recovery

Participant creation, invitation-fact persistence, upload, and presentation are separate effects. A later failure must not cause blind participant recreation. Recovery is valid only for the exact pending private read/write participant and only when the recovered URL digest matches the persisted digest.

Cancel an already queued delayed sync when foreground invitation issuance or recovery takes its exclusive mutation boundary, and do not start another delayed sync for an invitation fact that the foreground operation uploads itself. If the canceled task owned pending facts that remain when the exclusive operation exits, schedule their retry. Otherwise a timer can cross a foreground await and surface a global pending-changes error, or cancellation can strand offline work.

Recover an existing invitation only when its row retains a participant ID and valid URL digest and server-authoritative validation time confirms it is still unclaimed, unrevoked, and unexpired. Local clock status must not hide the recovery action or authorize delivery. Recovery presents the stored original expiration and never promises a fresh 24-hour lifetime.

For recipients, a custom `earnedit-invitation://join` package proves the code and URL digests together. A raw Apple URL has no recoverable clear code, so it must read and validate the current accepted participant once, uniquely match that participant ID to one persisted invitation, and use that invitation's digest for the atomic claim before any membership resume or attachment. A same-household membership for another invitation is a conflict, not a recovery shortcut. Before native raw acceptance, capture the exact share-access state and reject preexisting accepted access or an active membership lock. If native acceptance reports a retryable error, continue only when the persisted attempt began without access and the new exact participant uniquely matches one invitation. Probe a persisted accepting attempt before replay, and retain retryable pending state without replay or cleanup when the result cannot be established. Once pending state records an invitation ID, later participant discovery cannot replace it. In both paths, revalidate household, member, role, revocation, authoritative expiry, write access, one-time claim absence, and account membership lock before attaching the exact profile. Submit the atomic claim only while the authenticated participant, account generation, and exact accepted private read/write invitation participant still match. New claims, existing claims, cleanup, resume, retry, and startup recovery must revalidate that the committed membership's invitation participant is still the exact current accepted private read/write participant after all awaited lock work and immediately before synchronous local attachment. When pending state identifies an invitation, that committed membership must identify the same invitation. Pending acceptance blocks ordinary onboarding and family creation, and cleanup or recovery revalidates the unchanged empty or exact continuing-import session before clearing or attaching local state.

Existing-invitation recovery is an owner participant-management action. Non-owner parents do not see the action, even though their app role still permits ordinary family management.

## Privacy-safe diagnostics

Allow-list categorical fields only: stage, outcome, lifecycle state, lock state, known/unknown booleans, equality results, counts, CloudKit error codes and source, bounded retry timing, and account-generation stability.

Never include invitation codes, raw URLs, URL or code digests, CloudKit record names, user record names, participant IDs, zone names, family or member names, payloads, facts, attempt IDs, credentials, or opaque bindings. A Copy Diagnostics action belongs at a specific recoverable failure surface, not in routine production UI.

Capture the first failing trace before retry, refresh, relaunch, or cleanup changes the state. A later error is secondary unless the staged trace shows it was the first failed boundary.

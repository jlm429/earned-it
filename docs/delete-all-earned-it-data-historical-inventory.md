# Delete All Earned It Data Historical Inventory

## Scope and evidence

This inventory covers every artifact found in the complete Git history reachable at the September 24, 2026 baseline `b7581d1`. That history contains 166 commits, from `fb1391e` through `b7581d1`. The review included current source, entitlements, architecture and release documentation, migrations, unit and UI tests, and deleted source at each historical revision.

The history review used these reproducible checks:

- `git rev-list --all` and the full chronological `git log --all --reverse`;
- a per-commit `git grep` for `CKRecord`, record type strings, record names, zone names, `CKShare`, SwiftData models, store paths, preferences, files, caches, receipts, and migration code;
- `git log -S` and `git log -G` to locate introductions, removals, and renames;
- direct inspection of the relevant deleted files at `4f933fc`, `636907e`, `1c12a8d`, `b0b1a75`, `59f3c67`, `64ab9a8`, `5508363`, `e40ac06`, and the baseline.

Current authoritative evidence is in:

- `Configuration/EarnedIt.entitlements` for the CloudKit container and environment selection;
- `EarnedIt/Services/CloudKitHouseholdTransport.swift` for databases, zones, record encodings, shares, and account checks;
- `EarnedIt/Services/HouseholdTransport.swift` and `EarnedIt/Services/InvitationService.swift` for lock and lifecycle identities;
- `EarnedIt/Models/Household.swift` for every journal fact body;
- `EarnedIt/Models/FactJournal.swift` and `EarnedIt/Services/HouseholdRepository.swift` for current local persistence;
- `docs/shared-household-architecture.md` and the production evidence packages under `docs/` for security and recovery behavior;
- `EarnedItTests/TestSupport.swift`, `EarnedItTests/InvitationTests.swift`, and `EarnedItTests/ProductionCleanupTests.swift` for executable historical and failure-state coverage.

The only configured CloudKit container is `iCloud.com.jlm429.EarnedIt`. Its environment is selected by `$(ICLOUD_CONTAINER_ENVIRONMENT)`. SwiftData CloudKit mirroring is disabled with `.none`. No custom backend, second iCloud container, public invitation-code registry, keychain store, or ubiquitous file container was found.

## CloudKit private default zone

The following table distinguishes actual historical records from concepts that never had their own record.

| Artifact | Historical forms and evidence | Reset treatment |
| --- | --- | --- |
| `AccountMembershipLock` | Introduced at `b0b1a75`. The record name has always been deterministic `current-membership` in `_defaultZone`. The CloudKit envelope uses `formatVersion = 1` and a `payload` byte field. The first payload stored household ID, attempt nonce, state, expiry, and optional invitation ID, member ID, and role. At `59f3c67`, the invitation fields became an opaque `claimBinding`. At `e40ac06`, optional `ownerAuthorityBinding` was added. Unknown removed fields remain harmless to the current Codable decoder. | Fetch the exact record ID, verify the record type, and delete it. Exact not-found is success. |
| Lock states | Every lock generation can be `provisional`, `active`, or `released`. A released lock remains a real record with its prior evidence and must be deleted. Owner, invited parent, child, expired lease, recovery, replacement, and stale-owner flows all use this same record type and name. | Deleting the record removes every state and payload version without interpreting its authority. |
| `AccountMembershipValidationTime` | Introduced at `5508363`. It is a temporary record with a server-generated record name in the current account's private `_defaultZone`. The app normally deletes it after reading the server modification date. A crash or failed best-effort delete can leave any number of records. | Query every record of the exact type in `_defaultZone`, then delete each exact ID. |
| `InvitationValidationTime` | Introduced at `64ab9a8`. Historical source creates it in the household custom zone through the owner private or participant shared database, not in `_defaultZone`, and normally deletes it immediately. The reset also defensively queries this exact type in the private default zone so an experimental or interrupted build cannot leave it behind there. | Owner zone deletion removes private-zone remnants. Participant share relinquishment removes access to shared-zone remnants. Any defensive `_defaultZone` matches are individually deleted. |
| Account generation | Added as an in-memory counter on `CloudKitHouseholdTransport` at `50f176c`. It changes on `CKAccountChanged` and has never been a CloudKit record. | The reset captures and rechecks the value. There is no generation record to delete. |
| Account switch state | CloudKit account notifications, current `participantID`, and the in-memory generation implement switching. No `AccountSwitch`, account identity, account-generation, or similar record type was found in any commit. | No cloud artifact exists. Local routing state is cleared with `DeviceSession`. |
| Membership recovery state | Recovery reads `current-membership` and household facts. There has never been a distinct recovery record type. | Delete the lock, relevant zones or participation, journal, and local recovery fields. |
| Security and recovery receipts | `LastJoinReceipt`, invitation diagnostics, pending cleanup phases, and family-deletion notice state are local. No receipt record type was found in private CloudKit. | Clear with local state after cloud cleanup. |

The complete-history record-type scan found no other Earned It type in the private default zone. In particular, no historical `Account`, `AccountGeneration`, `AccountSwitch`, `MembershipRecovery`, `SecurityReceipt`, `RecoveryReceipt`, or profile record type exists.

## Owner private custom zones

Every historical synced household uses a custom zone named exactly `EarnedIt-<UUID>`. The UUID is the stable household ID. Prefix-only names, malformed UUID suffixes, and other custom zones are not unambiguously owned by Earned It and are outside the deletion boundary.

### Record types

| Record type | Identity and fields | Historical contents |
| --- | --- | --- |
| `HouseholdFact` | Introduced with sharing at `1c12a8d`. Record name is the stable fact UUID. Fields are `formatVersion = 1` and JSON `payload` bytes. Every semantic object below is a case inside this one record type, not a separate CloudKit type. | Household configuration and setup; member and profile definitions, roles, avatars, activation and archive dates; chore or responsibility revisions; dated completions and reversals; occurrence activation and disposition; alternating-turn advances; permanent chore deletions; allowance revisions; excuses; legacy profile requests and grants; family invitations; exact invitation claims; and invitation revocations. |
| `InvitationValidationTime` | A temporary record with a server-generated record name and no app fields. | Server-time validation during invitation issue or redemption. A crash can leave a remnant. |
| `CKShare` | The system zone-wide share uses record name `CKRecordNameZoneWideShare`. | Share metadata, owner, current and stale participant entries, participant status and permission, and Apple invitation metadata. Private invitations use read/write transport permission. App role permissions remain separate client checks. |

The current `HouseholdFactBody` cases are the historical superset:

1. `household`
2. `member`
3. `chore`
4. `completion`
5. `occurrence`
6. `alternatingTurnAdvance`
7. `choreDeletion`
8. `allowance`
9. `excuse`
10. `request`
11. `grant`
12. `invitation`
13. `invitationClaim`
14. `invitationRevocation`

Invitation generations are represented by new invitation identities plus their deterministic claim and revocation facts. Chore generations are immutable chore revisions and dated transition facts. Household deletion generations use the public lifecycle record described below. There has never been a separate cloud record type named `Family`, `Profile`, `Member`, `Responsibility`, `Chore`, `Completion`, `Allowance`, `Journal`, `Invitation`, `InvitationClaim`, `InvitationRevocation`, `Generation`, or `Revocation`.

Complete-history inspection found no renamed or removed Earned It CloudKit record type. New fact cases were added inside `HouseholdFact`, and the lock payload evolved inside `AccountMembershipLock`. The zone prefix remained `EarnedIt-` throughout the CloudKit implementation.

Deleting an owned custom zone is the authoritative cleanup for every record in it, including unknown future-compatible fact payloads, temporary validation records, the zone-wide `CKShare`, and its participant list. The reset enumerates all exact Earned It zones in the current account's private database. It does not rely on the one household cached by the current installation.

## Public database

`FamilyLifecycleAuthority` is the only public Earned It record type found in history. It was introduced at `e40ac06`.

- The record name is `SHA256("family-lifecycle|<household UUID>")`.
- App fields are `formatVersion` as Int64 and `state` as String.
- Recognized states are `active`, `deleting`, and `deleted`.
- CloudKit system fields identify the creator and last modifier. The app binds those identities to the owner account through an opaque digest.
- The record is fetched directly for normal lifecycle validation. Account-wide reset queries records whose `creatorUserRecordID` is the current participant and verifies the creator again before deletion.

No other historical public record type was found. Invitation codes, invitations, member identities, household facts, account locks, validation records, and recovery receipts were never stored in the public database.

## Shared and participant state

An invited account sees an owner's exact `EarnedIt-<UUID>` zone through its CloudKit shared database. The shared view includes `HouseholdFact` records, any temporary `InvitationValidationTime` remnant, the zone-wide `CKShare`, the current participant, and Apple share and invitation metadata.

A participant does not own the zone. CloudKit permits the participant to delete the shared-database `CKShare` reference to leave the share, which relinquishes that account's access. Exact not-found, missing-zone, or already-withdrawn permission is the same postcondition. The participant cannot directly delete the owner's private record zone, the owner-side `CKShare`, another participant entry, or records that remain in the owner's zone after access is relinquished. The owner must remove stale owner-side participant metadata or delete the zone. Account-wide reset never describes participant cleanup as deletion of another account's family.

Apple documents this participant boundary in [Shared Records](https://developer.apple.com/documentation/cloudkit/shared-records): deleting the share record from the participant's shared database leaves the share, while the owner's zone and the share for other participants remain.

Apple may retain service-level share acceptance, audit, backup, or diagnostic material according to its own CloudKit policies. Earned It has no API to enumerate or erase that service-managed material. The app removes every shared zone reference it can see and then verifies that no exact Earned It shared zone remains visible.

## Local persistence and process state

### Released and beta application stores

| Era | Store and models | Data represented |
| --- | --- | --- |
| `4f933fc` through `636907e` | SwiftData's implicit default store, normally `default.store`, with `-wal`, `-shm`, and support artifacts. Models were `AppSetting`, `DailyRecord`, `ExcusedDay`, `FamilyUser`, and `Responsibility`. | Setup completion and sample/live mode, people and roles, responsibilities, daily outcomes, excuses, allowance and scoring inputs. This predates CloudKit sharing and is incompatible with the journal schema. |
| `636907e` debug UI tests | Documents `isolated-ui-tests.store` and sidecars. | The same pre-journal models under an isolated UI-test launch. |
| `1c12a8d` to current | Application Support `shared-household-v1.store`, `shared-household-v1.store-wal`, `shared-household-v1.store-shm`, and `shared-household-v1.store_SUPPORT`. Debug UI tests use the same artifact forms for Documents `shared-household-ui-tests.store`. Models are `StoredFact` and `StoredSession`. SwiftData CloudKit mirroring is explicitly disabled. | The complete local household journal, upload and rejection state, and the encoded device session. |

Unit tests have also created temporary `shared-household.store`, `household-test-<UUID>`, `reset-test-<UUID>`, `membership-recovery-<UUID>`, and UUID-named stores under the XCTest temporary directory. Test teardown owns those paths. A production installation cannot safely guess or delete external XCTest temporary paths.

### Current journal and session inventory

`StoredFact` contains the fact ID, household ID, encoded `HouseholdFact`, uploaded flag, and optional rejection reason. It therefore caches the complete family, member, profile, chore, completion, allowance, history-source, invitation, claim, revocation, generation, and legacy request or grant state.

`StoredSession` uses key `device` and encodes `DeviceSession`, including:

- device, household, selected-profile, and CloudKit participant identifiers;
- owner or shared zone location and cached write permission;
- celebrated-week receipts and legacy profile IDs;
- pending invitation acceptance phase, location, participant, retained facts, lock attempt, invitation ID, expiry, and access history;
- pending invitation package digest, URL, participant, and Apple-verification flag;
- membership-lock attempt and claim binding;
- `LastJoinReceipt` recovery and refusal evidence;
- family-access-lost, pending family deletion, and family-deletion notice state;
- the new durable account-reset participant binding, remaining target list, and verification progress.

Other local state includes in-memory household projections, cached profiles, rejected writes, sync status, recovery flags, pending tasks, and invitation diagnostics. `FamilyTransitionDiagnostics` holds an in-memory event buffer and latest sanitized trace. It also writes allow-listed comparison results to Apple's unified logging system. Reset clears the in-process buffer. iOS owns unified log retention, and an app sandbox has no supported API to delete selected historical unified-log entries.

No historical source used `UserDefaults`, `@AppStorage`, Keychain, `SecItem`, an app-group container, or iCloud documents. Account-wide reset nevertheless removes the app's bundle-scoped UserDefaults persistent domain to cover system-created preferences and any tested build. It clears the app sandbox cache directory. It does not guess paths outside the app container.

## Deletion coverage map

| Boundary | What account-wide reset removes |
| --- | --- |
| Owner private database | Every exact `EarnedIt-<UUID>` custom zone and all contents, shares, and participants. |
| Current account private default zone | Exact `current-membership` after type verification, every queried validation-time record, and any defensive historical exact-type match. |
| Public database | Every `FamilyLifecycleAuthority` created by the current participant where CloudKit authorizes deletion. |
| Participant shared database | Every exact Earned It shared-zone participation visible to the current account, by relinquishing access through the zone-wide share reference. |
| Current local store | Every `StoredFact` and `StoredSession`, replaced atomically by one clean session only after cloud verification. |
| Historical local stores | Known incompatible and UI-test stores plus SQLite sidecars and support directories inside the app container. |
| Other local state | Bundle-scoped preferences, app cache contents, in-memory projections, receipts, invitation and recovery state, identifiers, and diagnostic buffers. |

This boundary deliberately does not delete malformed prefix-only zones, unrelated custom zones, another account's private records, another owner's household zone, another participant's private lock, Production schema, container configuration, or Apple-managed service records that CloudKit does not expose to the current account.

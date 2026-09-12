# Earned It

A native iPhone app that helps parents see what their children did without asking or nagging.

## A shared view of the day

One family has one recurring chore list for each weekday, Sunday through Saturday. Every member uses those same lists. A Monday chore returns next Monday with no completions carried forward.

A chore can belong to all children, one child, or selected children who alternate turns. Each alternating date has one owner, and the turn advances with the schedule even when the prior occurrence was not completed. Children see an alternating chore only on their turn; parents see whose turn it is. If synchronization leaves a recorded contribution from an earlier assignment, parents see it as view-only assignment history; it does not assign, score, or grant controls to that child under the current turn. Older any-one and multiple-child chores continue to load without migration. Their assignments stay intact during unrelated edits unless a parent deliberately converts them to a current choice. Each child records their own Done or Not Needed Today entry. Parents see expected people, completed people, and who remains directly on the daily list. Tap a child’s name to mark Done or undo it directly. Touch and hold for Not Needed Today and other dated states. Each change affects only that person’s contribution for that date; children can change only their own entries.

## Create or join a family

First run offers two role-aware paths. Choose **Create a New Family** when you are the first parent, enter the family and parent names, then add children. The creator is the approved parent for that installation. Children can exist before they have a device. Configure the seven weekday lists during setup or later. Saved setup survives closing the app.

Choose **Join an Existing Family** when an approved parent has created an invitation. Enter its ten-character code and Apple invitation link, scan its QR code, or open the private Apple invitation first and then enter the code. The app imports the existing household instead of creating another local family.

From **Family & Sharing**, an approved parent chooses a parent invitation or an exact existing child profile. A parent invitation creates and binds the new parent profile before anything is sent. A child invitation opens only that child and cannot switch to a sibling or parent. Invitations use Apple’s private one-time CloudKit participants, expire after 24 hours, and are atomically claimed once. The journal stores only a SHA-256 digest of the human-enterable code. Revocation removes both app profile access and the associated Apple share participant when the current parent has permission to manage the share.

The household’s iCloud owner creates and revokes private participants on every supported iOS version. Parent and child invitations remain private-user participants so invited parents keep read/write household access across iOS 18 and later. Non-owner parents retain full app-level family management, while Apple participant management stays owner-only. All new participants use a role-bound parent or exact-child invitation; the app does not expose generic participant creation. Failed redemption removes Apple access only when that attempt newly granted it, preserving account-level access already used by another authorized installation. Existing profile grants from older Earned It releases remain valid. An older owner-account installation retains only its previously selected profile, not blanket access to every family member. An iCloud account, installation, and family member remain separate identities.

The app keeps a local SwiftData journal and exchanges its facts through CloudKit private/shared databases. Foreground, local changes, and manual refresh trigger sync. There is no custom backend or push notification dependency. Offline changes are retained for retry. Synchronization is eventual, not instantaneous.

Update all participating installations to the weekly allowance version before sharing allowance changes. Earlier app versions cannot read the new allowance facts.

**Trust boundary:** CloudKit read/write participants can modify or delete any records in a share. App parent/child restrictions are centralized client checks, not server-enforced protection against a modified client. Invite only trusted family participants.

## Progress, streaks, and allowance

Weeks run Monday through Sunday in the family timezone. Every required item must be Done or Not Needed to earn allowance after Sunday. A complete state has a checkmark; unfinished work has a yellow warning with text and dated missing items. Future items are labeled as scheduled and do not count as missed. Empty weeks and optional-only weeks never earn allowance.

Parents open a child’s weekly detail and choose **Edit Weekly Allowance** to set an independent amount and currency. Amounts use integer currency minor units, support currency-specific decimal places, and can be left unset. Edits apply to the current week and future weeks; finished weeks retain their earlier amount. This tracks eligibility only, never payments or transfers.

Weekly history shows the current week and up to 12 finished weeks, labeled **Week of** with a date range. Summaries derive from retained chore revisions, membership, completions, excuses, and allowance revisions, so parent corrections update history after relaunch and sync. The summary window is bounded without deleting source journal records.

Children can mark their own items on the scheduled day and the following calendar day. At the start of the second following day, only parents can correct that date. Sunday items therefore remain available to children through Monday in the family timezone. **Finish yesterday’s items** and the dated weekly item links provide access.

A finished week with every required item accounted for earns an **Earned It** badge. **Way to go!** appears once per child and finished week on an installation, with a persisted local presentation receipt. A finished week with missing items instead offers **Check in with your parent**. The fresh current week stays first, and parent corrections update the previous result.

- Required chores count once for each required child. Only that child’s own Done or Not Needed Today state earns credit.
- Alternating chores count once for the child who owns that date. Completion never moves a later turn.
- Any-one chores are optional individual contributions. A contributor gets one accounted item and one expected item; other eligible children get neither credit nor a penalty.
- Excused days are excluded. They neither extend nor break streaks. Days without scored chores are also neutral.
- Past unmarked obligations derive Missed, with a one-day child completion grace period. Parents can correct dated entries and excuse days.

For example, if Hanna and Alek must both water plants and Hanna finishes, Hanna has 1/1 and Alek has 0/1. If watering plants is any-one, Hanna has 1/1 and Alek has no scored item. Alek does not get Hanna’s credit and is not penalized for leaving a finished shared chore alone.

## Dates and history

The family’s Gregorian timezone is fixed when created. Traveling devices keep the same family dates. New chores start today. New children join currently applicable all-children chores immediately, including today. Their persisted join date is the current family date, so earlier dates gain no obligations. Chore edits, archives, and new parent profiles after setup still start tomorrow. Existing dated contributions stay intact. History remains available after configuration changes or member archival.

This preproduction refactor uses a new named store, `shared-household-v1.store`. Old beta stores are left untouched; their incompatible per-child data is not migrated or automatically deleted. Production never seeds sample families. Settings requires confirmation to remove local data. Disconnecting a shared installation does not delete CloudKit or other devices’ data and requires pending changes to sync first.

## Development and verification

Use the selected full Xcode installation and a task-isolated iPhone Simulator:

```sh
xcodebuild test -project EarnedIt.xcodeproj -scheme EarnedIt \
  -destination 'platform=iOS Simulator,id=<isolated-simulator-uuid>' \
  -derivedDataPath .artifacts/DerivedData \
  -resultBundlePath .artifacts/tests.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Debug UI tests use a separate store and explicit reset flags. The weekly flow additionally uses `--ui-test-weekly-fixture` and a controllable family clock; these fixtures cannot run against the actual store and are excluded from Release builds. Unsigned Simulator builds do not activate CloudKit. Domain tests inject an in-memory transport server to verify shared identity, profile approval, convergence, retries, and credit. These tests are not live iCloud verification.

Physical-device sharing requires an Apple development team with the iCloud capability and the container declared in `Configuration/EarnedIt.entitlements`. Provision `iCloud.com.jlm429.EarnedIt` for the app’s bundle ID. The explicit CloudKit schema remains `HouseholdFact` with `payload` (Bytes) and `formatVersion` (Int64), plus the system CKShare record. Invitation issuance, revocation, and claims are typed facts in that same household zone, not a public lookup service or parallel synchronization system. Development saves can create the development schema. Production schema deployment is a separate, deliberate release action. The app never initializes or promotes production schema automatically.

Before distribution, validate parent and child one-time invitation delivery, cold and warm acceptance, code and QR redemption, two-device completions, relaunch, owner-only participant management across supported iOS versions, account changes, read-only access, and share revocation with two signed devices and two iCloud accounts. No live signing, provisioning, or production schema mutation is performed by local tests.

See [architecture decisions and Apple sources](docs/shared-household-architecture.md) and [agent guidance](AGENTS.md).

## Privacy

Family data stays in the installation’s local store and, when connected, the owner’s private CloudKit zone shared only through invited access. There are no ads, analytics, third-party services, or AI features.

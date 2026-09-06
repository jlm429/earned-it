# Earned It

A native iPhone app that helps parents see what their children did without asking or nagging.

## A shared view of the day

One family has one recurring chore list for each weekday, Sunday through Saturday. Every member uses those same lists. A Monday chore returns next Monday with no completions carried forward.

A chore can require one child, any one eligible child, specific children, or all children. Each child records their own Done or Not Needed Today entry. Parents see expected people, completed people, and who remains directly on the daily list. Tap a child’s name to mark Done or undo it directly. Touch and hold for Not Needed Today and other dated states. Each change affects only that person’s contribution for that date; children can change only their own entries.

## Create or join a family

Choose **Create Family**, enter a family name and parent name, then add children. Children can exist before they have a device. Configure the seven weekday lists during setup or later. Saved setup survives closing the app.

From **Family & Sharing**, connect to iCloud and use **Invite or Manage Sharing** to send a private Apple invitation. On another device, open that invitation or choose **Join Existing Family** and paste its link. **Find Connected Families** also finds families already connected to the current iCloud account.

An invited installation requests its preexisting family profiles. A parent reviews and approves those profiles. One installation can use multiple profiles, and one child can use multiple installations. An installation connected as the family’s iCloud owner can select any family profile. An iCloud account is not a family member.

The app keeps a local SwiftData journal and exchanges its facts through CloudKit private/shared databases. Foreground, local changes, and manual refresh trigger sync. There is no custom backend or push notification dependency. Offline changes are retained for retry. Synchronization is eventual, not instantaneous.

**Trust boundary:** CloudKit read/write participants can modify or delete any records in a share. App parent/child restrictions are centralized client checks, not server-enforced protection against a modified client. Invite only trusted family participants.

## Progress, streaks, and allowance

Weeks run Monday through Sunday. Green starts at 95%, yellow at 85%, and red is below 85%. At least 85% accounted for earns allowance after Sunday. Zero expected items are neutral. Children see status and streaks, without numeric percentages. The app does not configure amounts or make payments.

- Required chores count once for each required child. Only that child’s own Done or Not Needed Today state earns credit.
- Any-one chores are optional individual contributions. A contributor gets one accounted item and one expected item; other eligible children get neither credit nor a penalty.
- Excused days are excluded. They neither extend nor break streaks. Days without scored chores are also neutral.
- Past unmarked obligations derive Missed. Parents can correct dated entries and excuse days.

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

Debug UI tests use a separate store and explicit reset flags. Unsigned Simulator builds do not activate CloudKit. Domain tests inject an in-memory transport server to verify shared identity, profile approval, convergence, retries, and credit. These tests are not live iCloud verification.

Physical-device sharing requires an Apple development team with the iCloud capability and the container declared in `Configuration/EarnedIt.entitlements`. Provision `iCloud.com.jlm429.EarnedIt` for the app’s bundle ID. The explicit CloudKit schema is `HouseholdFact` with `payload` (Bytes) and `formatVersion` (Int64), plus the system CKShare record. Development saves can create the development schema. Production schema deployment is a separate, deliberate release action. The app never initializes or promotes production schema automatically.

Before distribution, validate create/invite, cold and warm invitation acceptance, profile approval, two-device completions, relaunch, offline recovery, account changes, read-only access, and share revocation with two signed devices and two iCloud accounts. No live signing, provisioning, or production schema mutation is performed by local tests.

See [architecture decisions and Apple sources](docs/shared-household-architecture.md) and [agent guidance](AGENTS.md).

## Privacy

Family data stays in the installation’s local store and, when connected, the owner’s private CloudKit zone shared only through invited access. There are no ads, analytics, third-party services, or AI features.

# Production invitation package investigation

## Findings recorded before implementation

Baseline: `45a289d`, current `origin/main` after fetch, including merged PR 13. Both physical-path checks resolved to the isolated treehouse worktree. The branch is `fm/earned-it-production-invitation-package`; the starting worktree was clean. `no-mistakes doctor` passed with a running daemon. PR 13's cancelled CI is not native-behavior verification.

Accepted firstmate instructions: inbox `001` approves the scoped repair and requires durable exact-code continuation, safe mismatched callbacks and visible retry after cancellation/visibility lag. Inbox `002` leaves GitHub CI for the captain's manual invocation. Inbox `003`, reaffirmed by `004`, supersedes no-mistakes delivery: stop implementation/review/hardening, finish only tests already running, record actual results and limitations, commit the current change and open a direct PR through gh-axi. No further review, new test cycle, no-mistakes run, GitHub workflow, upload or merge is authorized. Repository workflows remain unchanged. Production visibility and retry behavior require manual two-device validation even when doubles pass.

The captain reports owner invitation creation succeeding on TestFlight and recipient code/QR redemption showing `invitationNotFound`. No access to the two signed physical iPhones or their Production account transitions is available to this worker. No physical Production reproduction or successful join is claimed. Simulator transport is disabled by `EarnedItApp`; unit tests inject the existing synthetic transport.

The prior evidence is in `docs/production-membership-recovery/report.md`, especially its owner delivery/native callback audit. The brief's `data/earned-it-production-membership-recovery/report.md` path does not exist in this checkout. That report's independent continuation fixes are baseline. Its assumption that users manually open a separate Apple invitation does not establish the Production join cause.

## Exact baseline trace and answers

| Boundary | Actual baseline behavior |
| --- | --- |
| `createInvitationAccess` | Fetch/create the existing private zone-wide CKShare, add an unknown-handle `oneTimeURLParticipant` with `.privateUser` and `.readWrite`, save, retrieve the saved participant-specific one-time URL. Return `CloudInvitationAccess(participantID:url:)`. The ordinary `CKShare.url` is not substituted. |
| `issueInvitation` | Persist a role/exact-profile invitation fact with code digest and participant slot ID, upload it, return `IssuedFamilyInvitation(..., code: code, shareURL: access.url)`. No URL loss here. |
| QR | `qrPayload` is a custom `earnedit-invitation://join` URL containing exactly `code` and `share` query values, the latter being the entire one-time CKShare URL. `URLComponents` handles nested URL escaping. `InvitationQRCode` UTF-8 encodes this string into the QR image. |
| Owner Share Invitation / reported Send Invite | `FamilyInvitationView` has one `ShareLink(item: issued.shareText, subject: ...)`. It transfers a String containing prose, the plaintext app code, a newline, and the raw one-time CKShare URL. It does not send the QR image or custom app package. There is no separate native participant-management/send controller in this view. OS activities may render the transferred String differently; actual two-phone activity output was not captured. |
| In-app QR scan | `DataScannerViewController` obtains the QR text, validates `InvitationCredential`, then `JoinFamilyView` calls `store.redeemInvitation(payload)`. This preserves code and share URL and invokes native acceptance directly. It is not a code-only route. |
| Manual Join Family | Code alone searches already accessible private/shared households. Pasted raw Apple link plus code uses `join(url:invitationCode:)`, which directly accepts the share. |
| System Camera / opening package | No `CFBundleURLTypes` registration and no `onOpenURL` handler. The custom package cannot launch/routinely enter the app. `CKSharingSupported` is already true and applies to the native CKShare URL, not the custom scheme. |
| Direct native acceptance | Both generated-QR redemption and raw-link-plus-code fetch metadata with `CKContainer.shareMetadatas(for:)`, validate container and zone-wide household location, preserve a provisional lease/pending envelope, then call `CKContainer.accept([metadata])` unless already accepted/owner. They validate each Result and fetch the shared facts. |
| System native acceptance | Opening the raw `https://...icloud.com/...` URL can trigger Apple's invitation UI. Its cold/warm scene metadata and app-delegate callbacks feed `ShareAcceptance.pending`, then `RootView` calls `store.accept(metadata:)`. Pending participation is accepted with `CKContainer.accept`, exact participant slot is identified, and family facts are imported. The callback supplies no Earned It code, so it leaves profile authority unclaimed. The original share message's code is outside this callback. |
| Shared discovery / exact redemption | Code-only discovery enumerates accessible private/shared record zones. Package redemption instead knows the metadata-derived location and fetches it directly after acceptance. Invitation-slot identity is checked against `CKShare.currentUserParticipant.participantID`; account identity uses the container's user record ID. Redemption validates the exact code digest, role/member, invitation availability, active profile, write access, atomic claim, account lease and binding before attaching the exact profile. Apple acceptance alone grants no app profile. |
| Missing verification fallback | Metadata fetch can throw `participantMayNeedVerification`. No baseline handler opens the native URL for Apple's required account verification. The pre-location failure leaves no code/package continuation. A post-location failure follows existing cleanup. This is a documented missing branch, not a measured Production error receipt. |

Synthetic baseline QR, constructed using the production serializer with synthetic input:

```text
earnedit-invitation://join?code=2345-6789-AB&share=https://www.icloud.com/share/synthetic-only?token%3Dsynthetic%26value%3DA%252BB%23synthetic-fragment
```

The nested URL decodes exactly to `https://www.icloud.com/share/synthetic-only?token=synthetic&value=A%2BB#synthetic-fragment`. This is fabricated, not a live invitation.

Synthetic baseline Share Invitation String:

```text
Join my Earned It family. Open the Apple invitation, then use code 2345-6789-AB.
https://www.icloud.com/share/synthetic-only?token=synthetic&value=A%2BB#synthetic-fragment
```

**Where the native URL was lost/used:** it is retained through issuance, QR and in-app scan. Sharing uses it as a raw native link but loses the app package at the receiving callback boundary. The code remains only in message prose. Custom-URL opening has no receiving route at all. Direct scan acceptance also lacks the documented verification fallback. A blanket assertion that QR lacks the CloudKit URL is false on this baseline.

**Which action triggers acceptance:** in-app Scan QR invokes direct native API acceptance; Join Family with both raw link and code does too. Opening the raw native link invokes Apple's UI and metadata callbacks. Opening the custom QR/package through the system does not work on baseline. Entering only a code cannot initiate acceptance because it has no native URL.

**Error wording:** `invitationNotFound` tells users to open an Apple invitation first. The sharing UI exposes a raw native link inside its message, but no clearly named second stage or automatic code continuation. The error is reused for code-only discovery failure, mismatched package household, missing exact participant match and code/profile validation failures. Its text is not evidence that native acceptance never happened and does not correctly distinguish those causes.

## Reproduction, smallest counterfactual and disconfirmation

Before app edits, two existing generated-invitation unit flows passed: child exact-profile binding/refused escalation/reuse and parent join/persistence/management. These run actual `createChildInvitation` / `createParentInvitation` through issuance, generated `qrPayload`, parser, native transport boundary and claim services, with the synthetic server replacing CloudKit only.

New baseline delivery regressions exercised actual generated output. Code-only before access returned `invitationNotFound`; redeeming the same issued QR invoked acceptance once and attached only the chosen child. This deliberately disconfirms the idea that all QR scans require a separate manual Apple invitation. The parity regression failed: shared URL was a raw native URL, unequal to the generated QR package, and not parseable as an Earned It credential. The first test build had a new-test helper visibility error; it was corrected before the behavioral reproduction, without app edits.

The baseline app was launched on this task's isolated iPhone 17 Pro / iOS 26.5 Simulator using only the separate debug UI-test store. `simctl openurl` with a fabricated app package failed with `LSApplicationWorkspaceErrorDomain` 115. This exercises iOS's actual installed-app routing boundary and confirms absent custom-scheme support. It cannot prove camera hardware, signed CloudKit, Apple's verification UI or Production behavior.

Initiating trigger: attempting to join a private share from the recipient account before it has visible shared access. Masking conditions: a prior native acceptance makes code-only discovery work; the synthetic server immediately matches unknown-handle slots and never requests Apple verification; manual code entry strips the native URL by design. Symptom: broad `invitationNotFound` wording. The observed Production QR failure could also occur after successful native acceptance if exact participant matching or shared-fact visibility fails. No error receipt is available to choose among those native causes. Smallest demonstrated repairs concern complete package delivery, actual URL routing, documented verification and retained exact-code continuation. They must not be presented as established two-phone root-cause proof.

History inspected: `72f6450` originally introduced the same QR/native-link asymmetry; later membership lifecycle changes retained it. `50f176c` fixed lease continuation and recovery, without adding custom URL delivery or a native verification fallback. `Configuration/Info.plist` history contains camera permission and CKSharingSupported, but no custom URL scheme. The entitlement fix is already landed and captain-device-verified; no entitlement change is justified by these findings.

## Apple acceptance contract and representation

Apple explicitly supports using a saved one-time participant URL to fetch metadata and accept the share: [oneTimeURLParticipant](https://developer.apple.com/documentation/cloudkit/ckshare/participant/onetimeurlparticipant()) and [oneTimeURLForParticipantID](https://developer.apple.com/documentation/cloudkit/ckshare/onetimeurlforparticipantid:). [CKFetchShareMetadataOperation](https://developer.apple.com/documentation/cloudkit/ckfetchsharemetadataoperation) supports independent metadata fetching for manual API acceptance; [CKAcceptSharesOperation](https://developer.apple.com/documentation/cloudkit/ckacceptsharesoperation) confirms participation from either fetched or system-delivered metadata. There is no universal requirement to find a separate Apple invitation first.

There are two logical stages: grant native share access, then claim the Earned It code's exact role/profile. These can follow one scan/open action. For the conditional `participantMayNeedVerification` case, Apple's metadata-fetch documentation specifically requires [UIApplication.open](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)) with the **same native share URL**. Opening successfully means only that iOS accepted the open request; it does not establish share acceptance or profile authority. Native cancellation may supply no metadata callback. Represent this as visible unfinished joining with retry using the retained invitation, rather than instructing users to locate another invitation.

After Apple's UI, [CKShare.Metadata](https://developer.apple.com/documentation/cloudkit/ckshare/metadata) defines warm/suspended scene callback delivery and cold `connectionOptions.cloudKitShareMetadata`. Pending status still requires the accept operation. Following successful acceptance, fetch the shared zone facts, verify the invitation slot and retained code digest, then run the existing exact claim. Shared-database availability can lag native completion: Apple's accept-operation documentation allows residual server work. A network failure or incomplete visibility is not permission to bypass exact matching.

Installed Xcode 26.6 / iOS 26.5 SDK contracts checked under `CloudKit.framework/Headers`: `CKShareParticipant.h:142-150` (one-time factory, iOS 18), `CKShare.h:191-201` (saved one-time URL, iOS 18 Objective-C selector), `CKFetchShareMetadataOperation.h:16-34` (fetch and verification/open fallback), `CKAcceptSharesOperation.h:16-24` (accept/results/residual work), and `CKShareMetadata.h` (cold/warm delivery). Existing iOS 26 Swift overlay / iOS 18-25 selector use remains. Custom package opening requires [CFBundleURLTypes](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleurltypes) and [SwiftUI.onOpenURL](https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:)); this is app routing configuration, not a signing entitlement, schema or release change.

## Implementation and final validation

The implemented flow is: owner creates an invitation for the exact child or parent profile, recipient scans the QR **in Earned It** or opens the single shared invitation, the app initiates native acceptance, any required Apple account verification opens the native URL already inside that package, and Earned It continues the original exact-code claim. An unfinished native UI or temporary shared-fact/participant visibility failure retains the invitation and exposes **Continue Joining**. Relaunch can retry the same account-bound package without asking for the code again. Opening Apple's URL successfully is not treated as accepted share access or app profile authority.

The generated QR package format is unchanged. Sharing now transfers that same complete package as a URL, with explanatory message text; the human code remains visible on the owner's invitation screen. Synthetic corrected ShareLink payload:

```text
URL item:
earnedit-invitation://join?code=2345-6789-AB&share=https://www.icloud.com/share/synthetic-only?token%3Dsynthetic%26value%3DA%252BB%23synthetic-fragment

Message:
Join my Earned It family. Open this invitation or scan its QR code to connect to your approved profile.
```

No second invitation must be located. The legacy raw-link-plus-code and already-accessible code-only routes remain available. The actual destination activity's rendering and link-opening behavior on two signed iPhones still require the captain's retest.

Focused code changes:

- `InvitationService.swift` provides one `invitationURL` for QR and URL sharing. `PendingInvitationPackage` contains only the original normalized code's SHA-256 digest, native URL, original account identity and verification state. Clear codes are not persisted. `DeviceSession` has one optional Codable field inside the existing local session payload.
- `HouseholdStore.swift` routes raw-link-plus-code through the same package redemption, persists delivery before metadata fetching, opens the retained native URL only for Apple's verification condition and user initiation/retry, resumes the existing pending lease, and continues the digest's exact role/profile claim after matching native callback acceptance. A callback for another household or account cannot run that acceptance closure or substitute a code. Delivery serializes its active continuation and protects it from scheduled cleanup.
- The existing redemption checks now consume the already validated code digest internally. Exact member/role, current invitation slot, expiry, revocation, availability, write access, atomic claim, account membership lock and binding still gate attachment. Native acceptance alone cannot select a profile. Retryable **fetch/identification** visibility failures retain delivery; definitive atomic-claim permission refusal retains the existing refusal and cleanup behavior. The original child/account refusal suite remains unchanged apart from an explicit `as Any` that removes an encountered optional-time-interval compiler warning.
- `Info.plist` registers the existing custom scheme; `RootView` handles its URL, queues native metadata while joining, continues pending delivery on cold/foreground paths, and exposes visible retry. `JoinFamilyView` accepts the complete package link and replaces the hidden separate-invitation copy. Owner sharing and error copy describe the single invitation flow.
- A debug-only `--ui-test-pending-invitation` fixture is gated by the separate UI-test store. It contains fabricated data only and is absent from Release. The invitation UI flow was extended to cover its retry state, but that extension was **not executed** before the captain stopped new validation cycles. It must not be counted as a passing pending-screen UI check.
- README matches the implemented delivery flow; AGENTS points to this report's delivery evidence and proof limits. The required memory helper reported the existing AGENTS/CLAUDE pointer unchanged before the concise AGENTS edit.

**Schema/entitlements:** no CloudKit or SwiftData entity schema, signing entitlement, provisioning or release-infrastructure change is needed for these demonstrated delivery gaps. The optional delivery data uses the existing local `StoredSession.payload`; shared fact formats, household identities, membership lock/binding formats and historical data remain unchanged. Only custom URL routing registration changed in Info.plist. No actual store, Production membership, lock, share, zone, family or history was inspected destructively, deleted or replaced during worker validation. No live schema provisioning, signing, upload or workflow dispatch occurred.

### Completed local results

Final unit run on the final app implementation: **174 tests passed, zero failures**, 2.687 seconds of test execution (2.722 seconds suite elapsed). Sixteen new delivery tests cover actual generated package contents and QR/share URL parity, nested native URL preservation, original formatted code binding, direct scan acceptance, warm native callback continuation, system-open refusal, cancellation without callback, cold disk repository reopen for both roles, changed-account/different-code/mismatched-household refusals, visibility lag before/between reads, original lease retention, cancellation after native acceptance, expiry and fresh invitation, and definitive native-continuation claim refusal. The acceptance/discovery/slot timing in these tests is the existing synthetic transport contract, not CloudKit server evidence or UIKit native-callback proof.

```sh
xcodebuild test -project EarnedIt.xcodeproj -scheme EarnedIt \
  -destination 'platform=iOS Simulator,id=4732A4A0-5055-46E7-A216-68B020F2929E' \
  -derivedDataPath .artifacts/invitation-package/UnitDerivedData \
  -resultBundlePath .artifacts/invitation-package/final-validated-unit.xcresult \
  -only-testing:EarnedItTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Final unsigned Release generic-iPhone build and Xcode static analysis both passed with the selected full Xcode 26.6 installation. This compiles the physical-device app configuration but is not a signed distribution artifact or a device run. The only remaining tool warning is AppIntents metadata extraction skipped because the app does not depend on that framework. No compiler warning or test failure remains in the final unit run.

```sh
xcodebuild build analyze -project EarnedIt.xcodeproj -scheme EarnedIt \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .artifacts/invitation-package/ReleaseDerivedData CODE_SIGNING_ALLOWED=NO
```

Earlier runs deliberately reproduced QR/share parity failure and absent OS URL routing. Implementation iterations also caught a resumed pending-import transition error and overbroad classification of a definitive claim permission failure as visibility lag. Both were corrected before the final passing unit run; their failures are retained in task artifact logs. `git diff --check` passed before the captain's stop instruction. No new review/check cycle was started after that instruction was read.

The already-running three-flow UI run completed: **three passed, zero failures**, 445.825 seconds total (445.829 seconds suite elapsed). It uses `.artifacts/invitation-package/ui.xcresult` and Simulator `CE94E1D7-2B0A-4303-B0C8-18AB70158DC6`. Its binary predates the later delivery-error refinements and pending-screen test extension. Alternating parent/child chore flow passed (86.252 seconds); actual warm system URL open, cold app URL launch, complete-link paste and relaunch without a profile passed (35.519 seconds); largest Dynamic Type setup/persistence/duplicate prevention/confirmed reset, including the sufficient-element-description accessibility audit, passed (324.054 seconds). These UI tests cannot exercise signed CloudKit, actual camera scanning, native Apple verification, final pending-screen layout or two-account Production behavior. No further test/review cycle was started after the captain's stop instruction was read.

```sh
xcodebuild test -project EarnedIt.xcodeproj -scheme EarnedIt \
  -destination 'platform=iOS Simulator,id=CE94E1D7-2B0A-4303-B0C8-18AB70158DC6' \
  -derivedDataPath .artifacts/invitation-package/DerivedData \
  -resultBundlePath .artifacts/invitation-package/ui.xcresult \
  -only-testing:EarnedItUITests/EarnedItUITests/testInvitationPackageColdAndWarmURLRoutingKeepsUnclaimedSetup \
  -only-testing:EarnedItUITests/EarnedItUITests/testPartialSetupDuplicatePreventionAndConfirmedResetAtLargeType \
  -only-testing:EarnedItUITests/EarnedItUITests/testAlternatingChoreShowsOnlyTheCurrentChildTurn \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

### Shortest two-phone TestFlight retest

1. Through a separately authorized release, install this candidate on the existing owner and recipient iPhones, retaining the same Production household/history and account state. On the owner create an available invitation for the intended exact child in that household. Do not remove healthy memberships, reset stores or create a replacement family to force eligibility. If the recipient already has a conflicting active profile/household, record the existing refusal and obtain captain disposition rather than bypassing it.
2. On the recipient scan the owner's QR **inside Earned It**, or open the owner's shared invitation link. Follow Apple's confirmation if shown. Earned It should finish without another code or hidden invitation, show only the intended child, refuse sibling/parent selection, and preserve that profile after relaunch. If Apple confirmation is cancelled, reopen Earned It and use **Continue Joining** with the same invitation. A cold relaunch should also keep that continuation. If shared information is delayed, retry should retain the original invitation and never show profile authority early.
3. Mark one allowed child chore, refresh the owner, and confirm the same household/history and completion after relaunch. Exercise the alternate QR/shared-link delivery on the same still-eligible invitation/account state when practical. If access was already accepted before this test, a successful join proves continuation only; it does not prove fresh native verification or invitation admission.

If joining still fails, report only non-private transition facts: delivery route, whether Apple UI appeared/cancelled, callback presence, same/different household/account comparison, pending-delivery/pending-access phase, lease state and same-attempt comparison, metadata/accept/fetch/slot/claim failure stage, and CKError category. Do not include real invitation links/codes, account or family identifiers, payloads or credentials in evidence.

**Proof limit:** the precise Production QR failure cause remains unproven. Correct package routing, local continuation and refusal tests do not establish Apple's unknown-handle slot matching, UIKit cold/warm scheduling, Production residual visibility or successful two-phone join. Those behaviors, including visibility and retry, remain manual two-device validation per the captain. GitHub CI is **NOT RUN**; no no-mistakes run was started. Closeout stops at the authorized direct PR, without merge or TestFlight upload.

# Production one-time invitation crash evidence

Date: 2026-09-15. Starting default tip: `89cd91729b97dafb05f9395def4512561de337f2` (`origin/main`). Branch: `fm/earned-it-production-invitation-crash`. Worktree: `/Users/jlm429/.treehouse/earned-it-0033f9/1/earned-it`. Isolation verified with `pwd -P` and `git rev-parse --show-toplevel` before branching. No Production CloudKit operation, schema change, household reset, store migration, upload, or build-number change was performed.

## Finding and limits

The repository omits the native one-time link entitlement. CloudKit's local `CKShare.addParticipant:` implementation requires `com.apple.developer.icloud-extended-share-access` to contain `InProcessOneTimeLinks`. Without it, the exact factory, permission, role, and add sequence terminates with signal 5 before any save. Adding only that entitlement makes native admission succeed. This is a verified repository defect and native causal boundary, and the best-supported explanation for the captain's symbolicated Build 4.1 crash.

The actual signed TestFlight Build 4.1 entitlements, its exception/termination detail, and the iPhone OS version were not supplied or inspected. Therefore attribution of that specific device termination to this precondition remains an inference, not a measured device result. A signed Build 4.1 already containing the value, or an entitled candidate still failing at this call, would disconfirm that attribution. Obtain only the CloudKit fault/exception reason and stack in that case, without exporting family data or signing credentials.

## End-to-end observation and separation

Captain-supplied observation: Earned It 1.0 Build 4.1 from TestFlight on a real iPhone, with deployed Production schema. Household creation succeeds. Creating a child invitation reproducibly crashes about three seconds later. Expected result: an invitation for the parent-selected child, with an Apple invitation URL and app code. Symbolicated Thread 0:

`FamilyInvitationView.createInvitation -> HouseholdStore.createChildInvitation -> HouseholdStore.issueInvitation -> CloudKitHouseholdTransport.createInvitationAccess -> -[CKShare addParticipant:]`

- Trigger: owner requests the role-bound child invitation, reaching native addition of a one-time participant.
- Masking condition: the in-memory transport never invokes native `addParticipant:` and originally modeled neither the signing entitlement nor its admission failure. Unsigned application UI tests disable CloudKit and cannot cover this production path.
- Visible symptom: the process closes before invitation presentation, rather than returning a Swift error.

A faithful TestFlight reproduction was unavailable locally. The closest safe path executed actual native CloudKit objects on a newly created isolated iPhone 17 Simulator, iOS 26.5, without a `CKContainer`, database, network call, real account, or family journal. It does not reproduce or prove the signed two-account result.

## Native contract and evidence

Sources checked against installed Xcode 26.6 (17F113), iOS/iPhoneSimulator 26.5 SDK, macOS 26.6.2, and current primary Apple documentation. The browsed HTML exposes Markdown links; where the web reader rejected `text/markdown`, the exact Apple Markdown endpoint was retrieved directly.

| Contract | Verified evidence and consequence |
| --- | --- |
| Manual addition is intended | [oneTimeURLParticipant()](https://developer.apple.com/documentation/cloudkit/ckshare/participant/onetimeurlparticipant()) explicitly describes adding the factory participant, saving the share, then obtaining its one-time URL. There is no need to replace this with a sharing controller. |
| Native entitlement | [Extended share access entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-extended-share-access?changes=l_4) lists `InProcessOneTimeLinks` for single-use links. Request only that value. Native admission enforces it earlier than URL retrieval. This feature does not request owner contact information or access-request capabilities. |
| Roles | [ParticipantRole](https://developer.apple.com/documentation/cloudkit/ckshare/participantrole) defines unknown, owner, privateUser, publicUser, and administrator. The native factory yields privateUser, readOnly, pending. Setting privateUser again is accepted. Unknown/public roles are rejected on add; a second owner is rejected. The public role is self-added through public access. |
| Administrator | [Administrator](https://developer.apple.com/documentation/cloudkit/ckshare/participantrole/administrator) supports participant management beginning iOS 26. Older devices receive administrator shares as read-only with privateUser roles. Native admission accepts administrator on 26.5. Existing app policy continues to use privateUser for both parent and child invitations and owner-only participant management. |
| Permission mutations | [Permission](https://developer.apple.com/documentation/cloudkit/ckshare/participant/permission-swift.property) is mutable. Native readWrite and readOnly admission succeed; none also admits an object but provides no useful access. Setting unknown throws before add. Read/write access is transport-wide, not role authorization. |
| Other add preconditions | [addParticipant](https://developer.apple.com/documentation/cloudkit/ckshare/addparticipant(_:)) requires private sharing (`publicPermission == .none`) and updates an existing matching identity. Re-adding the same native object keeps two participants total, including the owner. App-owned shares already use `.none`. The probe unexpectedly admits a private object to a public share locally on 26.5; that contradicts a strict local interpretation of the documented rule and is retained in the evidence. No server save was attempted, and the app retains the documented private configuration. |
| Zone-wide support | [init(recordZoneID:)](https://developer.apple.com/documentation/cloudkit/ckshare/init(recordzoneid:)) is available since iOS 15. Custom private zones have zone-wide-sharing capability. A zone can hold one zone-wide share or hierarchical shares, never both. [Apple's sharing talk](https://developer.apple.com/videos/play/tech-talks/10874/) describes saving zone shares to the private database and the same acceptance path. Native one-time admission succeeds for both zone and hierarchical shares with the entitlement. |
| One-time semantics | [oneTimeURLForParticipantID:](https://developer.apple.com/documentation/cloudkit/ckshare/onetimeurlforparticipantid:?language=objc) requires a saved share and a factory-created participant ID. Its URL is stable while the participant remains in the share. Any recipient can claim the pending slot. After acceptance it behaves like the regular private-share URL, not a permanently invalid URL. App code claims, role binding, expiry, and revocation remain separate authority. |
| Server boundaries | [CKShare](https://developer.apple.com/documentation/cloudkit/ckshare) documents active iCloud accounts, a 100-participant limit, private custom zones, and restrictions on records already shared elsewhere. Those save/accept conditions were not tested against a live server. Household creation and share fetch in the supplied failure already precede native add. |

Installed SDK evidence: `CloudKit.framework/Headers/CKShareParticipant.h` lines 44-71, 114-150; `Headers/CKShare.h` lines 151-205; and `Modules/CloudKit.swiftmodule/arm64e-apple-ios.swiftinterface` lines 686-690 and 735-742, under the selected iPhoneOS SDK. The factory and Objective-C URL selector are iOS 18 APIs. The Swift `oneTimeURL(for:)` overlay is iOS 26; existing code uses the documented Objective-C selector on iOS 18-25 and the overlay on iOS 26. No availability change is necessary.

Current entitlement documentation's Markdown metadata labels the key iOS 26, while the native one-time APIs are explicitly iOS 18. This documentation discrepancy does not establish that the API is impossible on iOS 18-25. The declared app minimum remains iOS 18. Only iOS 26.5 native execution was available here. Older-OS entitlement enforcement, URL retrieval, and signed delivery need device coverage before claiming support was runtime-verified there.

## Counterfactuals, history, and exception detail

The smallest successful counterfactual is the same native factory/readWrite/privateUser/add sequence with only the simulator-embedded entitlement changed. Simulator entitlements use a `__TEXT,__entitlements` section. Standalone ad hoc signature experiments were rejected by local execution policy; they gave no CloudKit counterfactual result and are not distribution evidence. The linker-embedded simulator experiment executes normally and is the retained proof.

CloudKit's filtered native log, obtained without captain-device access:

```text
Significant issue at CKShare.m:1046: To use one time links, you must have the 'com.apple.developer.icloud-extended-share-access' entitlement with an array that includes 'InProcessOneTimeLinks'.
```

The entitlement failure is a trap in this runtime, not a caught Objective-C exception. Invalid role/permission negative controls do produce caught `NSInternalInconsistencyException` details, preserved in [native-results.log](native-results.log). The entitlement faults are in [native-entitlement-fault.log](native-entitlement-fault.log).

Disconfirming checks: omitting the explicit privateUser mutation still traps without the entitlement and succeeds with it. Changing only permissions between factory readOnly and readWrite succeeds with the entitlement. Both share models work. A wrong entitlement value still traps. These observations rule against the role assignment, readWrite permission, zone-wide model, or an inherent ban on manual one-time addition as the local cause. The probe performs no server save, so a Production schema change cannot explain the measured native admission difference.

History: `72f6450` introduced role-bound invitations and the one-time factory. `c05edb9` changed parent invitations from administrator to privateUser and made creation owner-only. Both original child branches and the current branch set privateUser. `Configuration/EarnedIt.entitlements` previously changed in `1156dab` and `1c12a8d`, but never declared one-time link access. Prior passing double tests did not exercise this native boundary. Nearby role hardening is not causal evidence for the crash.

## Exact change and validation

Production change: add this entry to the existing signing entitlement file used by Debug and Release:

```xml
<key>com.apple.developer.icloud-extended-share-access</key>
<array><string>InProcessOneTimeLinks</string></array>
```

There is no native method/API replacement. Keep `oneTimeURLParticipant()`, `.readWrite`, `.privateUser`, `addParticipant`, save, and per-participant URL retrieval. No authorization, onboarding, journal, schema, or version changes are needed.

The double now rejects one-time creation when its modeled extended access lacks the required value. It reports a rejected operation without crashing XCTest. It also permits repeat acceptance of an already accepted one-time URL by an authorized account while preserving the original participant binding and rejecting uninvited accounts. The double remains non-native evidence.

`NativeInvitationContractTests` parses the signing plist as a property-list contract, verifies the exact capability array, executes the native factory and supported mutations, and exercises the double's missing-capability rejection, same-household recovery, child binding, repeated acceptance, and unauthorized reuse. Its entitlement regression failed before the configuration change with `XCTUnwrap` on the missing array; the other three tests passed. Initial test compilation mistakes were corrected before the meaningful before/after run.

[run-native-probe.sh](run-native-probe.sh) parses the actual configured signing plist, embeds the capability using the Simulator mechanism, and executes native add and negative controls. Run on a booted task-isolated Simulator:

```sh
docs/production-invitation-crash/run-native-probe.sh <simulator-uuid>
```

All 18 native admission/negative-control cases passed on iOS 26.5. Three absent/wrong-value controls intentionally terminate with signal 5. The public-share observation is runtime evidence, not permission to deviate from Apple's documented contract.

Final validation: **139 unit tests passed, zero failures**, including all 63 invitation tests and 25 sharing tests. Coverage includes role-bound parent/child grants, sibling/parent escalation rejection, legacy-grant isolation, cross-role URL/code mismatch, cross-family misuse, expiry and clock skew, revocation, consumption/reuse, account locks, generation replacement, atomic claim conflict classification, retry, cleanup, and relaunch persistence. Application authorization services were unchanged.

An existing cleanup test also failed with the original remote-tip double on a second isolated Simulator: it expected an immediate leave after a retryable `.networkFailure`. The implementation intentionally retains the provisional attempt. The test now asserts zero immediate leaves and a retained attempt, invokes explicit `retryInvitationCleanup()`, then asserts the attempt clears and one leave occurs. This corrects the encountered stale test without changing cleanup or authorization behavior.

One focused XCUITest passed (319.963 seconds): `testPartialSetupDuplicatePreventionAndConfirmedResetAtLargeType`, covering fresh launch, partial setup/relaunch, duplicate prevention, parent experience, confirmed local reset and relaunch, accessibility descriptions, and the unsigned sharing-dependency error. Only the dedicated debug UI-test store was reset. No production or actual household store was deleted.

Commands used for final unit and UI verification, with task-isolated Simulator UUIDs:

```sh
xcodebuild test -project EarnedIt.xcodeproj -scheme EarnedIt \
  -destination 'platform=iOS Simulator,id=6E212056-6F8C-4404-BF5C-E716295D9D5F' \
  -derivedDataPath .artifacts/invitation-baseline/DerivedData \
  -resultBundlePath .artifacts/invitation-diagnostic/final-unit.xcresult \
  -only-testing:EarnedItTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
# UI selection in the earlier test run on 0D6B053A-CC65-49D1-90E4-7C2665B74D86:
# -only-testing:EarnedItUITests/EarnedItUITests/testPartialSetupDuplicatePreventionAndConfirmedResetAtLargeType
```

Local before/after evidence: `.artifacts/invitation-diagnostic/before-entitlement.xcresult`, `baseline-cleanup.xcresult`, `after.xcresult` (unit failure before test correction, UI passed), and `final-unit.xcresult`. The report and committed native logs preserve results without depending on those ignored bundles.

Release validation: unsigned generic iOS archive **passed**, unsigned Release Simulator build **passed**, and Release Simulator launch/relaunch **passed** with the fresh Welcome screen and no seeded family. Candidate archive: `.artifacts/invitation-release/EarnedIt-candidate.xcarchive`. Its Info.plist retains bundle ID `com.jlm429.EarnedIt`, version 1.0, build 1, minimum iOS 18.0, and `CKSharingSupported == true`; no version was changed. `codesign -dvv` explicitly reports the archive app is unsigned.

```sh
xcodebuild archive -project EarnedIt.xcodeproj -scheme EarnedIt \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .artifacts/invitation-release/DerivedData \
  -archivePath .artifacts/invitation-release/EarnedIt-candidate.xcarchive \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -project EarnedIt.xcodeproj -scheme EarnedIt \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .artifacts/invitation-release-simulator/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

The real Xcode Release build-settings consumer resolves `CODE_SIGN_ENTITLEMENTS=Configuration/EarnedIt.entitlements`, `CODE_SIGN_STYLE=Automatic`, `ICLOUD_CONTAINER_ENVIRONMENT=Production`, and minimum iOS 18.0. No development team or profile specifier is configured in this worktree. A signed distribution archive/export was not attempted without that release authority and setup. No keychain identity, signing credential, service-account file, or provisioning profile was read. The passing unsigned archive verifies Release compilation/archiving only. Existing CloudKit initializer deprecation and the system AppIntents metadata-skip warning remain compiler/tool warnings, not failed checks. The native probe compiles with `-Wall -Werror`; plist validation, shell syntax, and `git diff --check` passed.

## Production configuration and Build 4.2 candidate

No Production CloudKit schema/configuration change is required for this fix. It changes process signing capabilities, not record fields, zones, share location, container, or account locks. Use the existing household and deployed schema. No family data was modified in this investigation.

A Build 4.2 candidate can be prepared from this branch using the established distribution lane, subject to its normal signing and App Store Connect checks. It has not been uploaded or assigned a new build number here. The distribution signer must include `InProcessOneTimeLinks` in the final app's extended-share-access entitlement. Ensure the selected distribution profile supports the capability; refresh it through the authorized release process if signing/export rejects it. Compatibility of an existing profile was not inspected because no credentials or provisioning material were read. An unsigned archive or simulator entitlement section does not establish App Store/TestFlight signing acceptance.

On the authorized release machine, verify the final signed app has the expected extended-share-access array and Production CloudKit environment. Read only those non-secret capability values, never print an entire profile, credential, or service-account file. A signed candidate still failing at native add should be investigated with its specific fault reason before changing architecture or production data.

## Shortest two-device captain retest

1. Install the signed candidate over Build 4.1 on the owner iPhone, retain the existing household, and confirm its children/history remain. Record OS version. As owner parent, create an invitation for one existing child. Wait at least ten seconds. Confirm the app remains alive and presents the Apple URL plus app code/QR.
2. On the second iPhone with a distinct iCloud account and no active Earned It household membership, install the same candidate and redeem the package. Confirm Apple acceptance succeeds, the existing household loads, and exactly the invited child profile is selected. Confirm sibling/parent selection and parent-only management are unavailable.
3. Mark one child chore, refresh the owner, and confirm synchronization. Relaunch the child app and confirm the same bound identity persists. Reopen its accepted invitation and confirm it does not offer a new role or grant. This checks the core delivery path without deleting or resetting a Production household.

Optional follow-up using captain-authorized test invitations: owner revocation removes app access; mismatching a child URL with a parent code fails; expiration after the real 24-hour server interval fails. These are already checked at the application boundary by doubles, but that does not prove Apple's signed two-account behavior.

Delivery stops at the implementation/evidence commit. Firstmate invokes no-mistakes afterward. No push, TestFlight upload, PR creation, or merge is part of this implementation stage.

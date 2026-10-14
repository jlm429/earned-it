# Final release readiness audit

October 10, 2026 integration review: merged `origin/main` is `6820fe9e6836df4c14aa0a1e2f44814cad18a098`. UI polish, exact owner-reinstall deletion finalization, approved punts, Activity, optional alerts, and `remote-notification` background mode are integrated. The consolidated candidate restores inherited root tint, reconciles these documents, adds child weekly Punt Stats, and sets shared version metadata to **1.0.5/build 51** after the human-confirmed uploaded 1.0.4/build 50. Signed independent-account/device evidence remains required for lifecycle recovery and APNs delivery. Source integration does not close those release prerequisites.

The merged-main audit passed 211 focused unit tests and two of three native flows; its deletion flow failed before recovery at a toolbar action hidden by native overflow. That run is historical evidence on `6820fe9e`, not a green combined-candidate result. Combined-candidate local validation is recorded below; no-mistakes, push, PR publication, CI and merge are deferred at the user's request until morning.

The remainder retains the original documentation audit of `d88d9749ddbf087e75346e6fffd0e64f11d7af03`, version 1.0.4/build 16, minimum iOS 18. Its 383 domain tests, unsigned Release build/helpers and three focused Simulator flows passed on that historical base. The owner-reinstall recovery fix was not present on that base and is now integrated. The final signed artifact, Development lifecycle-access proof before any authorized Production role change, signed parent/child recovery, APNs evidence, and Store/asset inputs remain human actions in [the release checklist](app-store/release-readiness.md).

## Combined 1.0.5 candidate local validation

October 10, 2026, Xcode 27.0 (27A266a), dedicated iPhone 17 / iOS 26.5 Simulator `926BDB3C-CF4F-4028-B4DD-A790BE2DB167`. Local synthetic evidence is outside the repository in `data/earned-it-release-1-0-5/`; no screenshots were uploaded.

| Check | Result | Local evidence |
| --- | --- | --- |
| Full unit/domain suite | 427 passed, zero failures | `combined-normal.xcresult`, `combined-normal.log` |
| Exact pending-deletion flow before correction | Failed at absent `family-management` lookup after 172.466 seconds | `deletion-before.xcresult`, `deletion-before.log`, `deletion-before-toolbar.png` |
| Same deletion flow after hiding the unnecessary DEBUG clock | Passed, 46.588 seconds; settings confirmation, relaunch and largest-text recovered-owner Finish Deleting assertions retained | `combined-normal.xcresult` |
| Normal child Stats | Passed, 38.651 seconds; week switch, empty state, sibling counts, relaunch persistence, parent exclusion and description audit | `combined-normal.xcresult`, `screenshots-normal/` |
| Largest-text dark Stats | Passed, 43.753 seconds; readable stacked week controls, empty/breakdown, touch targets and description audit | `stats-large-dark.xcresult`, `screenshots-large-dark/` |
| Debug and unsigned Release compilation/metadata | Passed; built app CFBundle values 1.0.5/51, iPhone/iPad and `remote-notification`; all targets resolve 1.0.5/51 in both configurations | `Derived/`, `ReleaseDerived/`, resolved-settings JSON, `version-verification.txt` |
| Release helper and synthetic semantic checks | Passed; built Release metadata accepted, synthetic build 50 rejected; build-number and profile-entitlement semantics passed | `release-metadata.log`, `build-number.log`, `profile-synthetic.log` |
| Preserved build configuration | Every non-version build setting matches merged main; signing and CloudKit configuration unchanged | `version-verification.txt` |

The before/after failure is test navigation: the unnecessary test clock crowds Manage Family into native toolbar overflow, while the old helper scrolls body content. Hiding that debug clock preserves the synthetic household and all deletion assertions. It is distinct from the audit's separately correlated SpringBoard automation crashes; this reproduction shows an assertion failure, not an Earned It crash. No runtime recovery or reset code was changed. Local screenshots confirm the restored inherited terracotta/pale tint and readable light/dark Stats layout. Expected unreadable-store errors occur in the passing deliberate startup-recovery unit regression.

These three focused native flows exercise disposable test-store launch/reset, relaunch, parent/child presentation and recovery controls. They do not perform signed CloudKit finalization or APNs delivery. No-mistakes review/lint/publication gates have not run on this candidate; signed independent-account/device, Production security, final artifact and Store inputs remain open human release prerequisites.

## Historical audit: earlier merged changes

The forge bodies and complete diffs were inspected through `gh-axi`, then compared with current source and executable coverage.

| Change | Current evidence and remaining limit |
| --- | --- |
| [Refresh As Needed rotation](https://github.com/jlm429/earned-it/pull/39) | Store actions synchronize before availability/Skip and retain durable offline work only for classified transient failures. Current domain tests include stale-parent, three-child, and offline/relaunch cases. The original UI proof and these doubles do not establish signed inter-device convergence. |
| [Interrupted family deletion recovery](https://github.com/jlm429/earned-it/pull/40) | With the local receipt retained, pending intent survives relaunch, suppresses ordinary sync/recovery, and exposes Finish Deleting for the exact generation. Historical focused deletion tests passed within the full suite on the audited base. They do not cover receipt loss after uninstall between zone removal and authenticated finalization. The separate [PR 44 fix](https://github.com/jlm429/earned-it/pull/44) was absent from that historical base and is now integrated; signed parent/child proof and lifecycle-access policy checks remain open. |
| [Occurrence-aware parent chore controls](https://github.com/jlm429/earned-it/pull/41) | Stable occurrence IDs, repeated same-day use, withdrawal, control-head ordering, correction history, scheduled Done precedence/restoration, and versioned write refusal have passing domain coverage. Corrections must keep later turns fixed. The CloudKit fact envelope supports versions 1/2 without a new record schema, but rollout still needs old/new signed-client refusal and convergence proof. |

No new interpretation of parent correction, partial all-child withdrawal, or later-turn ownership is introduced by this audit. The earlier [invitation crash](production-invitation-crash/report.md), [invitation delivery](production-invitation-package/report.md), and [membership recovery](production-membership-recovery/report.md) reports retain their measured boundaries. Historical entitlement/schema findings are not evidence that the current signed artifact or live container is configured incorrectly today.

## Historical followups assessed on the original base

| Historical concern | Current result |
| --- | --- |
| Creation/archive dates stored as instants could shift during travel | Current `CivilDay` encodes a validated date string. `Household.timeZoneID` fixes the household calendar; created, joined, effective, archived, and completion days use that calendar. `BusinessRulesTests.testCreationAndArchiveUseHouseholdDayAcrossTimezoneAndDSTBoundaries` passed. The old instant-based concern does not justify migrating existing facts or stores. |
| Same-day reassignment could hide earlier child history | Existing chore edits begin tomorrow through `choreAssignmentDay`; current contributions and earlier assignments remain separately projected. `testSameDayReassignmentPreservesTodaysHistoryAndStartsTomorrow` and displaced-history cases passed. Preserve this next-day behavior and the current immutable history rules. |
| Baseline `3e0c8a9` lifecycle tests failed during reset/replacement races | The old test names are absent. Their replacements, `InvitationTests.testInvitationCleanupDoesNotPermitConcurrentLocalReset` and `SharingTests.testSuspendedConnectionBlocksLocalResetUntilConnectionCompletes`, execute suspended/async operations and assert `pendingChanges` rather than forcing concurrent reset. Both passed. The original failures are superseded by the exclusive-operation contract, not reproduced defects on this base. |

These are executable store/domain results, not source-text assertions or signed CloudKit evidence. The [architecture](shared-household-architecture.md) remains authoritative; no legacy timezone or history migration was performed.

## Historical release and privacy findings

| Area | Verified repository finding | Remaining release action |
| --- | --- | --- |
| Identity/configuration | Project and built Release metadata are 1.0.4/16, iOS 18, iPhone/iPad, and four iPad orientations. Release selects Production iCloud; Debug selects Development. | Confirm actual signed archive identity, SDK, distribution entitlements, container, and final build number. No signing, bundle, team, capability, or schema setting changed here. |
| Crash/build/test health | Unsigned physical-target Release build and static analysis succeeded; 383 domain tests and three real-app Simulator flows passed. | Run signed final-candidate smoke tests. AppIntents metadata extraction emits a non-actionable warning because the app has no AppIntents dependency; no compiler error/test failure was found. |
| Manifest/disclosures | Embedded source manifest declares linked names, optional allowance financial information, user/device identifiers, and other household content for app functionality; no tracking; UserDefaults reason `CA92.1`. No third-party packages/SDKs, ads, ATT/IDFA, analytics, or telemetry service found. | Compare the final signed archive's generated privacy report and actual data practices with App Store Connect. Keep the existing conservative CloudKit collection disclosures subject to human confirmation. |
| Data access | Household facts use owner-private/invited-shared zones; account membership records are private; minimal lifecycle authority is public. App roles restrict actions, while CloudKit read/write permission covers shared records broadly. | Invite trusted family participants. Do not describe app checks as server-enforced child authorization. First prove signed former-participant Development access to both family and exact claim-revocation authorities under Authenticated Read/Create and Creator Write with no World permissions. Only then may an authorized human correct and verify Production roles. The October 10 World Read report is human-reported, not independently verified evidence of current Production configuration. |
| Deletion | Creator-only confirmed deletion, retained-receipt generation-scoped retry, anti-resurrection tombstones, and authenticated participant local recovery exist. Receipt loss after uninstall with an absent owner zone and `deleting` authority leaves children without terminal proof. | The recovery fix is now integrated; pass signed two-account/device parent/child receipt-lost recovery checks. Recovery must reconstruct creator-authenticated exact original household, generation/attempt and current-account proof from surviving authoritative records, verify exact original owner-zone absence, and publish authenticated `deleted` before old membership release and local clearing. Preserve account isolation and child terminal-proof requirements; reject missing/active/unauthenticated authority, stale bindings and non-creators. Signed retained-receipt interruption, account-switch, exact revocation, relaunch and fresh-household checks remain required. Retained lifecycle/security metadata must remain disclosed. |
| Camera/permissions | Camera purpose is invitation scanning. Manual link/code entry remains available. No protected API beyond camera, or notification authorization, was found on this base. | Check camera denial/hardware and manual fallback on devices; check consent and denial for the now-integrated notifications. |
| Offline/sync | Local facts and pending outbox survive relaunch. Sync is connection, foreground, local-change, and refresh driven. | Signed offline/reconnect convergence remains unproved. Avoid instantaneous, guaranteed background, or device-only-data claims. |
| Release leakage | Production launch uses the real journal without seeded families. Debug clocks, test stores/resets, fabricated invitations, and fixtures are compile-gated. No nuke functionality is introduced. | Inspect the final combined Release artifact and keep diagnostic/test flags out of submission screenshots and review instructions. |
| Accessibility | Current flows prove largest-text setup/persistence/confirmed local reset, description audit, accessible public links, and distinct parent/child turn controls. Exported native screens were inspected. | This is not full VoiceOver, dark-mode, reduced-motion, all-screen contrast, or iPad proof for the final UI. Retain prior evidence and retest the integrated candidate on physical devices. |
| URLs/review | Public policy and GitHub Issues destinations loaded without a login to read them. First-run and parent menu link controls passed UI validation. Filing support issues uses GitHub's account flow. | Human must confirm maintained hosting/support, enter the URLs in App Store Connect, and supply sharing review resources privately with expiry/one-time constraints. |
| Screenshots/art rights | This audit's captures remain historical engineering evidence. The [visual asset specification](app-store/visual-assets.md) owns current banner, preview, icon, and screenshot status. | Follow that specification for artwork rights and final screenshot approval. |
| Family/children | Family profiles, no public feed/ads/analytics, and parent-managed invitations match the family positioning. Current child UI has external policy/support links without a Kids parental gate. | Complete the current age/category questionnaire and children's privacy review. A low age rating does not mean Made for Kids compliance. Do not market in the Kids Category without resolving its requirements. |

## Current Apple requirements

Authoritative Apple pages were read with `chrome-devtools-axi` on October 10, 2026. Requirements can change, so check again at submission.

| Authority | Application to this candidate |
| --- | --- |
| [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) | Sections 2.1/2.3 require a complete, stable app, accurate listing/screenshots, functioning URLs, and reviewer access. Sections 5.1/5.2 cover data practices, deletion, children, and content rights. Rule 4.5.4 requires optional push and protects sensitive notification content. See [the system artwork review](app-store/quotes-and-attribution.md#system-artwork-and-names) for rule 4.5.6 and the resolved avatar concern. |
| [Submission requirements](https://developer.apple.com/news/upcoming-requirements/) | Current uploads require Xcode 26 or later and iOS/iPadOS 26 SDK or later. The updated age questionnaire also applies. Selected Xcode 27.0 and the repository's Xcode 26.6 workflow meet the source/toolchain floor; the actual submitted archive still needs confirmation. |
| [Screenshot specification](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) | Required device groups, accepted dimensions, formats, and capture guidance are maintained in [the visual asset specification](app-store/visual-assets.md#required-app-store-screenshots). Historical engineering captures are not a final submission set. |
| [Required listing properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties) | Store inputs include listing, support, review, rights, privacy, and release information. Source version/pricing drafts do not establish live listing values or agreements. |
| [Privacy details](https://developer.apple.com/app-store/app-privacy-details/) and [privacy management](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy) | Explain retained off-device data and keep responses aligned with each shipped version. Confirm the manifest/report and store answers together. No tracking is different from no retained synchronization data. |
| [Notification authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) | Request alert/sound/badge authorization in a useful context, respect denial and later settings changes, and preserve the core app without alerts. Notification authorization is now integrated; the original historical base did not include it. |
| [CloudKit sharing](https://developer.apple.com/documentation/cloudkit/ckshare) | Participants with write access can change/delete shared records; app-level roles are a distinct trust boundary. Signed native admission and shared visibility remain separate from transport doubles. |
| [CloudKit database subscriptions](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription) | Private/shared-database subscriptions apply to the subscribing account. CloudKit notifications can coalesce and signal a need to fetch; they are not a durable event payload. `UIBackgroundModes` `remote-notification` is now integrated in source; it was absent from the original historical base. Signing/APNs entitlements or provisioning changes, CloudKit schema promotion, private/shared subscription behavior and signed two-account/device evidence remain human release prerequisites. Delivery is best effort, not guaranteed. Local-on-arrival alerts do not prove remote/background delivery. |

## Historical validation and proof location

Historical test stores, logs, derived data, complete forge diffs, browser receipts, result bundles, and exported screenshots are outside the repository in the task artifact directory `data/earned-it-release-readiness/`. The worktree started clean on the audited base. No actual store, live invitation, Production record, credential, provisioning profile, or preserved nuke checkout was inspected or changed.

| Check | Result | Artifact |
| --- | --- | --- |
| `EarnedItCI`, entire domain suite | 383 passed, 0 failures; iPhone 17, iOS 26.5 | `unit-baseline.xcresult`, `unit-summary.json`, `unit-baseline.log` |
| Release generic-iOS build and Xcode analysis | Passed, signing disabled; Xcode 27.0 (27A266a) | `release-build.log`, `ReleaseDerivedData` |
| Build-number semantics | Passed | `scripts/test-build-number.sh` |
| App Store entitlement semantics | Passed with synthetic fixtures, no actual profiles read | `scripts/test-app-store-profile-entitlements.sh` |
| Release device-family/version/orientations | Passed on built Release `.app`, version 1.0.4 | `scripts/validate-release-device-family.sh` |
| Privacy/Info plist parsing | Passed | Source and built bundle plist inspection |
| Large-text setup/persistence/confirmed local reset | Passed; 268.595 seconds; includes sufficient-element-description audit | `ui.xcresult` |
| Public privacy/support controls | Passed; 33.854 seconds | `ui.xcresult` |
| Three-child alternating parent/child visibility | Passed; 89.819 seconds | `ui.xcresult` |
| All three UI flows combined | 3 passed, 0 failed, 0 skipped | `ui.log`, `ui-screenshots/manifest.json` |

These are prior local executable results on the stated audited base, not new validation of PR 44 or the combined release. Any approved no-live-surface Test exception for this documentation milestone is separate from this historical evidence.

The UI suite uses `EarnedIt`, since `EarnedItCI` intentionally excludes UI tests. It runs only the three named flows above, on a newly created task-only Simulator with a separate debug store. Screens inspected include parent current-owner, child's Your turn, largest-text parent, and public first-run links. The view with another child's turn is hidden as expected; no live CloudKit transport is involved.

Human signing, Production security verification, TestFlight distribution, and submission remain outside the validation pipeline's authority.

# App Store release checklist

Updated October 11, 2026 against merged `origin/main` at `5c88d45e42c671d22f745bbe78cc4f5beec88576`, plus the profile toolbar cleanup. [Shared version metadata](../../Configuration/Version.xcconfig) owns the candidate version and build, following the human-confirmed uploaded 1.0.5/build 51. See the [product introduction](../../README.md#what-it-does) for current features and home navigation and the [profile selection follow-up](../release-ui-polish.md#profile-selection-follow-up) for retained code awaiting review. This is a submission checklist, not a claim of Store availability or signed Production readiness. See [release evidence and limits](../final-release-readiness.md); signed two-account/device parent/child recovery and APNs checks remain open.

## Remaining release blockers

- [ ] Publish the privacy policy at a stable public URL and enter that URL in App Store Connect. The repository is public, so the merged `docs/app-store/privacy-policy.md` page can serve as the URL if that hosting choice is accepted.
- [x] The app links to the merged public privacy policy. Human confirmation of maintained hosting and the App Store Connect URL remains above.
- [ ] Confirm the app icon artwork is owned or licensed for commercial use. The repository contains no provenance or license record for the artwork.
- [ ] Confirm that system-rendered emoji avatars are acceptable in the shipping app and screenshots under current Apple review and artwork rules, or approve a separate owned-art replacement before release.
- [ ] Replace or approve the current icon treatment before submission. It is a valid opaque 1024 by 1024 PNG, but the artwork includes its own rounded tile and white corners before iOS applies the system mask.
- [ ] Capture accurate App Store screenshots from the release candidate at accepted iPhone and iPad sizes. The tracked `assets/earned-it-preview.png` is stale, shows an older interface and icon, says iOS 17+, and incorrectly says data stays only on device.
- [ ] Complete a signed release-candidate pass on physical devices with two separate iCloud accounts. Cover owner creation, parent and child invitations, cold and warm acceptance, QR and link delivery, completion sync, relaunch, recovery, read-only behavior, and revocation.
- [ ] Complete the [notification signing and independent-account device checks](../punt-notifications.md#background-delivery-and-release-prerequisites), including the remaining scenarios in that guide's verification section.
- [ ] Confirm the production CloudKit schema contains every record type and field used by `CloudKitHouseholdTransport.swift`. Existing reports say a production schema was deployed and used by TestFlight, but this repository audit cannot inspect the live container.
- [x] Captain-reported Production lifecycle type and field inspection is recorded in [Family lifecycle authority](../family-lifecycle-authority.md#cloudkit-schema-and-security); the agent has not independently verified the environment.
- [ ] Confirm Production lifecycle security compliance using the staged procedure in [Family lifecycle authority](../family-lifecycle-authority.md#cloudkit-schema-and-security). Signed Development former-participant read access must be proven before an authorized human changes Production roles, followed by bounded signed Production verification.
- [ ] Validate the integrated uninstall/reinstall deletion recovery fix on signed devices: obtain signed two-account evidence using the [captain acceptance procedure](../delete-all-earned-it-data-implementation-report.md#recovery-after-owner-reinstall-during-deletion). Simulator and transport-double results do not close this blocker.
- [ ] Confirm that the archived app contains the expected iCloud and extended-share-access entitlements.
- [ ] Complete required App Store Connect values, agreements, tax and banking status where applicable, age rating, privacy responses, pricing set to Free, territories, export compliance, content rights, copyright, review contact, and release method.

## Verified repository evidence

- [x] Prior candidate local checks are recorded in [exact evidence and limits](../final-release-readiness.md#combined-105-candidate-local-validation). That historical evidence does not validate the current candidate.
- [x] Historical complete domain suite on `d88d9749`: 383 tests passed with zero failures on a task-only iPhone Simulator. Release generic-iOS build and static analysis passed unsigned. Synthetic build-number and entitlement tests passed.
- [x] iOS 18 minimum deployment, iPhone and iPad device families, and all four required iPad orientations. Release device-family validation passed against the built application.
- [x] Release configuration selects Production iCloud; Debug selects Development. Required sharing/custom invitation URL configuration is present. Signing configuration and capabilities were not changed by this audit.
- [x] Human-reported October 10 Console inspection of `FamilyLifecycleAuthority` Production type and fields: `formatVersion` Int64 and `state` String. This audit did not independently verify current Production configuration, security roles or device behavior.
- [x] Privacy manifest lists linked names, optional allowance financial information, user/device identifiers, and household/chore content for app functionality, with no tracking and UserDefaults reason `CA92.1`. Final archive/report and store responses still need confirmation.
- [x] No advertising, analytics, ATT/IDFA, telemetry SDK, third-party dependencies, developer account service, or custom family-data backend in the audited source.
- [x] Camera permission explains invitation scanning and has a manual fallback. Optional notification authorization and generic private alerts are integrated; signed APNs delivery remains unproved.
- [x] Production has no sample-family seeding, debug clocks, UI-test resets, or synthetic invitation fixtures. Tests use a separate compile-gated store.
- [x] Creator-only confirmed Delete All Data and retained-receipt Finish Deleting recovery are present. Authenticated deleted/exactly revoked installations have local Reset App recovery; transient failures do not enable it. The merged receipt-lost owner recovery reconstructs exact account/household/attempt proof and finalizes authenticated `deleted` authority before releasing membership. Signed recovery evidence remains required; `deleting` authority alone cannot authorize child reset.
- [x] Historical date/archive, reassignment history, and exclusive-lifecycle regressions supersede the three queued historical followups. See the release evidence for each tested source baseline.
- [x] Privacy/support links are wired into first-run and role UI. [The privacy audit](privacy-audit.md) and [content review](quotes-and-attribution.md) describe the details.

## Final device and accessibility pass

On the integrated signed candidate, check launch/relaunch and background/foreground recovery, camera denial/manual entry, airplane-mode queued work and later convergence, longest chore/member text, largest Dynamic Type, dark mode, reduced motion, status contrast, 44-point controls, and physical-device VoiceOver reading/action order. Include iPad portrait and landscape. Existing Simulator/accessibility evidence is useful but does not prove this final combined UI or physical-device experience.

For the integrated notifications, check explicit contextual opt-in, denial/revocation, device-local settings, lock-screen privacy, correct eligible-child targeting, duplicate suppression/relaunch, and usability with alerts disabled. `UIBackgroundModes` includes `remote-notification` in source. Final signing/APNs entitlements and provisioning, Production roles/schema, private/shared subscriptions for receiving accounts, and signed two-account/device evidence remain human release prerequisites. Delivery is best effort; local alerts after refresh do not prove remote/background delivery.

- [x] Native iPhone and iPad target with iOS 18.0 minimum deployment, both device families enabled, and all four iPad multitasking orientations declared.
- [x] All targets and Debug/Release inherit marketing version and build number from [Version.xcconfig](../../Configuration/Version.xcconfig). Archive and Upload resolves that project build number, rejects reruns, and validates the built version. Before another upload, increment the project build number beyond the latest uploaded build; starting a new workflow does not assign a new number.
- [x] Release builds select the Production iCloud environment. Debug builds select Development.
- [x] Explicit iCloud, CloudKit, sharing, custom invitation URL, and one-time-link entitlement configuration.
- [x] Generated launch screen and app display name configuration.
- [x] Opaque sRGB 1024 by 1024 app icon wired to the application target.
- [x] No Swift package, CocoaPods, binary framework, advertising, analytics, telemetry, crash-reporting, ATT, or IDFA dependency.
- [x] Camera purpose string accurately describes invitation QR scanning.
- [x] Protected API usage is documented in the [privacy audit](privacy-audit.md#implementation-findings).
- [x] UI-test store, reset arguments, synthetic invitations, dark-mode control, and weekly fixture are guarded by `DEBUG`; the weekly fixture file is also compile-gated.
- [x] Production store creation does not seed sample data.
- [x] Settings exposes one confirmed Delete All Data action to the creating parent. Authoritatively deleted or revoked participant installations expose a separate confirmed local Reset App recovery action.
- [x] No application logging calls were found that expose family names, chore content, invitation URLs, or invitation codes.
- [x] App Store upload workflow manually signs with supplied distribution assets, validates the certificate and profile before archiving, reserves temporary API-key material for upload, cleans temporary release material on exit, and preserves the project build number without committing signing credentials.
- [x] App Store profile validation accepts scalar or flat string allowlists, recognizes the CloudKit service wildcard, and fails closed unless the profile authorizes Production iCloud, the Earned It container, CloudKit, and `InProcessOneTimeLinks`.
- [x] Build products, Derived Data, Xcode user state, `.env` files, and local artifacts are ignored.
- [x] Existing unit, service, UI, sharing, invitation, onboarding, scheduling, allowance, and business-rule tests are present.
- [x] Application text was reviewed for attribution. The [content review](quotes-and-attribution.md#application-text) owns the current findings.

Apple sources were checked October 10, 2026. Recheck at submission if requirements change.

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): completeness and accurate metadata, privacy/deletion, review access, notification privacy, artwork rights, and family/Kids positioning. See [the system artwork review](quotes-and-attribution.md#system-artwork-and-names) for emoji restrictions.
- [Upcoming submission requirements](https://developer.apple.com/news/upcoming-requirements/): Xcode 26 or later with the corresponding iOS/iPadOS 26 SDK or later, plus the current age-rating questionnaire. Minimum deployment and build SDK are different settings.
- [Required App Store properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties), [app privacy details](https://developer.apple.com/app-store/app-privacy-details/), and [managing app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications): follow [the visual asset specification](visual-assets.md#required-app-store-screenshots) for required sets and image constraints.
- [Notification authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications), [CloudKit sharing permissions](https://developer.apple.com/documentation/cloudkit/ckshare), and [database subscriptions](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription). Silent delivery requires the background-mode configuration and a subscription for the receiving account; notifications signal changes to fetch and may coalesce.

The configured no-mistakes pipeline owns validation and PR delivery. It does not authorize signing changes, Production operations, App Store Connect writes, uploads, merging, or submission.

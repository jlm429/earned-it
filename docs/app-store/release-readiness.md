# App Store Release Readiness

Audit date: September 16, 2026. This checklist reflects the repository at version 1.0 and does not assert the state of Apple Developer or App Store Connect accounts unless repository evidence supports it.

## Blocking

- [ ] Publish the privacy policy at a stable public URL and enter that URL in App Store Connect. The repository is public, so the merged `docs/app-store/privacy-policy.md` page can serve as the URL if that hosting choice is accepted.
- [ ] Add the same privacy policy URL to the shipping app. The source now includes a link, but it becomes valid only after this branch is merged to `main`.
- [ ] Confirm the app icon artwork is owned or licensed for commercial use. The repository contains no provenance or license record for the artwork.
- [ ] Confirm that system-rendered emoji avatars are acceptable in the shipping app and screenshots under current Apple review and artwork rules, or approve a separate owned-art replacement before release.
- [ ] Replace or approve the current icon treatment before submission. It is a valid opaque 1024 by 1024 PNG, but the artwork includes its own rounded tile and white corners before iOS applies the system mask.
- [ ] Capture at least one accurate App Store screenshot from the release candidate at an accepted iPhone size. The tracked `assets/earned-it-preview.png` is stale, shows an older interface and icon, says iOS 17+, and incorrectly says data stays only on device.
- [ ] Complete a signed release-candidate pass on physical devices with two separate iCloud accounts. Cover owner creation, parent and child invitations, cold and warm acceptance, QR and link delivery, completion sync, relaunch, recovery, read-only behavior, and revocation.
- [ ] Confirm the production CloudKit schema contains every record type and field used by `CloudKitHouseholdTransport.swift`. Existing reports say a production schema was deployed and used by TestFlight, but this repository audit cannot inspect the live container.
- [ ] Create and verify the public `FamilyLifecycleAuthority` type in Development exactly as documented in [family-lifecycle-authority.md](../family-lifecycle-authority.md), complete signed two-account deletion safety checks, then have an authorized human promote that schema to Production. Do not distribute this change before the type and creator-only write rule are confirmed.
- [ ] Confirm the distribution profile admits `InProcessOneTimeLinks` and that the archived app contains the expected iCloud and extended-share-access entitlements.
- [ ] Complete required App Store Connect values, agreements, tax and banking status where applicable, age rating, privacy responses, pricing set to Free, territories, export compliance, content rights, copyright, review contact, and release method.

## Should do before release

- [ ] Run an Xcode Organizer archive validation and inspect the exported privacy report, entitlements, icon warnings, and embedded `PrivacyInfo.xcprivacy`.
- [ ] Test camera denial and the manual invitation-code fallback on a physical iPhone.
- [ ] Verify the final app name and bundle ID are registered to the intended App Store Connect record. Current source values are `Earned It` and `com.jlm429.EarnedIt`.
- [ ] Use the TestFlight workflow to upload a release candidate, then complete internal TestFlight smoke testing before selecting the build for review.
- [ ] Confirm the GitHub Issues page is an acceptable public Support URL, or provide another real support page. Do not submit a placeholder.
- [ ] Confirm the App Store privacy answers against the generated privacy report. The likely declarations are listed in [privacy-audit.md](privacy-audit.md).
- [ ] Decide whether the repository will remain source-available with no license or receive an explicit license from the rights holder.
- [ ] Review historical engineering reports for public tone and remove machine-specific paths in a later documentation-only cleanup. They are not linked from the public README.
- [ ] Consider running CI on pull requests rather than only by manual dispatch. The present workflow is deterministic but `workflow_dispatch` only.

## Nice to have

- [ ] Produce a simple wordmark or horizontal lockup derived from approved brand artwork.
- [ ] Add localized App Store metadata and screenshots if the app is marketed outside English-speaking storefronts.
- [ ] Add optional dark and tinted icon appearances after the primary icon is approved.
- [ ] Add a dedicated support page with private contact instructions instead of relying on public GitHub Issues.
- [ ] Add a short App Store preview video only if it accurately improves the listing. Apple does not require one.

## Already complete

- [x] Native iPhone target with iOS 18.0 minimum deployment and iPhone-only device family.
- [x] Marketing version 1.0 and a CI build-number strategy based on GitHub run number and attempt.
- [x] Release builds select the Production iCloud environment. Debug builds select Development.
- [x] Explicit iCloud, CloudKit, sharing, custom invitation URL, and one-time-link entitlement configuration.
- [x] Generated launch screen and app display name configuration.
- [x] Opaque sRGB 1024 by 1024 app icon wired to the application target.
- [x] No Swift package, CocoaPods, binary framework, advertising, analytics, telemetry, crash-reporting, ATT, or IDFA dependency.
- [x] Camera purpose string accurately describes invitation QR scanning.
- [x] No location, contacts, photos, microphone, notifications, health, Bluetooth, or other protected-data permission in source or configuration.
- [x] UI-test store, reset arguments, synthetic invitations, dark-mode control, and weekly fixture are guarded by `DEBUG`; the weekly fixture file is also compile-gated.
- [x] Production store creation does not seed sample data.
- [x] Local deletion and shared-device disconnect require confirmation. Disconnect leaves other devices and iCloud data intact and blocks while ordinary changes are pending.
- [x] No application logging calls were found that expose family names, chore content, invitation URLs, or invitation codes.
- [x] App Store upload workflow uses temporary API-key material, cleans it on exit, and overrides the build number without committing signing credentials.
- [x] Build products, Derived Data, Xcode user state, `.env` files, and local artifacts are ignored.
- [x] Existing unit, service, UI, sharing, invitation, onboarding, scheduling, allowance, and business-rule tests are present.
- [x] Attributed daily quotations were replaced with unattributed product microcopy. The remaining rights and attribution findings are documented in `quotes-and-attribution.md`.

## Manual archive inspection

Before submission, inspect the selected archive rather than relying on project settings alone:

1. Confirm `CFBundleIdentifier`, `CFBundleShortVersionString`, and `CFBundleVersion`.
2. Confirm the signed entitlements use the intended production container and include `InProcessOneTimeLinks`.
3. Confirm `PrivacyInfo.xcprivacy`, the app icon, and the camera purpose string are embedded.
4. Generate the privacy report and reconcile it with App Store Connect.
5. Validate and upload through the authorized signing workflow. Do not let a local agent alter certificates, profiles, containers, or schema.

## Apple submission references

- [Required App Store metadata](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [Age rating questionnaire](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating)
- [CloudKit production deployment](https://developer.apple.com/icloud/cloudkit/designing/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

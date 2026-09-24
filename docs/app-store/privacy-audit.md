# Privacy Implementation Audit

Audit date: September 24, 2026.

## Implementation findings

| Area | Finding |
| --- | --- |
| Advertising | None. No advertising frameworks, SDKs, or network integrations were found. |
| Analytics and telemetry | None. No analytics, telemetry, logging backend, or third-party crash SDK was found. |
| Tracking | None. No ATT prompt, IDFA access, tracking domain, data broker, or cross-company data linkage was found. |
| Dependencies | No Swift packages, CocoaPods dependencies, binary frameworks, or third-party libraries are configured. |
| Network services | Apple's CloudKit is the only application data service. The system share sheet can deliver an invitation through services the person chooses. |
| Camera | VisionKit's data scanner reads Earned It QR invitations. The app declares `NSCameraUsageDescription`, does not retain images, and offers manual code/link entry. |
| Notifications | No user-notification framework, permission request, or push-notification entitlement was found. Synchronization is foreground/local-change/pull-to-refresh driven. |
| Other protected APIs | No location, contacts, photos, microphone, speech, health, motion, HomeKit, Bluetooth, NFC, calendar, or biometric access was found. |
| Local data | SwiftData stores family facts and a device session in Application Support. Debug UI tests use a separate Documents store only under `DEBUG`. Account-wide deletion clears the journal, current and historical stores, the app cache, and the app's UserDefaults domain after cloud cleanup completes. |
| iCloud data | Family facts use the owner's private CloudKit zone and invited participants' shared database. Private account-membership and validation records bind the iCloud participant to one household membership. Public lifecycle records prevent deleted families from being restored as active. |
| Identifiers | The journal contains generated household, member, device, record, invitation, and CloudKit participant identifiers. It does not request an advertising identifier. |
| Logging | Family-transition diagnostics use unified logging with allow-listed comparison results and CloudKit error metadata. The app has no logging backend or third-party telemetry. |
| Required-reason APIs | Account-wide deletion clears the app's own UserDefaults domain. `PrivacyInfo.xcprivacy` declares UserDefaults reason `CA92.1`. The app does not use the covered file-timestamp, system-boot-time, or disk-space APIs identified in source. |

## Privacy manifest

`EarnedIt/PrivacyInfo.xcprivacy` declares no tracking domains and declares UserDefaults reason `CA92.1`. It declares the data types that the app retains off device through CloudKit for app functionality:

- names;
- other financial information for optional allowance amounts;
- user identifiers;
- device identifiers;
- other user content, including household and chore data.

Each type is declared as linked to the user, not used for tracking, and used only for app functionality. The final signed archive's generated privacy report must be compared with this source manifest and the App Store Connect answers.

## Likely App Store Connect privacy answers

Select **Yes, we collect data from this app** because family data is transmitted off device and retained in readable CloudKit records for synchronization. Declare the following, subject to final confirmation in App Store Connect:

| App Store data type | Linked to identity | Tracking | Purpose |
| --- | --- | --- | --- |
| Name | Yes | No | App Functionality |
| Other Financial Info | Yes | No | App Functionality |
| User ID | Yes | No | App Functionality |
| Device ID | Yes | No | App Functionality |
| Other User Content | Yes | No | App Functionality |

Do not declare advertising, marketing, analytics, product personalization, or tracking purposes based on the inspected implementation.

Apple's guidance says developers are not responsible for disclosing data collected by Apple itself. If the developer separately enables or uses an Apple-provided service in a way that gives the developer retained app data, reassess the answers before submission.

Relevant Apple references:

- [App privacy details definitions](https://developer.apple.com/go/?id=info-1)
- [Managing app privacy in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [User privacy and data use, including tracking definitions](https://developer.apple.com/app-store/user-privacy-and-data-use/)
- [Privacy manifest files](https://developer.apple.com/documentation/BundleResources/privacy-manifest-files)

## “Free. No ads. No tracking.”

The claim is accurate for the inspected app code and dependencies:

- no purchase or subscription implementation exists;
- no advertising code or SDK exists;
- no behavioral analytics or third-party telemetry exists;
- no ATT or IDFA access exists;
- CloudKit family synchronization is app functionality, not tracking across other companies' apps or websites.

The App Store price must still be manually set to Free. Apple's own App Store, iCloud, diagnostic, and crash processing remains subject to Apple's settings and policies and should not be represented as Earned It first-party tracking.

# Earned It

<img src="EarnedIt/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="Earned It app icon">

**A simple shared chore app for families.**

Earned It gives parents and children one clear place to see what needs doing, mark work complete, and follow weekly progress together.

**Free. No ads. No tracking.**

## What it does

- Shares family chore lists across invited iPhones.
- Gives parents and children role-appropriate views and controls.
- Supports repeating weekday chores and chores that are available only when needed.
- Assigns chores to every child, one child, or a group of children who alternate turns.
- Lets children mark their own work while parents can review and correct family history.
- Shows weekly progress, streaks, and completed or missed work.
- Optionally tracks whether a weekly allowance was earned. Earned It does not move money or record payments.
- Keeps working offline and synchronizes automatically through iCloud when a connection is available.

## How it works

One parent creates a family, adds children, and sets up chores. The family owner can invite another parent or a particular child with a private, one-time iCloud invitation. Each invited person sees the profile and permissions chosen for them.

Changes are saved on the device first. When family sharing is enabled, Earned It synchronizes the family journal through the owner's private CloudKit zone and the invited family's shared CloudKit access.

## Preview

Current App Store screenshots are still being prepared. The repository includes the shipping app icon above. See the [release asset specification](docs/app-store/visual-assets.md) for the screenshot plan and known branding work.

## Privacy

Earned It has no advertising, behavioral analytics, third-party tracking, or third-party telemetry SDKs. Family names, member names, chore details, progress, invitations, and optional allowance settings are stored locally and, when sharing is enabled, in private/shared iCloud storage for the invited family.

The developer does not operate a separate server for family data. Apple may process iCloud data and may provide platform diagnostics under Apple's own settings and policies. Earned It does not use that information to track people across apps or websites.

Read the full [privacy policy](docs/app-store/privacy-policy.md) and [privacy implementation audit](docs/app-store/privacy-audit.md).

## Requirements

- iPhone running iOS 18 or later
- An iCloud account and network access to share a family across devices
- Camera access only when scanning an invitation QR code. Invitation codes and links can also be entered without camera access.

Earned It can keep an unshared family locally on one iPhone. iCloud is required for invitations, recovery, and synchronization between family devices.

## Development

Open `EarnedIt.xcodeproj` in Xcode 26.6 or later. To run the deterministic unit and service suite without signing:

```sh
xcodebuild test \
  -project EarnedIt.xcodeproj \
  -scheme EarnedItCI \
  -destination 'platform=iOS Simulator,id=<simulator-uuid>' \
  -derivedDataPath .artifacts/DerivedData \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

Simulator builds do not establish live iCloud sharing behavior. Signed two-device testing with separate iCloud accounts remains part of release validation.

## Technical documentation

- [Shared household architecture and product invariants](docs/shared-household-architecture.md)
- [Technical behavior overview](docs/technical-overview.md)
- [App Store release readiness](docs/app-store/release-readiness.md)
- [App Store metadata draft](docs/app-store/metadata.md)
- [Quotes and attribution review](docs/app-store/quotes-and-attribution.md)
- [Agent guidance](AGENTS.md)

The source is currently published without an open-source license. Public visibility does not grant permission to reuse, modify, or redistribute it.

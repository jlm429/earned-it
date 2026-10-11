# Earned It 1.0.1 production cleanup

## Alternating As Needed chores

The prior projection advanced an As Needed alternating turn when Make Available wrote an activation. It had no inactive next-owner projection, so management UI could not show or skip the next child. The visible symptom was most confusing with three or more children because activation and rotation history were coupled.

The 1.0.1 projection derives exactly one owner from the complete saved participant order before activation. Make Available records that child's identity in the existing occurrence fact and assigns only that child. An accounted completion consumes the turn, while an incomplete activation retains it. Switching between Scheduled and As Needed preserves the next child. Entering alternating mode from a non-alternating configuration starts a new rotation and honors the parent's required first-child selection. Older 1.0 activations have no recorded owner and retain their original activation-based rotation, so the update cannot reassign an earlier occurrence or completion. A late offline skip cannot alter an explicitly assigned active occurrence. Archived and not-yet-active children are skipped. Parent management shows Whose Turn before activation and the assigned child while active. Child lists expose the occurrence only to its owner.

Skip writes an immutable fact containing the revision, civil day, acting parent, and expected next child. The expected child makes concurrent duplicate skips idempotent. Sequential skips continue through the saved order. The fact changes only future derivation and never edits a dated assignment or completion.

## Chore deletion

Affected UI now uses Delete Chore with ordinary family-list confirmation copy. Deletion writes a same-day archived revision and a durable deletion fact so current parent and child lists remove the chore immediately and a late offline edit cannot bring it back. If a next-day edit is already pending, deletion also writes a next-day archived revision to keep configuration views consistent.

The first valid deletion in deterministic fact order owns the deletion-time snapshot. That snapshot preserves resolved current-day Done, Missed, legacy Not Needed, and excused outcomes while dropping Unmarked obligations. Facts ordered after that deletion remain stored but cannot rewrite the chore's active state or history, and duplicate deletions cannot replace the first snapshot. Earlier facts continue to produce history. Permission checks reject mutation of a deleted projection. Normal foreground synchronization and pull-to-refresh deliver the same deletion fact to stale installations, which then hide the chore even if they upload retained local facts. The exact domain contract is maintained in [Shared household architecture](shared-household-architecture.md).

## Permanent family deletion

The permanent-deletion contract has since gained owner-authenticated lifecycle authority and terminal child cleanup. Its authoritative behavior is maintained in [Shared household architecture](shared-household-architecture.md), with the CloudKit record and schema contract in [Family lifecycle authority](family-lifecycle-authority.md).

## Shipping device support and adaptive layout

Version 1.0 was iPhone-only because every Debug and Release app and test configuration set `TARGETED_DEVICE_FAMILY = 1`. The project already supported the iOS device and Simulator platforms, so App Store delivery generated only an iPhone application rather than a native iPad application.

The adaptive SwiftUI improvements remain in 1.0.1. High-density dashboards and child content use readable maximum widths, and the compact empty-state presentation avoids a larger-screen illustration overlap. Test targets remain iPad-capable so this layout can continue to be exercised.

The shipping application target intentionally remains `TARGETED_DEVICE_FAMILY = 1` in both Debug and Release. Version 1.0.1 therefore remains an iPhone application and does not add native iPad availability or create an iPad screenshot requirement in App Store Connect. It can still appear on iPad through Apple's iPhone compatibility behavior, not as the native full-screen iPad app originally investigated. A Release metadata validator rejects an app or archive whose built `UIDeviceFamily` is anything other than the single value `1`, and both CI and Archive and Upload run that validator.

The existing iOS App Store Connect record remains unchanged. A human should continue to review the ordinary 1.0.1 description, release notes, privacy answers, accessibility declarations, and review notes, but no new iPad screenshots or iPad-specific metadata are required for this release. Apple's screenshot specification marks iPad screenshots as required only when the app runs natively on iPad. See [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

## Version and build numbers

Historical 1.0.1 metadata used marketing version `1.0.1` and local fallback build `15`, newer than released build `14.1`. Its upload lane generated build numbers from workflow runs; that policy has been superseded. Current version metadata and upload-number requirements are maintained in the [release checklist](app-store/release-readiness.md#final-device-and-accessibility-pass). No build was uploaded by this historical change.

Apple associates a build with its bundle ID and version and uses the build string as its unique identifier. See [Apple build upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds) and [CFBundleVersion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion).

## Release safety

The work does not change the bundle ID, deployment target, signing style, team, entitlements, iCloud container, certificate configuration, or CloudKit schema. Release fixture exclusion remains controlled by the existing `#if DEBUG` boundary. No TestFlight or App Store upload, Production CloudKit mutation, schema deployment, certificate change, or merge is part of this implementation.

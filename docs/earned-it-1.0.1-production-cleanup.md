# Earned It 1.0.1 production cleanup

## Alternating As Needed chores

The prior projection advanced an As Needed alternating turn when Make Available wrote an activation. It had no inactive next-owner projection, so management UI could not show or skip the next child. The visible symptom was most confusing with three or more children because activation and rotation history were coupled.

The 1.0.1 projection derives exactly one owner from the complete saved participant order before activation. Make Available records that child's identity in the existing occurrence fact and assigns only that child. An accounted completion consumes the turn, while an incomplete activation retains it. Older 1.0 activations have no recorded owner and retain their original activation-based rotation, so the update cannot reassign an earlier occurrence or completion. A late offline skip cannot alter an explicitly assigned active occurrence. Archived and not-yet-active children are skipped. Parent management shows Whose Turn before activation and the assigned child while active. Child lists expose the occurrence only to its owner.

Skip writes an immutable fact containing the revision, civil day, acting parent, and expected next child. The expected child makes concurrent duplicate skips idempotent. Sequential skips continue through the saved order. The fact changes only future derivation and never edits a dated assignment or completion.

## Chore deletion

Affected UI now uses Delete Chore with ordinary family-list confirmation copy. Deletion writes a same-day archived revision and a durable deletion fact so current parent and child lists remove the chore immediately and a late offline edit cannot bring it back. If a next-day edit is already pending, deletion also writes a next-day archived revision to keep configuration views consistent.

Unfinished current obligations disappear. Accounted current-day contributions remain in a hidden deleted projection so allowance and streak calculations keep their completed meaning. Earlier facts remain unchanged and continue to produce history. Permission checks reject mutation of a deleted projection. Normal foreground synchronization and pull-to-refresh deliver the same deletion fact to stale installations, which then hide the chore even if they upload a retained local edit.

## Permanent family deletion

The destructive action appears only when the selected profile is the original creating parent and the current CloudKit location is owner-controlled. CloudKit performs the final ownership check against the creator's private database.

After two explicit confirmations, deletion follows this order:

1. Revalidate the current iCloud participant.
2. Delete the creator-owned household record zone, including its family facts, invitations, and zone-wide share.
3. Conditionally release the creator account's exact membership lock.
4. Clear local family data only after both cloud operations succeed.

A missing zone is a successful idempotent retry. Network, account, or membership cleanup failures remain visible and keep local state for retry. Relaunch can resume after the zone was deleted but before lock release; the creator also has a Finish Deleting Family action if a later sync observes lost cloud access. Invited devices that later fetch the missing family suspend writes, release their own exact lock when possible, and show a disconnected cleanup state. A fresh installation cannot recover the deleted family, and its old invitation is invalid. Startup retains an otherwise inaccessible account membership because missing local state alone cannot distinguish permanent deletion from ordinary participant revocation. When that account accepts a new family's invitation, the join path confirms that the old family is inaccessible, conditionally releases the exact old membership, and claims the new family. Network failures preserve the membership and retry path. An offline stale device cannot recreate the family because synchronization fetches the zone before uploading. Disconnect This Device, Remove Local Data, app deletion, and reinstall recovery do not call permanent cloud deletion.

These behaviors are covered with the transport double. They do not prove signed, two-account Production CloudKit behavior, and Production data was not used destructively.

## Shipping device support and adaptive layout

Version 1.0 was iPhone-only because every Debug and Release app and test configuration set `TARGETED_DEVICE_FAMILY = 1`. The project already supported the iOS device and Simulator platforms, so App Store delivery generated only an iPhone application rather than a native iPad application.

The adaptive SwiftUI improvements remain in 1.0.1. High-density dashboards and child content use readable maximum widths, and the compact empty-state presentation avoids a larger-screen illustration overlap. Test targets remain iPad-capable so this layout can continue to be exercised.

The shipping application target intentionally remains `TARGETED_DEVICE_FAMILY = 1` in both Debug and Release. Version 1.0.1 therefore remains an iPhone application and does not add native iPad availability or create an iPad screenshot requirement in App Store Connect. It can still appear on iPad through Apple's iPhone compatibility behavior, not as the native full-screen iPad app originally investigated. A Release metadata validator rejects an app or archive whose built `UIDeviceFamily` is anything other than the single value `1`, and both CI and Archive and Upload run that validator.

The existing iOS App Store Connect record remains unchanged. A human should continue to review the ordinary 1.0.1 description, release notes, privacy answers, accessibility declarations, and review notes, but no new iPad screenshots or iPad-specific metadata are required for this release. Apple's screenshot specification marks iPad screenshots as required only when the app runs natively on iPad. See [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

## Version and build numbers

The project marketing version is `1.0.1` and its local fallback build is `15`, the first integer newer than released build `14.1`. Archive and Upload computes `14 + GITHUB_RUN_NUMBER`. Workflow run numbers increase across future invocations, so uploaded builds remain simple monotonically increasing integers across marketing versions.

`GITHUB_RUN_ATTEMPT` must equal `1`. A GitHub rerun therefore stops before archive instead of reusing the prior build number. A retry uses a new workflow dispatch and receives a new run number. Concurrency serialization prevents overlapping Archive and Upload jobs. The semantic script verifies digit-only Apple-valid values, `15 > 14.1`, later monotonic values, rerun refusal, and the four-digit upper bound. No build is uploaded by this change.

Apple associates a build with its bundle ID and version and uses the build string as its unique identifier. See [Apple build upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds) and [CFBundleVersion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion).

## Release safety

The work does not change the bundle ID, deployment target, signing style, team, entitlements, iCloud container, certificate configuration, or CloudKit schema. Release fixture exclusion remains controlled by the existing `#if DEBUG` boundary. No TestFlight or App Store upload, Production CloudKit mutation, schema deployment, certificate change, or merge is part of this implementation.

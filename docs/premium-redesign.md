# Earned It 1.1.0 design and QA

The refresh makes daily effort easier to see, chore completion more satisfying,
and the family experience more welcoming. It uses SwiftUI, system typography,
SF Symbols, and the existing app's own data and actions.

## Presentation

- Warm ivory canvas, white cards, deep teal feature surfaces, mint progress, and
  restrained gold streak accents. Dark mode uses deep blue-green surfaces and
  lighter semantic colors. Rounded display headings pair with standard body text.
- Parent home presentation follows the [current interface guide](family-polish.md#interface).
  Progress cards combine each child's name, streak, required
  item counts, weekly state, and allowance eligibility.
  The daily picture starts from the chore cards' visible list, then omits Not Needed
  occurrences and chores without eligible children from its counts. It counts chore
  outcomes rather than individual child contributions. Deleted chores do not
  contribute to daily totals; their outcomes remain in weekly progress and history.
- Child home hierarchy follows the [current interface guide](family-polish.md#interface).
  The amount is allowance eligibility, not a payment or an earned balance.
- Completed chore cards have a restrained tinted surface, seal, state symbol,
  and text. Completion controls respond to presses and replace state symbols.
  Success haptics occur only after a successful local store action. A remote
  refresh cannot replay completion haptics. Existing one-time weekly celebration
  consumption still controls the accomplishment feedback. Clearing an accomplishment
  after a correction or rollover does not emit success feedback.
- Family management introduces the household, keeps all existing management
  actions, and adds derived child progress and streaks to member rows. Setup,
  member forms, settings, weekday lists, and history share the same visual language.
- iPad home layouts place daily work and weekly context alongside each other.
  Accessibility text sizes return to a single column. Dates and long titles wrap;
  whole member controls flow onto another row. Compact member names are used only
  when unique in the family. Full names remain in accessible labels and identifiers.

`AppTheme.swift` owns the presentation tokens, surfaces, rings, responsive columns,
press style, and motion preference. `ViewSupport.swift` owns the semantic allowance
fields. Business rules remain in their existing services. There are no model,
journal, permission, transport, invitation lifecycle,
or allowance calculation changes. The only startup additions are DEBUG Simulator
marketing data and DEBUG appearance QA hooks.

## Accessibility and motion

Status uses symbols and text alongside color. Critical controls retain their
existing accessibility identifiers, labels, hints, and actions. Native list rows
have a 52-point minimum, while completion buttons and state menus retain at least
44-point targets. Profile headers, week strips, and home columns adapt to the
largest accessibility text sizes. Progress ring graphics grow at accessibility
sizes and expose their full counts as accessible text.

The system Reduced Motion preference disables press scaling, progress interpolation,
state-symbol replacement, and card/celebration animations. A DEBUG-only override
can request the same behavior during UI QA; it cannot turn off the system setting.
Haptic feedback remains independent of motion.

Calculated text contrast: secondary text against the standard surface is 6.35:1
in light mode and 8.66:1 in dark mode; accent text is 6.63:1 and 8.52:1. On the
brightest part of the teal feature surface, primary text is 6.75:1 and supporting
text is 5.05:1. Increased Contrast retains stronger card outlines.

## Before and after

[Native comparison captures](premium-redesign-evidence/README.md) hold the existing
weekly fixture and calendar day constant. They show the parent and child screens
before and after the refresh. The local portable Lavish comparison uses the app's
own design tokens and actual screenshots, with no external publishing.

## Marketing assets and release scope

See [the six native screenshots and reproduction recipe](../marketing-assets/1.1.0/README.md).
The Smith demo uses a dedicated Simulator journal, disabled activity alerts, no
CloudKit transport, and real store operations. Tests cover explicit opt-in,
real derived streak and allowance outcomes, relaunch identity preservation, and
absence of invitations and claims. Release and physical-device builds omit the
fixture. The PNG conversion script verifies native dimensions, upright orientation,
and opaque input, then writes RGB without cropping or scaling.

The branch bumps the minor version and build for the redesign; [Version.xcconfig](../Configuration/Version.xcconfig)
owns both values for every target and configuration. Signing, bundle identifiers, entitlements,
CloudKit containers and schema, submitted release, app icon, pricing, and App Store
metadata are untouched. No TestFlight upload, archive, release operation, or merge
is part of this delivery.

## Native audit corrections

Native captures reproduced a crowded parent navigation title, an empty sync-status
list row, tracked feature-heading clipping, and a short currency Text with a long
custom accessibility label. The fixes shorten the navigation title, render sync
status only when meaningful, use untracked flexible headings, and expose allowance
as a semantic label/value field. Every native audit remains enabled and every issue
is still recorded. A focused regression brings Remy's allowance fully into view
before checking its label/value and running the audit.

The heading counterfactual changed only tracking and cleared ordinary and largest
Dynamic Type phone audits. The currency counterfactual changed only the parent
amount's accessibility label and cleared its iPad screen, then identified the same
mismatch in Manage Family. The semantic field passed the full iPad flow without
changing printed amounts, typography, or calculations.

## Pre-pipeline local validation

The following evidence predates the no-mistakes review fixes and refreshed captures.
It records the initial redesign QA, not validation of the current pipeline revision.
Evidence bundles and full logs are
under `/Users/jlm429/Documents/gitstuff/firstmate/data/earned-it-premium-redesign/`.
The toolchain is Xcode 27.0 (27A266a), using iOS 26.5 Simulator.

| Final evidence | Result |
| --- | --- |
| `verified-phone.xcresult` | All 442 unit tests and all three selected UI flows passed. |
| `verified-ipad.xcresult` | Setup/reset and the same premium UI flow passed on the 13-inch iPad. |
| `verified-release.log` | Unsigned Release build passed; version 1.1.0 (54), iPhone/iPad device-family and orientation metadata validated. |
| Semantic scripts | Build-number and provisioning-profile entitlement semantic checks passed using synthetic inputs. |
| Release binary check | No marketing fixture names, demo flags, or appearance QA arguments occur in Release. |
| `screenshot-validation.json` | All six native captures verified as requested-size, upright, opaque, 8-bit RGB PNGs. Each image was visually inspected. |

The three focused flows are setup/duplicate prevention/confirmed local reset at the
largest text size; weekly allowance/history/grace/celebration/rollover/relaunch; and
premium parent/child screens, forms, settings, Activity, history, sibling completion
independence, persistence, and native accessibility audits. The iPad setup flow also
checks landscape at the largest size. The premium flow checks ordinary light mode,
dark mode with largest Dynamic Type, and reduced motion on both devices.

The 76 app/test/config source hashes in `final-source-sha256.json` remained unchanged
through those pre-pipeline builds and tests. That manifest bounds this evidence to
those source bytes, not the later review fixes or UI-test edits. Unit coverage includes the protected transport,
permissions, invitations, membership/deletion/recovery, recurrence, sibling states,
scoring, streaks, and allowance rules. No failure remained in those completed runs.

The active no-mistakes pipeline owns current review, testing, refreshed screenshot
validation, publication, and the update of [existing PR 49](https://github.com/jlm429/earned-it/pull/49).
Its Test phase owns the current revision and run linkage for passing evidence.
The premium native flow includes a deleted-chore dashboard regression through real
store actions, while the weekly flow checks correction, receipt consumption, and
rollover. The role-equivalence flow remains separate evidence of sibling permissions.
These flow descriptions do not claim a current passing result.
GitHub CI is explicitly skipped for this run. Both workflow files remain manual-only;
no merge, TestFlight upload, or App Store operation is authorized by this delivery.

Simulator and transport-double tests do not prove signed two-account CloudKit
behavior, APNs delivery, or physical-device haptics. Existing production invitation,
membership recovery, and release evidence remains authoritative for those checks.
Campaign artwork and submission inputs require human review.

# Earned It 1.1.0 native screenshots

These six files show the actual SwiftUI app. They contain no marketing overlays,
icon changes, generated imagery, or fabricated interface. All use the fictional
Smith family: Alex Smith, Remy Smith, and Piper Smith.

| File in each device folder | Screen | What it shows |
| --- | --- | --- |
| `daily-chores.png` | Alex's Today (family overview) | Shared daily chores, independent sibling states, alternating assignment, and daily progress. The iPad also shows weekly progress alongside the chores. |
| `progress.png` | Remy's Today | $12 weekly allowance eligibility, genuine weekly counts, a nine-day streak, and the dated week strip. The iPad also shows the completed prior week's accomplishment. |
| `family.png` | Manage Family | The Smiths, parent and child profiles, each child's derived progress, streak, allowance, and native family-management controls. |

`iphone-6.5/` contains native 1242 x 2688 captures from iPhone 11 Pro Max.
`ipad-13/` contains native 2064 x 2752 captures from iPad Pro 13-inch (M5).
Every delivered image is an upright, opaque, 8-bit RGB PNG in sRGB. No image was
stretched, cropped, or placed on another device's canvas.

For the separate supplied README artwork, see the [repository banner specification](../../docs/app-store/visual-assets.md#repository-banner).

## Reproduce

Use Xcode 27.0 with iOS 26.5 Simulator. Build the Debug app with signing disabled.
The demonstration fixture is compiled only for DEBUG Simulator builds and requires
both `--ui-test-store` and `--marketing-demo`. It writes only
`Documents/marketing-demo-only.store`, uses no CloudKit transport, disables activity
alerts, and never creates invitations, claims, locks, or CloudKit membership records. Normal
app and UI-test stores are separate. Release and physical-device builds exclude it.

Launch the app on a disposable Simulator with these arguments:

```text
--ui-test-store --ui-test-reset --marketing-demo --marketing-member=alex-smith
-AppleLanguages (en) -AppleLocale en_US
```

The initial seed begins October 5, 2026, then advances the family clock to October 14.
Earlier dates are completed through normal store operations. Today's school bags
are still due. Both children have a nine-day streak and an earned prior week.
Remy's allowance is $12 and Piper's is $10. These are eligibility amounts, not
payments. All progress, assignments, history, and streaks use existing app rules.

Set Simulator orientation to portrait and its status bar to 9:41, full Wi-Fi,
and full battery. Capture Alex's Today, navigate to Manage Family, then relaunch
with `--marketing-member=remy-smith` without `--ui-test-reset` to capture Remy's
Today. The fixture retains family, member, chore, and fact identities on relaunch.
Reset only this dedicated demo journal by including the two demo flags and
`--ui-test-reset` again.

The focused XCUITest `testPremiumRedesignDemoAndAccessibility` automates these
three captures on either device, preserving named screenshot attachments in its
result bundle. It also checks completion persistence, independent sibling state,
major screens, dark appearance, largest Dynamic Type, and a DEBUG reduced-motion
override. Export native attachments with:

```sh
xcrun xcresulttool export attachments --path <results.xcresult> --output-path <raw-captures>
swift scripts/prepare-marketing-screenshot.swift <raw.png> <output.png> 1242 2688
# For iPad, use 2064 2752 instead.
```

The export script rejects wrong dimensions, orientation, and transparent pixels.
It removes the opaque alpha channel while retaining the native composition. It
verifies the resulting PNG uses RGB without alpha. See
[the design and QA report](../../docs/premium-redesign.md) for validation evidence.

Final campaign artwork, asset rights, and App Store submission remain human review
inputs. These files are source captures for that campaign, not promotional cards.

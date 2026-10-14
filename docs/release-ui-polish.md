# Release UI polish

The 1.1.0 redesign supersedes this earlier polish's palette, home layout, and
motion treatment. See [the design and QA report](premium-redesign.md) for current
presentation, shared components, accessibility, and motion behavior. The evidence
below describes the earlier polish only and does not validate the redesigned UI.

## Native verification

The selected toolchain is Xcode 27.0 (27A266a) with the available iOS 26.5 Simulator runtime. Verification uses dedicated task Simulators and DerivedData outside the repository:

- iPhone 17e: `A58ED931-8546-44E1-B071-9C676CB24B89`.
- iPad mini (A17 Pro): `1593C443-C13F-41BC-A986-991F31268484`.

The unmodified allowance/history UI flow was run before choosing the changes. It passed and supplied genuine baseline parent/child screenshots. The full unit suite passed 383 tests. Debug and unsigned Release builds passed. Build-number and provisioning-profile semantic checks passed. The first focused round passed setup/reset and allowance/history. Its text-clipping audit identified a week-date label at the largest size; the native element capture reproduced the issue before the wrapped-height correction. The corrected build passed the affected allowance/history flow and the parent/child flow with both sufficient-description and text-clipping audits. All three selected flows passed across the final verification rounds; no failure remains.

UI coverage is limited to three existing flows: setup and confirmed local reset at the largest text size; allowance/history, grace, celebration and relaunch; and parent/child controls at the largest text size. Screenshots use only synthetic `--ui-test-store` data. No actual family store, live invitation, production CloudKit record, or signing setting was touched.

Simulator and transport-double results do not validate signed two-account CloudKit behavior or human-confirmed App Store inputs. This UI work does not claim those release checks.

## Local review evidence

Task evidence lives under `/Users/jlm429/Documents/gitstuff/firstmate/data/earned-it-release-ui-polish/`. It is local and has not been published externally. The final comparison uses the app's own presentation tokens and screenshots of the running native app, rather than a mock interface.

- Baseline screenshots: `before/parent-today.png` and `before/weekly-current-week-start.png`, plus named allowance/history captures.
- Polished screenshots: `after/parent-today.png`, `after/weekly-current-week-start.png`, `after/weekly-earned-it-way-to-go.png`, `after/child-dark.png`, `after/ipad-parent-dark.png`, `after/ipad-parent-largest-text.png`, and `after/empty-parent-largest-text.png`. The pending-invitation attempt on the unsigned Simulator shows its expected iCloud-unavailable alert in `after/ipad-pending-icloud-alert-largest-text.png`; it is not evidence of live invitation acceptance.
- Test evidence: `baseline-ui.xcresult` (one baseline flow passed), `unit.xcresult` (383 tests passed), `polish-ui.xcresult` (setup/reset passed and the date-clipping issue reproduced), and `final-ui.xcresult` (both affected flows passed after correction). The setup/reset flow was not repeated because its behavior was unchanged by the subsequent date/glyph refinements.
- Review artifact: `visual-review.html` and the self-contained `visual-review-portable.html`, exported locally through Lavish. The comparison uses the app palette and was checked in Chrome at desktop and 390-point width with loaded images and no horizontal overflow.

These are engineering review captures, not approved App Store marketing screenshots. See [release readiness](app-store/release-readiness.md) for the remaining submission checks and [visual assets](app-store/visual-assets.md) for screenshot requirements.

## Profile selection follow-up

See the [product introduction](../README.md#what-it-does) for current home navigation.
Invitation claiming and account recovery retain their existing profile selection code. Review
whether creator-device and legacy shared-device switching permissions and the
underlying picker remain necessary after iCloud person binding. They are retained
for now; the profile selection change affects the home toolbar only.

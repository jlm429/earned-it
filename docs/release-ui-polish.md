# Release UI polish

## Visual direction

Earned It uses a warm cream canvas, terracotta navigation accents, and restrained teal, amber, blue, and plum accents. Rounded layered cards use a subtle gradient and outline instead of a flat white field. The palette adapts to dark mode with charcoal surfaces and pale accents. Native navigation, forms, menus, sheets, progress indicators, SF Symbols, and emoji avatars remain the visual foundation.

Parent and child profile headers share a warm introductory card. The child's current weekly summary uses a teal surface; the previous finished week uses a success tint when earned and amber when not earned. Weekly progress bars use the success tint when earned and the navigation accent otherwise, with a separate status badge retaining the week's status. Chore titles occupy their own full-width row above the member controls. Completed and Not Needed chores have distinct tinted surfaces while their text, symbols, and permitted actions retain the existing meanings. Quiet empty days use a leaf symbol with the existing explanatory copy. Pending synchronization has a tinted explanatory panel. Welcome and recovery screens use a consistent accent symbol and native controls.

## Shared presentation API

`EarnedIt/Views/Shared/AppTheme.swift` defines `canvas`, `surface`, `inset`, `border`, `secondaryText`, `accent`, `success`, `warning`, `info`, `danger`, and `personal`. These colors are presentation tokens only. `ThemedSurface(tint:cornerRadius:)` supplies a reusable layered surface. `SectionCard(tint:)` wraps content with the shared padding and surface; existing `SectionCard { ... }` calls remain supported. `SectionHeading(title:systemImage:)` pairs a decorative symbol with an accessible heading. `themedListBackground()` retains native list rows on the warm canvas.

Root styling is a tint modifier and recovery-view presentation. This change leaves store, transport, domain, configuration, and release settings unchanged.

## Accessibility and layout

- Status retains text and symbols in addition to color. Decorative symbols and avatars stay hidden from VoiceOver. Existing control identifiers, labels, hints, and actions remain available.
- Supporting text uses the adaptive `secondaryText` token for stronger contrast on tinted surfaces. Calculated supporting-text and semantic-color contrast is at least 5.1:1 against the strongest 13% layered tints in both appearances. Increased contrast strengthens card outlines.
- Profile cards switch to wider grid cells at accessibility sizes. Chore titles wrap independently from member controls. Every week strip switches to day rows at accessibility sizes, including the compact child summary. Week-date text uses explicit wrapped height. At accessibility sizes, allowance text gets the full card width without a decorative banknote beside it.
- Standalone action buttons and disclosure labels use 44-point minimum targets or native large control sizing. Fixed circular glyphs remain small enough to fit their containers at the largest text size; status text still scales.
- Scroll content is bounded to 760 points on wide layouts. Recovery content retains its 560-point bound and scrolls when needed.
- No custom animation was added. Reduced Motion retains native behavior without a new celebratory effect.

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

The 1.0.6 toolbar removes Switch Profile from parent and child homes. Invitation
claiming and account recovery retain their existing profile selection code. Review
whether creator-device and legacy shared-device switching permissions and the
underlying picker remain necessary after iCloud person binding. They are retained
for now; this release changes navigation only.

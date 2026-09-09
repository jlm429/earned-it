# Chore-flow implementation report

Branch: `fm/earned-it-immediate-children-compact-chores`. Initial implementation checkpoint: `9640cb0`. Resumed after captain pause via firstmate inbox `004.msg`; no pipeline owns the branch. Implementation and focused validation are complete. This report accompanies the implementation-gate commit on top of that checkpoint. Delivery stops at the committed implementation gate for firstmate to trigger no-mistakes, with a new PR and no autonomous merge.

## Diagnosis

- **Setup:** Both `pwd -P` and `git rev-parse --show-toplevel` verified `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it`. The initial worktree was clean. Before implementation, remote HEAD/main and the local base matched `d12c5081e649347d6ffa2198dfeb3944f9a0eae8`, the PR 5 merge following PR 4. The resumed inventory was clean at `9640cb0`, with no active tests or no-mistakes run on this branch. Doctor reported healthy infrastructure; no daemon lifecycle changes occurred.
- **Actual reproduction:** In the separate debug UI-test journal on iPhone 17e, create Test Family with Hanna and Alek, create today's all-children `Feed dog`, finish setup, mark Alek Done, add New Child through Family & Sharing, and return to Family Today. Observed: `Joins lists tomorrow`, no New Child on today's chore. Expected: New Child immediately Unmarked, Alek still Done. The native UI regression failed before production changes, and three independent executable domain/transport regressions repeated the exclusion.
- **Trigger:** Saving a new child after setup. **Masking conditions:** setup-time creation already uses today; tomorrow's configuration preview includes the new child; reaching the saved join day makes the child eligible. A different weekday remains inapplicable regardless of membership. **Visible symptom:** today's chore and profile selection exclude the new child. The completion card also duplicates names vertically and requires menus for ordinary changes.
- **Root cause and history:** `saveMember` deliberately saved tomorrow as every post-setup member's `joinedDay`, introduced by `1c12a8d` in PR 4. Daily responsibility generation and profile checks correctly honored that boundary. PR 5's `9aa7b40` aligned picker/save dates but did not introduce this behavior. The old membership policy is superseded for new children by the current request. No cache or CloudKit failure was observed.
- **Minimal counterfactual and proven path:** Changing only new children's persisted join boundary to the current household day made all three failing regressions pass, before the row redesign. Setup-time children already followed that working path. No chore revision or completion rewrite was needed.
- **Disconfirming checks:** Particular-child assignment is unchanged; future imported joins and explicit future chore starts remain future; current-day weekday applicability is respected; archived children are excluded from dates at/after archival; earlier Mondays gain no new-child obligations. Existing completion facts stay equal, and reversed delivery order produces the same snapshot.

Read and applied firstmate's diagnostic-reasoning skill and history handoff. Inbox instructions through `004.msg` were acknowledged. The project-memory helper found AGENTS.md and its CLAUDE.md pointer conformant.

## Implementation

New children persist today's fixed household civil date. New parent activation, archives, and chore edits retain their existing tomorrow boundary. New chore picker/save still use today; existing chore picker/save use tomorrow. Renames preserve the saved join date. All-children membership is derived from the applicable immutable revision and dated member facts, then combined with recorded assignment evidence. Reading a list creates no facts. Save, reload, import, and sync all use this projection, so a new child appears even if a sibling's prior contribution recorded fewer eligible members.

Native cards now wrap the chore title and every child control. Done/Not Needed have colored backgrounds; all states have distinct symbols, and Not Needed/Missed also show text. Each permitted control is at least 44 by 44 points and toggles Done directly, including undo. Context menus and VoiceOver actions retain other states. Today undo writes Unmarked; parent history undo writes Missed. Children see sibling status as read-only. Central store authorization still checks role, target, date, and cloud access. README, architecture, Add Child copy, and changelog match this behavior.

## Verification

All artifacts are under `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/`.

| Evidence | Result |
| --- | --- |
| `before-ui.xcresult`, `before-ui.log` | Expected failure: new child's control absent on the unchanged app. |
| `before-regressions.xcresult`, `.log` | All three new behavior regressions fail on original production code. |
| `counterfactual.xcresult`, `.log` | Same three pass after only the child join-date correction. |
| `after-tests.xcresult`, `.log` | 53 unit/integration tests pass. Picker/save timing and largest-type setup/reset/join-failure flows pass. Daily UI flow initially stopped on floating-point measurement of a 44-point control, corrected with 0.01-point assertion tolerance. |
| `typical-ui.xcresult`, `.log` | Added DST-boundary child creation and later rename checks pass. Separate UI audit identified the subtitle contrast issue, now corrected. |
| `final-small-dark-ui.xcresult`, `.log` | Full daily flow passes on iPhone SE, dark mode, Reduce Motion, normal and largest text. |
| `resume-typical-ui.xcresult`, `.log` | PASS: complete light-mode daily flow, accessibility audit, relaunch, and largest-text interactions. |
| `resume-small-dark-ui.xcresult`, `.log` | PASS: complete constrained dark-mode flow, audit, relaunch, and largest-text interactions. Centered long-name evidence is from the typical-size run. |

Coverage includes immediate assignment after a sibling completion; unchanged particular assignment; no earlier obligations; inactive/future membership; explicit future chore start and weekday recurrence; picker/save date consistency; persistence/reload; offline transport reconciliation, grant approval, fresh import, and delivery order; toggles both ways; sibling and dated-write permissions. The suite has only three focused native UI flows. No broad rerun was needed after the resumed test-only audit exception.

The final UI checks use selected full Xcode and iOS 26.5, unsigned: iPhone 17e, 390 by 844 points (`282A3227-AB36-4256-8364-614F38DCD1FC`), and iPhone SE (3rd generation), 375 by 667 points (`EC679574-3ECA-4B26-93CA-2B232D59691B`). Exact invocation is the first line of each log: `xcodebuild test`, project/scheme EarnedIt, task-local DerivedData/results, parallel testing disabled, and only `EarnedItUITests/EarnedItUITests/testExistingAllChildrenChoreIncludesNewChildImmediately` for resumed runs.

## Accessibility findings and bounded exception

The light-mode audit exposed real insufficient contrast in the existing dashboard subtitle. It and daily supporting text now use the semantic primary color at 70% opacity; Done symbols use primary foreground against their green background.

Two subsequent findings concern the decorative star avatar, not meaningful text: clipping and contrast of its shading. Both exported element screenshots show the complete star inside its circular background. `AvatarView` already hides this decoration from VoiceOver; the separate member name and status carry meaning. Firstmate authorized a precise, documented exception in `004.msg`, releasing the earlier hold. The test accepts only clipping/contrast on a star labelled `⭐️`, measuring 52 by 52 points, contained within `parent-child-alek`. Description and hit audits, all other elements, and all meaningful chore names/states remain enabled. No avatar, name, or product interaction was removed or recolored to accommodate the audit.

Exact diagnostic imagery:

- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/contrast-fixed-screenshots/Element Screenshot_1_AB834D3A-FC22-4635-87E1-78410BEF6A74.png.png`
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/avatar-audit-evidence/decorative-star-contrast.png`

## Visual evidence

Before, inspected:

- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/before-screenshots/before-daily-completion-list.png`
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/before-screenshots/before-new-child-joins-tomorrow.png`
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/before-screenshots/before-new-child-missing-from-today.png`

Final after screenshots, inspected:

- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/resume-typical-screenshots/after-compact-two-children.png`: two-child chore fits a compact line of controls alongside the title, using the existing card language.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/resume-typical-screenshots/after-new-child-immediately-in-today.png`: the new child appears immediately, Alek remains Done, and the particular-child chore stays assigned only to Hanna.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/resume-typical-screenshots/after-largest-type-long-name.png`: the entire Alexandria Montgomery control is visible at Accessibility XXXL, with natural line wrapping and no hidden children. The other three children and the chore title remain visible in the same card.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/resume-typical-screenshots/after-child-own-control-and-sibling-states.png`: Not Needed has text plus a distinct symbol; siblings remain visible and read-only to the child.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/resume-small-dark-screenshots/after-new-child-immediately-in-today.png`: readable wrapping on the 375-point screen in dark mode.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/resume-small-dark-screenshots/after-largest-type-direct-toggle.png`: the new child's direct toggle remains usable at the largest size. The tall card scrolls vertically on this shorter screen; the SE long-name capture is not claimed to center the entire name.

Native audits passed descriptions, text clipping, contrast, and hit regions at normal text size, with the exact decorative exception above. Largest text was checked through direct actions, control frames of at least 44 points, screen-width bounds, and visual inspection. Existing weekly-progress navigation and card styling are preserved. `git diff --check` passes. Earlier failed diagnostic bundles and the interrupted pre-pause screenshot run remain preserved and are not counted as passed.

## Limits and follow-ups

Transport-double tests and unsigned native Simulator flows do not establish signed, two-account live CloudKit/device behavior. No actual family store was erased, live schema provisioned, or signing account required. Native accessibility audits, interaction/geometry assertions, and screenshot inspection are distinct from listening to VoiceOver on a physical device.

Existing imported join days remain authoritative: this journal has no separate creation timestamp that could safely move an older future join date backward. The fix never subtracts a day or infers creation from import time. New member facts carry the correct household day through storage/sync, and genuine future effective boundaries remain honored.

The queued legacy timezone migration and same-day particular reassignment follow-ups are not expanded. Current civil dates, next-day edits/archives, and recorded history retain their coverage.

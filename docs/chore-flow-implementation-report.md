# Chore-flow implementation report

Paused at the captain's request from firstmate inbox `002.msg` and `003.msg`. Branch: `fm/earned-it-immediate-children-compact-chores`. Source changes are saved as a checkpoint, with incomplete validation explicitly retained. This is not the implementation gate and not a no-mistakes handoff. No pipeline owns this branch, and no push, PR, or merge occurred.

Resume handoff: first resolve outstanding `[key=decorative-avatar-audit]` through firstmate, then finish the typical-size light-mode daily UI flow and inspect the centered long-name screenshot. The blocker remains open; the captain's pause does not resolve it. Reuse the existing worktree, Simulator IDs, and evidence below. Do not repeat the original reproduction or reset actual stores. After resolving the audit, run only `EarnedItUITests/EarnedItUITests/testExistingAllChildrenChoreIncludesNewChildImmediately` with the recorded xcodebuild command and a new result bundle path, inspect screenshots, update this report, and commit the completed implementation gate. Firstmate then triggers no-mistakes.


## Setup and diagnosis

- Isolated root verified with both `pwd -P` and `git rev-parse --show-toplevel`: `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it`. The launch worktree was clean. Branch creation preceded investigation. Remote `HEAD` and `refs/heads/main`, checked with `git ls-remote`, both matched local base `d12c5081e649347d6ffa2198dfeb3944f9a0eae8`, the PR 5 merge following PR 4. No unexpected work needed preservation.
- `no-mistakes doctor` reported the daemon, database, and Codex agent healthy. No daemon lifecycle changes or pipeline run occurred. Read and applied firstmate's diagnostic-reasoning skill and its later `001.msg` handoff; the inbox message was acknowledged.
- End-to-end setup: fresh, dedicated debug UI-test journal on isolated iPhone 17e Simulator `282A3227-AB36-4256-8364-614F38DCD1FC`, iOS 26.5, selected `/Applications/Xcode.app/Contents/Developer`. Create Test Family with Hanna and Alek, create today's recurring all-children `Feed dog`, finish setup, mark Alek Done, add New Child through Family & Sharing, return to Family Today.
- Observed: Family & Sharing says `Joins lists tomorrow`; the daily card still shows only Alek and Hanna. Expected: New Child appears immediately, Unmarked, while Alek stays Done. The actual UI regression failed on the missing new-child control before production changes. Three separate executable domain/transport regressions reproduced the same exclusion, making the symptom repeatable across native UI and independent stores.
- Initiating trigger: saving a new child after setup. Masking conditions: setup-time creation saves today's join date and works; configuration previews can use tomorrow; reaching the saved join day makes the child eligible; chores on another weekday do not apply today regardless of membership. Existing completion evidence does not explain the exclusion.
- Visible symptom: the child is missing from today's all-children chore and cannot select/request its new profile today. The large daily card also duplicates required names and puts each child's state behind a menu; marking Done takes two taps, and undo additionally asks for confirmation.
- Evidence-backed root cause: `HouseholdStore.saveMember` deliberately persisted `tomorrow` for every post-setup new member. `FamilyMember.isActive`, profile selection, picker validation, and `ChoreRules.dailyList` correctly honored that boundary. This policy came from `1c12a8d` in PR 4. PR 5's `9aa7b40` aligned picker/save dates but did not introduce the join-date behavior. No CloudKit or view-cache failure was observed.
- Minimal counterfactual: change only new children's saved join boundary to today's household day. All three previously failing regressions passed with zero failures before the row redesign. No revision or completion mutation was needed. Proven path: setup-time children and children on their saved effective day already joined all-mode projections.
- Disconfirming checks: particular-child assignment remains unchanged; a future imported join date remains inactive; an explicit future-start Monday chore is absent on the current Monday; a Tuesday chore stays absent Monday; an archived child stays excluded on dates at/after archival; the prior Monday never gains the newly created child. Existing dated contributions remain equal as decoded facts, and opposite fact delivery order yields the same snapshot.

## Implementation

New children persist today's fixed household civil date, independent of the existing today/new-chore and tomorrow/chore-edit distinction. Existing parent activation and archive policies remain intact. Renaming retains the recorded join date. No model migration or transport schema change is needed.

Daily responsibility generation remains a read-only projection of the applicable immutable revision, dated membership, and recorded assignment evidence. Adding/fetching a child fact changes the next projection immediately. It neither materializes earlier obligations nor overwrites completion facts. Tests exercise sibling completion before the new child arrives, offline completion against an older membership set, grant approval, sync, reopening, and fresh import.

The native card now wraps its chore title and individual child controls. Symbols distinguish all states; Done/Not Needed also use colored backgrounds, and Not Needed/Missed show explicit text. Each permitted child control is at least 44 by 44 points and toggles Done in one tap, including undo. Context menus and VoiceOver actions retain the other states. Parent history undo records Missed; today undo records Unmarked. Siblings remain visible and read-only to a child. Store authorization still checks role, target, date, and cloud write access.

README, changelog, architecture, and the Add Child form describe the immediate boundary and direct controls. The project-memory helper found AGENTS.md and its CLAUDE.md pointer already conformant; no general guidance needed expansion.

## Verification and evidence

Evidence directory: `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/`.

- `before-ui.xcresult` and `before-ui.log`: expected native reproduction failure on the missing `state-feed-dog-new-child` control.
- `before-regressions.xcresult` and `.log`: all three new behavioral regressions fail against the original production code.
- `counterfactual.xcresult` and `.log`: those same three tests pass after only the persisted child-creation boundary changes.
- `after-tests.xcresult` and `.log`: full unit/integration suite, 53 tests passed. Picker/save timing and the largest-type setup, duplicate prevention, confirmed reset, and unsigned join-failure UI flows passed. The daily flow stopped on a floating-point hit-size assertion (43.99999999999994 versus 44 points); the assertion now allows 0.01 point of measurement tolerance. Production targets remain at least 44 points.

Exact before screenshot paths:

- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/before-screenshots/before-daily-completion-list.png`
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/before-screenshots/before-new-child-joins-tomorrow.png`
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/before-screenshots/before-new-child-missing-from-today.png`

The expanded small-screen daily flow passed in `final-small-dark-ui.xcresult` / `.log` on iPhone SE (3rd generation), 375 by 667 points, iOS 26.5, Simulator `EC679574-3ECA-4B26-93CA-2B232D59691B`. Appearance was dark and Reduce Motion was enabled. It checks immediate membership after a completion, unchanged particular assignment, direct Done/Unmarked toggles by child and parent, sibling view-only states, Not Needed Today via context menu, relaunch, four children including a long name, and largest accessibility text. All checked child controls are at least 44 points and remain within screen width. The dark-mode native accessibility audit passed description, text-clipping, contrast, and hit-region checks on the normal-size daily screen. The light-mode audit remains blocked as described below. Largest-type behavior was checked through actual interactions, control geometry, and screenshots; this is not a live VoiceOver listening session.

Inspected after screenshots (absolute paths):

- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/after-suite-screenshots/after-compact-two-children.png`: light mode, the former tall two-child chore now fits one compact line of controls alongside its title.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/small-dark-screenshots/after-new-child-immediately-in-today.png`: all three children visible, Alek Done and the new child Unmarked, with wrapping on the SE.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/final-small-dark-screenshots/after-child-own-control-and-sibling-states.png`: the child can change only their own contribution, while sibling status remains visible.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/small-dark-screenshots/after-largest-type-long-name.png`: long-name wrapping at Accessibility XXXL; this screenshot shows only part of the control while scrolling. The test now uses a measured drag to center it, but its new evidence run was interrupted. Final centered visual inspection remains pending.
- `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/final-small-dark-screenshots/after-largest-type-direct-toggle.png`: direct toggle remains usable at the largest size without navigation or a confirmation dialog.

## Current blocker

`[key=decorative-avatar-audit]`: The typical-size light-mode audit first identified insufficient subtitle contrast; the dashboard subtitle and daily supporting text were corrected using the semantic primary color at 70% opacity. Done symbols also use the primary color against the green status background. The next audit flagged the existing decorative 52-point star avatar for text clipping. Its exported element screenshot shows the entire star, and the avatar is hidden from VoiceOver. A narrowly scoped exception for that avatar's text-clipping finding exposed a contrast finding on the same decorative star in `verified-typical-ui.xcresult` / `.log`. The scaffold requires stopping after the same obstacle twice, so no further exception or avatar change was applied. Firstmate guidance is needed before resuming, with a resolved line for this key.

The repeated findings are on the existing weekly-progress avatar, outside the new chore controls. Screenshot evidence is in `/Users/jlm429/.treehouse/earned-it-0033f9/3/earned-it/.artifacts/chore-flow/contrast-fixed-screenshots/Element Screenshot_1_AB834D3A-FC22-4635-87E1-78410BEF6A74.png.png` and the `verified-typical-ui.xcresult` failure attachments. No failing assertion was silently dropped. The typical-size light-mode UI flow has not yet completed all direct-toggle checks because its audit stops first; those same interactions passed in dark mode on the smaller SE.

The latest `verified-small-dark-ui` run was launched to improve the long-name screenshot centering before the repeated typical-size finding was inspected. The prior `final-small-dark-ui` run already passed; its largest-type interactions and screenshot evidence are preserved. Before the captain pause message was delivered to this agent, the remaining screenshot run received SIGINT under the scaffold repeated-obstacle stop rule. Its log and result bundle are preserved; it is not counted as passed. No Simulator was deleted or shut down. All source and evidence remain in this worktree. A checkpoint commit is being saved at the captain's request. No implementation-gate done status, push, or pipeline start has been issued.

## Limits and remaining follow-ups

Unsigned native Simulator flows and an in-memory two-account transport server do not establish live CloudKit/device behavior. Signed two-account invitation and synchronization validation remains external. No real family store was erased, no production schema was provisioned, and no signing account was needed.

Old/imported persisted join days remain authoritative: the existing journal has no separate genuine creation timestamp from which to safely move an older future join day backward. This fix never subtracts a day or infers creation from import time. New child facts created by this version carry the correct day through local storage and sync; a future effective boundary from another source is honored.

F1, hidden archived IDs in an existing any-one/multiple chore edit, remains a documented follow-up. The form can retain an invisible selection and validation can reject the save. It does not leak archived children into all-mode projections; all-mode revisions persist no explicit child IDs, and save validation still rejects ineligible explicit assignments. No accepted immediate all-children behavior requires changing that separate editor policy. The queued legacy timezone-boundary migration and same-day particular-child reassignment follow-ups are not expanded; fixed household dates, next-day edits/archives, and recorded history remain covered.

Checkpoint only. Resume and complete validation before declaring the implementation gate. Firstmate triggers no-mistakes after that gate, with a new PR and no autonomous merge.

## Exact resume command

After firstmate resolves the outstanding audit key, use a fresh result path:

```sh
xcodebuild test -project EarnedIt.xcodeproj -scheme EarnedIt \
  -destination 'platform=iOS Simulator,id=282A3227-AB36-4256-8364-614F38DCD1FC' \
  -derivedDataPath .artifacts/DerivedData \
  -resultBundlePath .artifacts/chore-flow/resume-typical-ui.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:EarnedItUITests/EarnedItUITests/testExistingAllChildrenChoreIncludesNewChildImmediately \
  CODE_SIGNING_ALLOWED=NO > .artifacts/chore-flow/resume-typical-ui.log 2>&1
```

The small-screen equivalent uses Simulator `EC679574-3ECA-4B26-93CA-2B232D59691B`, `.artifacts/SmallDerivedData`, and a new small-screen result/log path. Current sources include the measured long-name screenshot drag and the narrow text-clipping-only exception for the 52-point decorative star. The star's contrast audit still needs a decision; no contrast exception has been added. The extra household-DST/new-child-rename regression passed in `typical-ui.xcresult` before its separate UI test failed.

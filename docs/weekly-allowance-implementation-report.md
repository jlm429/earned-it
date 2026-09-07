# Weekly allowance implementation report

## Scope and base

Implemented on `fm/earned-it-weekly-allowance` from remote `origin/main` at `c96e4f1`. Local HEAD and remote main matched before work began. GitHub listed PRs 1 through 6 as merged, including PR 6 in that base. No contradictory merge evidence was found. No PR was merged by this task.

The app retains its native SwiftUI cards, forms, profile selection and centralized permissions, SwiftData journal, and explicit CloudKit fact transport. No backend, dependency, payment system, signing account, or live schema was added.

## Delivered behavior

| Requirement | Implementation |
| --- | --- |
| Independent child allowances | Parent child detail has an amount editor with currency selection, decimal-place validation, localized formatting, zero and unset support. Integer minor units avoid binary floating point. |
| Amount history | Append-only allowance facts apply from the current Monday onward. Earlier finished weeks resolve their previous rate. Concurrent edits resolve in existing deterministic fact order. |
| All required items | A nonempty finished week earns only when every required item is accounted for. Done and Not Needed count; excused days are excluded. Optional contributions cannot substitute for required items or earn an optional-only badge. |
| Missing versus future | Current summary separates overdue missing items, items due today, and future scheduled items. Warning text and symbols accompany yellow. Missing items identify the chore and family civil date. |
| Bounded history | Current week plus at most 12 finished weeks since family creation, each labeled Week of with a start/end range. Derived directly from immutable source facts, without summary-cache drift or broad journal deletion. |
| Child grace cutoff | Scheduled day and following calendar day are editable by that child. The second following day locks child mutations. Parents retain dated correction access. Both UI and the store enforce this. |
| Finished-week treatment | Earned It badge and encouraging Way to go treatment. Local persisted receipts prevent repeated celebration on relaunch. Missing finished weeks instead show Check in with your parent. Corrections update results. |
| New week | Monday-start current week appears first in parent and child views. Foreground, significant time changes, and household-midnight refresh use the same family calendar. Yesterday remains reachable for Sunday grace completion on Monday. |

## Migration and history contract

There is no SwiftData entity change. New allowance facts use the existing Codable payload journal and CloudKit record envelope. Existing household, member, chore, completion, and session payloads reopen with allowance unset; the new optional local celebration receipt decodes as absent. Current shared-household stores are preserved. Old incompatible beta stores remain untouched. No actual family store was deleted or inspected.

This journal had no configurable threshold fields to migrate. The earlier fixed scoring constants and obsolete copy have been replaced; retained outcomes now use the accepted all-required rule. See [Create or join a family](../README.md#create-or-join-a-family) for the participating-installation update requirement.

The historical timezone and same-day reassignment backlog concerns are already addressed for the current journal by persisted `CivilDay` values and next-day configuration/archive boundaries. Tests cover those behaviors and their weekly projections. This task does not migrate the incompatible beta store or expand unrelated assignment editing scope. The previously documented hidden archived-selection issue in the chore editor remains separate.

## Verification

Environment: Xcode 26.6 (17F113), iOS Simulator 26.5, task-isolated 375 × 667 point iPhone SE (3rd generation) Simulator `EC679574-3ECA-4B26-93CA-2B232D59691B`. Simulator signing was disabled. Tests use the separate debug UI store and explicit reset/clock flags. No real waiting for days or weeks was used.

- The existing parent/child compact-chore flow passed on the base build: `.artifacts/baseline.xcresult` and `.artifacts/baseline.log`.
- All 62 domain, persistence, onboarding, authorization, and transport-double tests passed in `.artifacts/weekly-validation.xcresult`. Nine allowance tests cover fractional and currency-specific precision, multiple children, unset migration, reopening a disk journal, past-week rates, assignment/title and archive history, empty and optional-only weeks, future exclusion, parent correction, grace cutoff, persisted celebration receipts, retention after absence, DST and year boundaries, and offline retry/convergence.
- The existing largest Dynamic Type setup flow passed, including partial setup/relaunch, duplicate rejection, cancel, confirmed reset/relaunch, empty parent state, and native unavailable-sharing feedback. Evidence is in `.artifacts/weekly-validation.xcresult`.
- Release Simulator builds passed in `.artifacts/release-build.log` and `.artifacts/final-release-build.log`. Debug clock/fixture code is excluded by compilation conditions. The only build warning was Xcode skipping optional App Intents metadata extraction because the app has no AppIntents dependency.

### Native navigation diagnosis and corrections

The initial weekly flow reached celebration and relaunch before a history-link tap stayed on Today. XCTest reported the low link as hittable while the debug clock inset obscured its tap point. A focused counterfactual passed in `.artifacts/navigation-counterfactual.xcresult`: hiding the clock let the original link at frame `(32, 643.5, 178, 20.5)` open Weekly History, and bounded scrolling with the clock present reached the same history and locked Sunday. This disconfirmed a broken destination. Full swipe gestures in an interim helper overshot the target. The final fixture puts its clock in the native navigation toolbar, and the test helper uses bounded 160-point drags to position actual tap targets inside scrolling content. Menu options use ordinary native menu taps. The temporary diagnostic test was removed after retaining its evidence.

Subsequent native checks exposed duplicate accessibility identifiers on the decorative badge icon and label, and an untappable spacer in plain-styled dated rows. Badges now have a single explicit accessibility label, and dated rows have a full rectangular content shape. Screenshot review also removed impossible tap instructions from locked/read-only days, strengthened date contrast, and increased child navigation targets to at least 44 points.

The complete weekly flow passed in `.artifacts/weekly-native.xcresult`. It covers invalid decimals, independent amounts, future exclusion, the gentle reminder, Sunday completion during Monday grace, one-time celebration and persistent badge, locked child history, parent correction, prior amount preservation, relaunch, and the fresh current week in largest-text dark mode. Its sufficient-element-description audit passed.

The final combined run in `.artifacts/final-validation.xcresult` passed all 62 domain tests, the existing parent/child compact flow, and the complete weekly flow again. Its one failure was the setup test helper reversing its search before the distant Finish Setup cell materialized in the largest-text SwiftUI Form. The helper now chooses the actual collection/table container and allows enough bounded search distance before reversing. The focused setup regression then passed in `.artifacts/final-setup-regression.xcresult` (one test, zero failures), including duplicate rejection, completed setup, cancelled reset, confirmed reset/relaunch, and unavailable-sharing feedback. All 62 domain tests and all three selected native flows have passing results. This report does not describe the earlier combined result bundle as green. Only test-helper navigation and whitespace changed after that combined run; product behavior stayed as verified.

### Reproduction

Use the available isolated Simulator ID in place of the one below when needed. Keep result bundle paths unique for each run.

```sh
xcodebuild test -project EarnedIt.xcodeproj -scheme EarnedIt \
  -destination 'platform=iOS Simulator,id=EC679574-3ECA-4B26-93CA-2B232D59691B' \
  -derivedDataPath .artifacts/DerivedData \
  -resultBundlePath .artifacts/weekly-recheck.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:EarnedItTests \
  -only-testing:EarnedItUITests/EarnedItUITests/testExistingAllChildrenChoreIncludesNewChildImmediately \
  -only-testing:EarnedItUITests/EarnedItUITests/testPartialSetupDuplicatePreventionAndConfirmedResetAtLargeType \
  -only-testing:EarnedItUITests/EarnedItUITests/testWeeklyAllowanceHistoryGraceCelebrationAndRollover \
  CODE_SIGNING_ALLOWED=NO
```

## Preserved native evidence

These unedited Simulator captures come from the passing complete weekly flow. “Test date” is an explicit debug-only native toolbar control and is not in production. Normal and largest accessibility text sizes are shown; the layouts scroll vertically on the small iPhone. The latest current week appears before the retained outcome in the child home hierarchy.

| Evidence | Capture |
| --- | --- |
| Fractional allowance editing | [Amount editor](weekly-allowance-evidence/weekly-edit-fractional-allowance.png) |
| Current week, amount, and future exclusion | [Current week](weekly-allowance-evidence/weekly-current-week-start.png), [scheduled item count](weekly-allowance-evidence/weekly-current-future-not-missed.png) |
| Finished-week reminder | [Gentle parent check-in](weekly-allowance-evidence/weekly-finished-gentle-parent-reminder.png) |
| Sunday grace on Monday | [Child completion during grace](weekly-allowance-evidence/weekly-sunday-completed-during-monday-grace.png) |
| Earned result and no replay | [Way to go](weekly-allowance-evidence/weekly-earned-it-way-to-go.png), [badge after relaunch](weekly-allowance-evidence/weekly-badge-persists-without-replay.png) |
| Historical child refusal | [Locked Sunday and dated missing chore](weekly-allowance-evidence/weekly-child-locked-after-grace.png) |
| Parent history and correction | [Finished week and missing count](weekly-allowance-evidence/weekly-parent-missing-items-and-dates.png), [dated Sunday correction](weekly-allowance-evidence/weekly-parent-corrects-locked-sunday.png), [corrected earned outcome](weekly-allowance-evidence/weekly-corrected-parent-earned-outcome.png) |
| Past amount preserved | [Prior rate after a current-week edit](weekly-allowance-evidence/weekly-finished-amount-preserved-after-edit.png) |
| Fresh current week, dark mode, largest text | [Accessible current week](weekly-allowance-evidence/weekly-current-largest-type.png) |

Machine-readable Xcode results are retained for the [weekly native flow](weekly-allowance-evidence/weekly-native-summary.json), [navigation counterfactual](weekly-allowance-evidence/navigation-counterfactual-summary.json), [combined run with 64 passing tests and the setup-helper failure](weekly-allowance-evidence/final-validation-summary.json), and [passing setup regression after the helper correction](weekly-allowance-evidence/final-setup-regression-summary.json). Full result bundles and logs remain in worktree-local `.artifacts/` and are not committed.

## Limits and delivery gate

CloudKit evidence here is from the existing production codec and transport doubles, not signed two-account CloudKit/device validation. Live invitations, account permissions, actual upload/retry behavior, and physical-device accessibility remain release checks. The existing CKShare trust boundary is unchanged: a shared-zone writer has broader access than app profile permissions.

Remote main has no checked-in CI workflow and `gh-axi run list` reported zero runs. The prior PR 6 CI waiver is not used for this change. No paid CI service was configured and no ended CI research was resumed. This implementation and evidence are the commit handoff for Firstmate's instructed no-mistakes run, with yolo off and no merge. The pipeline has not yet run for this branch. If the pipeline reaches an absent-CI gate, the exact remaining decision must be escalated there.

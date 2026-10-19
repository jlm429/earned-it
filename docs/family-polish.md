# Family progress, bonuses, reminders, and turn exchanges

## Bonus allowance

A parent can open a child's progress and choose Award Bonus beside the weekly allowance summary and bonus history. The labeled content button has a minimum 44-point target. Each save writes one immutable `BonusAward` with its stable fact ID, child, parent, household civil date, integer minor-unit amount, ISO currency, and optional note. Retrying Save on the same form cannot create a second award. Separate awards remain separate, including awards made offline on different devices.

Bonus history shows the recorded amount, currency, date, note, and parent. Weekly History includes awards for each retained week and an All bonus awards disclosure for older awards. Bonuses do not alter the regular weekly amount, required work, earned-week rule, streak, or prior outcomes. There is no money movement or payment state.

## Manual reminders

Parents have a Nudge button on today's incomplete scheduled chores and active As Needed occurrences. The action targets only children with unfinished, unexcused work. Inactive, withdrawn, removed, Not Needed, and fully accounted-for chores have no reminder action. Separate same-day As Needed occurrences can each receive a reminder.

The button saves `ChoreNudge` facts in the existing journal. A reminder can be saved offline. Reminder admission and actionable Activity match the stable chore, occurrence, civil day, and child across harmless revision edits. Each child receives at most one effective reminder per chore/occurrence/civil day, even if two offline parents create facts independently. A stable derived Activity identity also deduplicates local notification receipts. Completing or excusing the work removes its reminder from actionable Activity; outdated reminders do not replay on a later day. The button says Reminder saved because journal persistence does not prove remote delivery.

Reminders use the existing private/shared CloudKit zone and permission-controlled generic local Activity alert. No recurring schedule, notification scheduler, external service, record type, entitlement, or schema change is introduced. Notification preference and authorization stay local to each installation. Denial leaves Activity usable. Existing backlog does not replay when permission is later enabled. An alert suspension rechecks that its activity is still relevant before retaining the delivered notification.

Family updates arrive on launch, foreground, refresh, or an available background CloudKit hint. [Apple's background update limits](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app) still apply. A saved nudge does not guarantee a push, wake, notification, or immediate delivery. Signed APNs and independent-account evidence remain outside Simulator proof.

## Swap Turns

A child responsible for an incomplete scheduled alternating chore can ask another eligible child to exchange two occurrences of that same stable chore. The request names today's exact revision/day and the recipient's next base-rotation scheduled date within 28 household civil days. That date is shown before sending and in Activity. As Needed chores have no scheduled return date, so they do not offer a swap. This prevents promising an occurrence that may never be activated.

Both children are reserved from the first valid request. The recipient must explicitly accept on the request's household civil day. Until acceptance, neither responsibility changes. Accepting assigns today's occurrence to the recipient and the return occurrence to the requester. It never edits the participant order or consumes another child's base rotation slot. Scores, allowance, streaks, completion controls, and history use those same effective owners.

| State | Result |
| --- | --- |
| Pending | Both participants reserved; original responsibilities remain. Requester may cancel; recipient may decline or accept. |
| Declined or cancelled | No responsibility changed; reservations released. A fresh valid request is allowed. |
| Expired | No acceptance before midnight, or source/return no longer valid. No transfer; reservations released. |
| Accepted | Both participants reserved through the return date and existing next-day completion grace. Neither exchanged occurrence can start another swap. |
| Completed | Both occurrences accounted for. Reservations released; assignments and history retained. |
| Ended | Return completion grace ended, or a parent corrected a previously settled outcome. Reservations stay released; original exchanged responsibilities and their corrected credit remain in their actual weeks. |
| Released | A structural schedule, membership, deletion, or Not Needed change invalidated the promise. Return obligation cancelled without moving it to another date. The accepted source assignment and its recorded outcome remain historical. |

Only completions and corrections for each endpoint's winning dated revision supply active credit or settle an exchange. Losing-revision contributions remain historical. Rotation uses the same latest winning-revision completion, so an offline losing-revision reversal cannot apply Keep Turn to completed work. Accepted endpoints remain unavailable to later exchanges even after release, and both offered choices and request admission enforce that restriction.

Ordinary title/notes/category edits preserve a compatible dated return. Changing schedule, rotation membership/order, archiving, removing a participant, or disposing an unpaid endpoint releases an invalid return. A release does not revive after a later configuration edit or restoration. Done wins a concurrent Not Needed disposition, including the base-rotation consumption. Completion history can still be corrected by parents through existing rules. After both turns settled, a later correction changes actual credit without reviving an earlier concurrent Not Needed disposition, cancelling the exchanged assignments, or changing their consumed rotation slots. A later intentional Not Needed action still applies.

All requests and decisions replay globally in Lamport sequence and UUID order. This reserves participants across chores, admits the first non-overlapping request and first valid decision, prevents chains, and retains rejected/conflicting facts as audit evidence. Acceptance reads its preceding journal and cannot pass an earlier completion or disposal. An on-time offline decision can arrive later and remain valid; a decision dated after the request day is ineffective. Replay prefixes retain original swap facts and their implicit journal capability boundary while disabling nested swap projection. Restored scheduled requirements therefore have the same meaning during candidate selection, request admission, acceptance, and settlement. Devices may disagree temporarily while offline and converge after merging the same facts.

The old one-way transfer facts and their projection remain readable for history and accounting. New screens create only reciprocal swaps. Historical requests are labeled Earlier turn request. Transfer statistics and their presentation/fixtures are retired.

## Compatibility and security

New bonus, reminder, request, and decision facts use the existing `HouseholdFact` payload and format version 4. They imply journal capability 4, so earlier clients fail closed before upload rather than interpreting exchanged work as a base turn. Versions 1 through 3 remain readable; the SwiftData schema and store identity are unchanged.

Parent mutations remain in `HouseholdStore`; child decisions require the exact selected invited profile. Upload reference ordering, field validation, and parent/child author checks cover the new facts. CloudKit participants still have broader transport write access than the app role checks. These client checks are not server-enforced authorization. Invitation creation, exact claims, one-time link binding, owner-only participant management, account membership, and recovery retain their existing boundaries.

## Interface

The family name is part of the Daily Picture, replacing the separate avatar/header and motivational sentence. Child home puts a compact greeting and weekly summary above today's responsibilities; weekly history and supporting information follow the work on iPhone and sit beside it on iPad. Redundant quote cards are removed. Existing progress/completion motion respects Reduce Motion; native controls retain accessible sizes and wrapped text.

Saving a child immediately offers Connect Now with that exact profile preselected, or Add Device Later. Setup and Manage Family retain Not connected yet or Invitation waiting until the existing membership facts prove connection. Opening the invitation form does not create or claim an invitation. Issuing an invitation from unfinished setup first uses the existing validated Finish Setup path, requiring a child profile before upload. The invitation stays presented while setup completes, so it can be shared and redeemed immediately. Add Device Later leaves unfinished setup unchanged; parents can continue editing family members and chores afterward.

## Local verification

The implementation report and synthetic before/after captures are retained under the assigned task data directory. Local domain/transport tests and native UI flows validate application behavior; they do not prove signed two-account CloudKit delivery, Apple invitation admission, Production schema availability, or APNs provisioning. Production evidence limits in the invitation crash, invitation package, and membership recovery reports remain applicable. No live family, invitation, schema, signing, release, or CI operation is part of this change.

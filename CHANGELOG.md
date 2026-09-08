# Changelog

User-visible changes to Earned It. The shared household app is a preproduction preview.

## Unreleased

### Alternating chores

- Parents can assign a chore to all children, one child, or selected children who alternate turns. Turn order is shown while editing and advances on scheduled dates regardless of completion.
- Children see an alternating chore only when it is theirs, with concise turn copy and the existing compact completion state. Parent daily lists identify the current owner.
- Future turns exclude archived or inactive participants. Existing all-child, single-child, any-one, and multiple-child chores continue to load with their prior behavior.

### Development

- Pull requests and manual dispatches now build the app and run the complete automated suite on the stable macOS 26, Xcode 26.6, and iOS 26.5 Simulator toolchain without signing.

### Weekly allowance

- Parents can set and edit each child’s weekly amount and currency, including fractional amounts or an unset amount. Finished weeks preserve the rate that applied to them. This tracks eligibility, never payments or transfers.
- Allowance now requires every required item (100%) after the week ends. Future items stay scheduled; missing items show a yellow warning, their names, and dates. Optional-only and empty weeks do not earn allowance.
- Weekly history retains a view of the current Monday-start week plus 12 finished weeks, including corrections after chore changes, reassignment, and archive.
- Children can mark an item on its scheduled day and the next calendar day. Later corrections require a parent. Sunday’s grace period continues through Monday.
- Finished complete weeks receive an Earned It badge and a one-time “Way to go!” treatment. Missing weeks gently ask children to check in with their parent. Both stay separate from the fresh current week.

### Fixed

- iPhone builds and App Store archives now include the production app icon.
- New children immediately join existing all-children chores that apply today. Particular-child assignments, future chore starts, earlier history, and other children’s completions are preserved across reload and sync.
- Daily chore cards now show compact, wrapping child controls with individual status symbols and colors. Tap once to complete or undo your permitted entries; touch and hold for other states. Names stay readable with Dynamic Type, controls have at least 44-point touch targets, and supporting daily text has stronger contrast.
- Conflicting or superseded dated assignments remain visible to parents as view-only history without assigning, scoring, or granting controls to the displaced child. Archived hidden selections no longer block saving older any-one or multiple-child chore edits.

- An approved local parent can disconnect an installation after its iCloud share becomes read-only or access is revoked. Disconnect still requires confirmation, blocks ordinary pending changes and active synchronization, preserves rejected-change evidence, and leaves iCloud and other installations untouched.
- Chore assignment choices now match the date used when saving. New chores use today's children; edits use tomorrow's children. A child joining tomorrow can be selected for an edit, while a child archived from tomorrow remains eligible for a new chore today.

### Shared household preview

- One shared recurring list for each weekday, with a separate completion for each person and calendar date. Monday's configuration returns next Monday without carrying completions forward.
- Chores can require one child, any one eligible child, multiple specific children, or all children. Parents see who completed each chore and who remains on the same daily list. Removing a contribution changes only that person's dated entry.
- Create Family and Join Existing Family, persisted setup, native iCloud invitations, and association with existing family profiles. An installation can support multiple approved profiles.
- Per-child weekly progress, streaks, excused days, and allowance eligibility. Required chores credit only the relevant child; optional any-one contributions credit their contributor without penalizing other children. The original preview tracked eligibility only; per-child amounts are now available as described above. No payments are recorded.
- Household timezone dates, retained assignment history, next-day configuration edits and archives, and protection against conflicting edits leaving no active parent.
- Offline changes remain available for synchronization. Rejected changes retain their reasons and evidence; dependent uploads wait for confirmed prerequisite saves.
- Existing beta stores remain untouched. Production does not seed sample families.

### Sharing and validation limits

Invite only trusted family participants. A CloudKit read/write participant can modify or delete any shared record; the app's parent/child controls are client checks, not server-enforced role authorization. Synchronization occurs on foreground, local changes, and refresh, with no real-time or background delivery guarantee.

Signed testing on two devices with distinct iCloud accounts remains required for invitation delivery and acceptance, profile approval, offline recovery, account changes, read-only access, and revocation. Local integration tests and Simulator flows do not establish live iCloud behavior or production readiness. No production schema deployment is included.

See [architecture and Apple sources](docs/shared-household-architecture.md) for the domain and sharing rules.

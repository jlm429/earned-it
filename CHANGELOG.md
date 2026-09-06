# Changelog

User-visible changes to Earned It. The shared household app is a preproduction preview.

## Unreleased

### Fixed

- New children immediately join existing all-children chores that apply today. Particular-child assignments, future chore starts, earlier history, and other children’s completions are preserved across reload and sync.
- Daily chore cards now show compact, wrapping child controls with individual status symbols and colors. Tap once to complete or undo your permitted entries; touch and hold for other states. Names stay readable with Dynamic Type and controls have at least 44-point touch targets.

- An approved local parent can disconnect an installation after its iCloud share becomes read-only or access is revoked. Disconnect still requires confirmation, blocks ordinary pending changes and active synchronization, preserves rejected-change evidence, and leaves iCloud and other installations untouched.
- Chore assignment choices now match the date used when saving. New chores use today's children; edits use tomorrow's children. A child joining tomorrow can be selected for an edit, while a child archived from tomorrow remains eligible for a new chore today.

### Shared household preview

- One shared recurring list for each weekday, with a separate completion for each person and calendar date. Monday's configuration returns next Monday without carrying completions forward.
- Chores can require one child, any one eligible child, multiple specific children, or all children. Parents see who completed each chore and who remains on the same daily list. Removing a contribution changes only that person's dated entry.
- Create Family and Join Existing Family, persisted setup, native iCloud invitations, and association with existing family profiles. An installation can support multiple approved profiles.
- Per-child weekly progress, streaks, excused days, and allowance eligibility. Required chores credit only the relevant child; optional any-one contributions credit their contributor without penalizing other children. No payments or amounts are configured.
- Household timezone dates, retained assignment history, next-day configuration edits and archives, and protection against conflicting edits leaving no active parent.
- Offline changes remain available for synchronization. Rejected changes retain their reasons and evidence; dependent uploads wait for confirmed prerequisite saves.
- Existing beta stores remain untouched. Production does not seed sample families.

### Known limitation

Editing an existing any-one or multiple-child chore after archiving one of its selected children can retain a hidden selection and fail validation. This preexisting edge case remains open.

### Sharing and validation limits

Invite only trusted family participants. A CloudKit read/write participant can modify or delete any shared record; the app's parent/child controls are client checks, not server-enforced role authorization. Synchronization occurs on foreground, local changes, and refresh, with no real-time or background delivery guarantee.

Signed testing on two devices with distinct iCloud accounts remains required for invitation delivery and acceptance, profile approval, offline recovery, account changes, read-only access, and revocation. Local integration tests and Simulator flows do not establish live iCloud behavior or production readiness. No production schema deployment is included.

See [architecture and Apple sources](docs/shared-household-architecture.md) for the domain and sharing rules.

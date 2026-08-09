# SwiftData Guidance

- Persist source facts and relationships locally. Derive scores, streaks, counts, and status labels.
- Use stable UUID identifiers for users, responsibilities, daily states, and excused days.
- Store relationship identifiers explicitly when that keeps permission and deletion checks safe.
- Normalize calendar dates before lookup and enforce one daily state per responsibility per day.
- Perform rollover on launch and relevant loads. Do not schedule background midnight work.
- Make model changes conservatively, provide defaults where possible, and never discard user data silently.
- Validate deletion against responsibility ownership and assignment so remaining records stay valid.

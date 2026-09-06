# SwiftData Guidance

- `HouseholdRepository` persists immutable typed facts and a separate local device session. It disables automatic CloudKit mirroring.
- `HouseholdStore` is the mutation boundary. `CloudKitHouseholdTransport` exchanges the same facts through one shared zone per household.
- Use UUID identities and household civil date keys. Follow `docs/shared-household-architecture.md` for revision and membership boundaries.
- Preserve contribution and revision history; reversals are scoped to one chore, date, and member.
- Never erase an actual store or silently replace unreadable data. UI tests use only the dedicated test store.

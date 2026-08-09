# Testing Guidance

- Use XCTest for deterministic business rules and permissions without UI dependencies.
- Test dates with an explicit Gregorian calendar, locale, and time zone.
- Cover boundary values for weekly thresholds, allowance decisions, date ranges, rollover, excuses, and streak neutrality.
- Keep UI coverage to at most three focused end-to-end flows with stable accessibility identifiers.
- Reset or seed a dedicated test store at UI-test launch so flows are repeatable.
- Build and run tests against a named available iPhone Simulator.
- Treat failures and flakes as product defects and fix them before delivery.

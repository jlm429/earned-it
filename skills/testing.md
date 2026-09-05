# Testing Guidance

- Use XCTest for deterministic business rules and permissions without UI dependencies.
- Test dates with an explicit Gregorian calendar, locale, and time zone.
- Cover boundary values for weekly thresholds, allowance decisions, date ranges, rollover, excuses, and streak neutrality.
- Keep UI coverage to at most three focused end-to-end flows with stable accessibility identifiers.
- Reset a dedicated test store at UI-test launch so flows are repeatable. Debug UI tests use `--ui-test-store` and `--ui-test-reset`; production has no sample-loading or launch-reset commands.
- Build and run tests against a named available iPhone Simulator.
- Treat failures and flakes as product defects and fix them before delivery.

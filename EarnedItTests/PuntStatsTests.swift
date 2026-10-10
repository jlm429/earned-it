import XCTest
@testable import EarnedIt

@MainActor
final class PuntStatsTests: XCTestCase {
    private func stats(_ family: TestFamily, member: FamilyMember? = nil,
                       week: PuntStatsWeek = .thisWeek, facts: [HouseholdFact]? = nil) -> PuntStats {
        PuntStatsRules.summary(memberID: (member ?? family.hanna).id, week: week, today: family.store.day,
                               snapshot: facts.map { HouseholdSnapshot(facts: $0) } ?? family.store.snapshot)
    }

    private func request(_ family: TestFamily, sender: FamilyMember? = nil,
                         recipient: FamilyMember? = nil, siblings: [UUID]? = nil) throws -> ProjectedPunt {
        let sender = sender ?? family.hanna
        let recipient = recipient ?? family.alek
        try family.store.selectProfile(family.parent.id)
        let weekday = Weekday(rawValue: family.store.calendar.component(.weekday, from: family.clock.now))!
        let chore = try family.store.saveChore(weekday: weekday, title: "Bins", mode: .alternating,
            memberIDs: siblings ?? [sender.id, recipient.id], firstAlternatingMemberID: sender.id)
        try family.store.selectProfile(sender.id)
        try family.store.requestPunt(choreID: chore, recipientID: recipient.id)
        return try XCTUnwrap(family.store.activity.first {
            $0.punt?.request.scope.choreID == chore
        }?.punt)
    }

    private func accept(_ family: TestFamily, _ request: ProjectedPunt) throws {
        try family.store.selectProfile(request.request.recipientID)
        try family.store.decidePunt(requestFactID: request.id, kind: .accepted)
    }

    private func decision(_ family: TestFamily, _ request: ProjectedPunt, kind: PuntDecisionKind = .accepted,
                          author: UUID? = nil, day: CivilDay? = nil, sequence: Int64? = nil,
                          scope: PuntScope? = nil) -> HouseholdFact {
        let actor = kind == .cancelled ? request.request.requesterID : request.request.recipientID
        return HouseholdFact(id: UUID(), householdID: family.store.household!.id,
            sequence: sequence ?? family.store.snapshot.orderedFacts.last!.sequence + 1,
            authorDeviceID: UUID(), authorMemberID: author ?? actor,
            body: .puntDecision(PuntDecision(requestFactID: request.id, scope: scope ?? request.request.scope,
                day: day ?? request.request.scope.day, memberID: actor, kind: kind)))
    }

    func testAcceptedTransferCountsBeforeCompletionAndKeepsHistoryAfterCompletionAndDisposition() throws {
        let family = try TestFamily()
        let pending = try request(family)
        XCTAssertTrue(stats(family).isEmpty)
        try accept(family, pending)
        XCTAssertEqual(stats(family).punted, 1)
        XCTAssertEqual(stats(family, member: family.alek).covered, 1)
        XCTAssertEqual(family.store.dailyList().first?.state(for: family.alek.id), .unmarked)
        try family.store.setCompletion(choreID: pending.request.scope.choreID, memberID: family.alek.id,
                                       date: family.clock.now, state: .done)
        XCTAssertEqual(stats(family).punted, 1)
        try family.store.selectProfile(family.parent.id)
        try family.store.setCompletion(choreID: pending.request.scope.choreID, memberID: family.alek.id,
                                       date: family.clock.now, state: .unmarked)
        try family.store.markOccurrenceNotNeeded(choreID: pending.request.scope.choreID,
            date: family.clock.now, alternatingSkipBehavior: .keepTurn)
        XCTAssertEqual(stats(family).punted, 1)
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertTrue(stats(family).isEmpty)
        XCTAssertEqual(stats(family, week: .lastWeek).punted, 1)
    }

    func testPendingDeclinedCancelledAndExpiredNeverCount() throws {
        for rejected in [PuntStatus.pending, .declined, .cancelled, .expired] {
            let family = try TestFamily()
            let pending = try request(family)
            switch rejected {
            case .declined:
                try family.store.selectProfile(family.alek.id)
                try family.store.decidePunt(requestFactID: pending.id, kind: .declined)
            case .cancelled: try family.store.decidePunt(requestFactID: pending.id, kind: .cancelled)
            case .expired: family.move(to: "2026-09-08T16:00:00Z")
            default: break
            }
            XCTAssertEqual(family.store.activity.first { $0.id == pending.id }?.punt?.status, rejected)
            XCTAssertTrue(stats(family).isEmpty)
            XCTAssertTrue(stats(family, member: family.alek).isEmpty)
        }
    }

    func testDirectionsMultipleSiblingsStableGroupingAndPluralCopy() throws {
        let family = try TestFamily()
        let first = try request(family)
        try accept(family, first)
        try family.store.selectProfile(family.parent.id)
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        for _ in 0..<2 {
            let incoming = try request(family, sender: nora, recipient: family.hanna)
            try accept(family, incoming)
        }
        let reverse = try request(family, sender: family.alek, recipient: family.hanna)
        try accept(family, reverse)
        let result = stats(family)
        XCTAssertEqual(result.punted, 1)
        XCTAssertEqual(result.covered, 3)
        XCTAssertEqual(result.siblings.count, 2)
        let alek = try XCTUnwrap(result.siblings.first { $0.id == family.alek.id })
        XCTAssertEqual(alek.puntedText, "You punted to Alek 1 time.")
        XCTAssertEqual(alek.coveredText, "You covered for Alek 1 time.")
        XCTAssertEqual(result.siblings.first { $0.id == nora.id }?.coveredText, "You covered for Nora 2 times.")
        try family.store.selectProfile(family.parent.id)
        _ = try family.store.saveMember(id: nora.id, name: "Alex", role: .child, avatar: .star)
        try family.store.archiveMember(nora.id)
        XCTAssertEqual(stats(family).siblings.first { $0.id == nora.id }?.coveredText, "You covered for Alex 2 times.")
        XCTAssertEqual(stats(family).covered, 3)
        let missingName = family.store.snapshot.orderedFacts.map { fact -> HouseholdFact in
            guard case .member(var member) = fact.body, member.id == nora.id else { return fact }
            member.displayName = "  "
            return HouseholdFact(id: fact.id, householdID: fact.householdID, sequence: fact.sequence,
                authorDeviceID: fact.authorDeviceID, authorMemberID: fact.authorMemberID, body: .member(member))
        }
        XCTAssertEqual(stats(family, facts: missingName).siblings.first { $0.id == nora.id }?.name, "your sibling")
    }

    func testDuplicateConflictingAndReplayedDecisionsCountOneEffectiveTransfer() throws {
        let family = try TestFamily()
        let pending = try request(family)
        try accept(family, pending)
        let facts = family.store.snapshot.orderedFacts
        let duplicates = facts + [decision(family, pending), decision(family, pending, kind: .declined)]
        for delivered in [duplicates, Array(duplicates.reversed()), facts + [decision(family, pending), decision(family, pending)]] {
            XCTAssertEqual(stats(family, facts: delivered).punted, 1)
            XCTAssertEqual(stats(family, member: family.alek, facts: delivered).covered, 1)
        }
    }

    func testConflictingDeclineOrCancelBeforeAcceptanceAndApprovalBeforeRequestNeverCount() throws {
        for kind in [PuntDecisionKind.declined, .cancelled] {
            let family = try TestFamily()
            let pending = try request(family)
            let facts = family.store.snapshot.orderedFacts
            let first = decision(family, pending, kind: kind)
            let later = decision(family, pending, sequence: first.sequence + 1)
            for delivered in [facts + [first, later], [later, first] + facts.reversed()] {
                XCTAssertTrue(stats(family, facts: delivered).isEmpty)
            }
        }
        let family = try TestFamily()
        let pending = try request(family)
        let requestFact = try XCTUnwrap(family.store.snapshot.orderedFacts.first { $0.id == pending.id })
        let early = decision(family, pending, sequence: requestFact.sequence - 1)
        XCTAssertTrue(stats(family, facts: family.store.snapshot.orderedFacts + [early]).isEmpty)
    }

    func testWrongAuthorDayScopeAndStaleAfterCompletionApprovalsNeverCount() throws {
        let family = try TestFamily()
        let pending = try request(family)
        let scope = pending.request.scope
        let wrongScope = PuntScope(choreID: scope.choreID, revisionID: scope.revisionID,
                                  day: scope.day, occurrenceID: UUID())
        for invalid in [decision(family, pending, author: family.hanna.id),
                        decision(family, pending, author: family.parent.id),
                        decision(family, pending, author: UUID()),
                        decision(family, pending, day: scope.day.adding(days: 1, calendar: family.store.calendar)),
                        decision(family, pending, scope: wrongScope)] {
            XCTAssertTrue(stats(family, facts: family.store.snapshot.orderedFacts + [invalid]).isEmpty)
        }
        try family.complete(scope.choreID, as: family.hanna)
        let delayed = decision(family, pending)
        let facts = family.store.snapshot.orderedFacts + [delayed]
        XCTAssertTrue(stats(family, facts: facts).isEmpty)
        XCTAssertTrue(stats(family, facts: Array(facts.reversed())).isEmpty)
    }

    func testHouseholdWeekBoundariesAcrossSundayMondayAndYear() throws {
        let family = try TestFamily()
        family.move(to: "2026-12-28T16:00:00Z")
        let monday = try request(family)
        try accept(family, monday)
        family.move(to: "2027-01-04T04:30:00Z") // Sunday in the household, Monday in UTC.
        XCTAssertEqual(family.store.day.rawValue, "2027-01-03")
        let sunday = try request(family)
        try accept(family, sunday)
        XCTAssertEqual(stats(family).punted, 2)
        XCTAssertTrue(stats(family, week: .lastWeek).isEmpty)
        family.move(to: "2027-01-04T05:00:00Z")
        XCTAssertEqual(PuntStatsWeek.thisWeek.start(today: family.store.day, calendar: family.store.calendar).rawValue,
                       "2027-01-04")
        XCTAssertEqual(stats(family, week: .lastWeek).punted, 2)
        XCTAssertTrue(stats(family).isEmpty)
        let next = try request(family)
        try accept(family, next)
        XCTAssertEqual(stats(family).punted, 1)
        XCTAssertEqual(stats(family, week: .lastWeek).punted, 2)
    }

    func testAsNeededDistinctOccurrencesCountOnceEachIncludingWithdrawnAndCompletedHistory() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(weekday: .monday, title: "Bins", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id], schedulingMode: .asNeeded,
            firstAlternatingMemberID: family.hanna.id)
        for completed in [false, true] {
            try family.store.selectProfile(family.parent.id)
            try family.store.activateAsNeededChore(choreID: chore)
            let row = try XCTUnwrap(family.store.dailyList().first { $0.isActionableOccurrence })
            let sender = try XCTUnwrap(row.turnOwnerID)
            let recipient = sender == family.hanna.id ? family.alek.id : family.hanna.id
            try family.store.selectProfile(sender)
            try family.store.requestPunt(choreID: chore, occurrenceID: row.occurrenceID, recipientID: recipient)
            let pending = try XCTUnwrap(family.store.activity.first { $0.punt?.status == .pending }?.punt)
            try accept(family, pending)
            if completed {
                try family.store.setCompletion(choreID: chore, occurrenceID: row.occurrenceID,
                    memberID: recipient, date: family.clock.now, state: .done)
            } else {
                try family.store.selectProfile(family.parent.id)
                try family.store.withdrawAsNeededOccurrence(choreID: chore, occurrenceID: row.occurrenceID!)
            }
        }
        XCTAssertEqual(stats(family).punted, 2)
        XCTAssertEqual(stats(family, member: family.alek).covered, 2)
    }

    func testMergedJournalAndRelaunchProduceIdenticalStats() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PuntStats-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let family = try TestFamily(url: directory.appending(path: "first.store"))
        let pending = try request(family)
        let before = family.store.snapshot.orderedFacts
        try accept(family, pending)
        let merged = family.store.snapshot.orderedFacts
        XCTAssertTrue(stats(family, facts: before).isEmpty)
        let expected = stats(family)
        let encoded = try JSONEncoder().encode(Array(merged.reversed()) + merged)
        let replay = try JSONDecoder().decode([HouseholdFact].self, from: encoded)
        let second = try HouseholdRepository(url: directory.appending(path: "second.store"))
        try second.commit(facts: replay, session: family.store.session)
        let relaunched = try HouseholdStore(repository: second, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(PuntStatsRules.summary(memberID: family.hanna.id, week: .thisWeek,
            today: relaunched.day, snapshot: relaunched.snapshot), expected)
        XCTAssertEqual(stats(family, facts: Array(merged.reversed())), expected)
        XCTAssertEqual(stats(family).covered, 0)
    }
}

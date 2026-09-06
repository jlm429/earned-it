import XCTest
import CloudKit
@testable import EarnedIt

@MainActor
final class SharingTests: XCTestCase {
    func testJoinedFamilyUsesSameFactsAndPreexistingMembersThroughTransportBoundary() async throws {
        let server = TestCloudServer()
        let ownerTransport = TestTransport(server: server, account: "test-owner")
        let family = try TestFamily(transport: ownerTransport)
        let chore = try family.chore()
        try await family.store.connect()
        let location = try XCTUnwrap(family.store.session.location)
        let guestTransport = TestTransport(server: server, account: "test-guest")
        let guest = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: guestTransport,
                                       clock: { family.clock.now }, automaticSync: false)
        try await guest.join(url: URL(string: "https://test.invalid/\(location.zoneName)")!)
        XCTAssertEqual(server.createCalls, 1, "Accepting must not create a local replacement household or new cloud zone")
        XCTAssertEqual(guest.household?.id, family.store.household?.id)
        XCTAssertEqual(guest.snapshot.members.map(\.id), family.store.snapshot.members.map(\.id))
        XCTAssertTrue(guest.profiles.isEmpty)
        XCTAssertThrowsError(try guest.selectProfile(family.parent.id))
        try guest.requestProfiles([family.hanna.id, family.alek.id], deviceName: "Children’s tablet")
        try await guest.synchronize()
        try await family.store.synchronize()
        let request = try XCTUnwrap(family.store.pendingRequests.first)
        try family.store.approve(request, memberIDs: [family.hanna.id, family.alek.id])
        try await family.store.synchronize()
        try await guest.synchronize()
        XCTAssertEqual(Set(guest.profiles.map(\.id)), [family.hanna.id, family.alek.id])
        XCTAssertThrowsError(try guest.selectProfile(family.parent.id))
        try guest.selectProfile(family.hanna.id)
        try guest.setCompletion(choreID: chore, memberID: family.hanna.id, date: family.clock.now, state: .done)
        try await guest.synchronize()
        try await family.store.synchronize()
        XCTAssertEqual(family.store.dailyList()[0].completedMembers.map(\.id), [family.hanna.id])
        XCTAssertEqual(family.store.dailyList()[0].remainingMembers.map(\.id), [family.alek.id])
        XCTAssertEqual(family.store.snapshot, guest.snapshot)
    }

    func testConcurrentChildCompletionsAndScopedRemovalConverge() async throws {
        let server = TestCloudServer()
        let ownerTransport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: ownerTransport)
        let id = try family.chore()
        try await family.store.connect()
        let peer = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                      transport: TestTransport(server: server, account: "owner"),
                                      clock: { family.clock.now }, automaticSync: false)
        let discovered = try await peer.discoverFamilies()
        try await peer.joinExisting(discovered[0].location)
        XCTAssertNotEqual(peer.session.deviceID, family.store.session.deviceID)
        try family.complete(id, as: family.hanna)
        try peer.selectProfile(family.alek.id)
        try peer.setCompletion(choreID: id, memberID: family.alek.id, date: family.clock.now, state: .done)
        try await family.store.synchronize()
        try await peer.synchronize()
        try await family.store.synchronize()
        XCTAssertTrue(family.store.dailyList()[0].isFullyComplete)
        XCTAssertEqual(family.store.snapshot, peer.snapshot)
        try family.complete(id, as: family.hanna, state: .unmarked)
        try await family.store.synchronize()
        try await peer.synchronize()
        XCTAssertEqual(peer.dailyList()[0].state(for: family.alek.id), .done)
        XCTAssertEqual(peer.dailyList()[0].state(for: family.hanna.id), .unmarked)
        XCTAssertEqual(server.createCalls, 1)
    }

    func testPartialUploadRetryIsIdempotentAndLocalQueueSurvivesRelaunch() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        _ = try family.chore()
        server.failUploadAfter = 2
        do { try await family.store.connect(); XCTFail("Expected a partial transport failure") } catch {}
        XCTAssertGreaterThan(family.store.pendingCount, 0)
        XCTAssertFalse(family.store.cloudAccessBlocked, "Transient network loss should permit offline work")
        let reopened = try HouseholdStore(repository: family.repository, transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        XCTAssertGreaterThan(reopened.pendingCount, 0)
        server.failUploadAfter = nil
        try await reopened.synchronize()
        XCTAssertEqual(reopened.pendingCount, 0)
        let cloudCount = server.zones.values.first!.facts.count
        try await reopened.synchronize()
        XCTAssertEqual(server.zones.values.first!.facts.count, cloudCount)
        XCTAssertEqual(HouseholdSnapshot(facts: Array(server.zones.values.first!.facts.values)), reopened.snapshot)
    }

    func testAccountChangeStopsUploadsAndDoesNotReassociateMembers() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        let id = try family.chore()
        try await family.store.connect()
        try family.complete(id, as: family.hanna)
        let uploadedBefore = transport.uploadedIDs.count
        transport.account = "different-account"
        do { try await family.store.synchronize(); XCTFail("Expected account mismatch") }
        catch { XCTAssertEqual(error as? HouseholdError, .wrongAccount) }
        XCTAssertTrue(family.store.cloudAccessBlocked)
        XCTAssertEqual(transport.uploadedIDs.count, uploadedBefore)
        XCTAssertGreaterThan(family.store.pendingCount, 0)
        XCTAssertThrowsError(try family.store.setCompletion(choreID: id, memberID: family.hanna.id, date: family.clock.now, state: .unmarked))
        transport.account = "owner"
        try await family.store.synchronize()
        XCTAssertFalse(family.store.cloudAccessBlocked)
        XCTAssertEqual(family.store.pendingCount, 0)
    }

    func testReadOnlyShareAndRevokedProfileRestrictWrites() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let id = try family.chore()
        try await family.store.connect()
        let guest = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: "guest"),
                                       clock: { family.clock.now }, automaticSync: false)
        try await guest.join(url: URL(string: "https://test.invalid/\(family.store.session.location!.zoneName)")!)
        try guest.requestProfiles([family.hanna.id], deviceName: "Test Phone")
        try await guest.synchronize()
        try await family.store.synchronize()
        try family.store.approve(family.store.pendingRequests[0], memberIDs: [family.hanna.id])
        try await family.store.synchronize()
        try await guest.synchronize()
        try guest.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try guest.approve(guest.currentRequest!, memberIDs: [family.parent.id]))
        server.writeAllowed = false
        try await guest.synchronize()
        XCTAssertThrowsError(try guest.setCompletion(choreID: id, memberID: family.hanna.id, date: family.clock.now, state: .done))
        server.writeAllowed = true
        try family.store.revoke(family.store.snapshot.grants[0])
        try await family.store.synchronize()
        try await guest.synchronize()
        XCTAssertNil(guest.selectedMember)
        XCTAssertTrue(guest.profiles.isEmpty)
    }

    func testInvalidInvitationAndUnavailableCloudNeverCreateAFamily() async throws {
        let server = TestCloudServer()
        let guest = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: "guest"), automaticSync: false)
        do { try await guest.join(url: URL(string: "https://test.invalid/missing")!); XCTFail("Invalid invitation") } catch {}
        XCTAssertNil(guest.household)
        XCTAssertEqual(server.createCalls, 0)
        let offline = try HouseholdStore(repository: HouseholdRepository(inMemory: true), automaticSync: false)
        do { _ = try await offline.discoverFamilies(); XCTFail("No provisioned transport") }
        catch { XCTAssertEqual(error as? HouseholdError, .cloudUnavailable) }
        XCTAssertNil(offline.household)
    }


    func testReadOnlyPermissionPersistsAcrossReopening() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        server.writeAllowed = false
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "guest")
        let guest = try HouseholdStore(repository: repository, transport: transport,
                                       clock: { family.clock.now }, automaticSync: false)
        try await guest.join(url: URL(string: "https://test.invalid/\(family.store.session.location!.zoneName)")!)
        let reopened = try HouseholdStore(repository: repository, transport: transport,
                                          clock: { family.clock.now }, automaticSync: false)
        XCTAssertTrue(reopened.cloudIsReadOnly)
        XCTAssertThrowsError(try reopened.requestProfiles([family.hanna.id], deviceName: "Test Phone"))
    }

    func testIncompleteRemoteSetupDoesNotCommitAJoinedHousehold() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let location = family.store.session.location!
        let memberFacts = server.zones[location.zoneName]!.facts.filter { _, fact in
            if case .member(let member) = fact.body { return member.role == .child }
            return false
        }
        for id in memberFacts.keys { server.zones[location.zoneName]?.facts.removeValue(forKey: id) }
        let guest = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: "guest"),
                                       clock: { family.clock.now }, automaticSync: false)
        do { try await guest.join(url: URL(string: "https://test.invalid/\(location.zoneName)")!); XCTFail("Incomplete import") }
        catch { XCTAssertEqual(error as? HouseholdError, .familyStillSyncing) }
        XCTAssertNil(guest.household)
        for (id, fact) in memberFacts { server.zones[location.zoneName]?.facts[id] = fact }
        try await guest.join(url: URL(string: "https://test.invalid/\(location.zoneName)")!)
        XCTAssertEqual(guest.household?.id, family.store.household?.id)
    }

    func testDeterministicRevisionResolutionRegardlessOfDeliveryOrder() throws {
        let family = try TestFamily()
        let id = try family.chore()
        try family.store.saveChore(choreID: id, weekday: .monday, title: "Updated", mode: .particular, memberIDs: [family.hanna.id])
        let facts = try family.repository.facts(householdID: family.store.household!.id)
        XCTAssertEqual(HouseholdSnapshot(facts: facts), HouseholdSnapshot(facts: facts.reversed()))
    }
    func testRecordedRequiredAssignmentSurvivesOfflineAnyOneRevision() async throws {
        try await checkRecordedAssignment(state: .done)
    }

    func testRecordedMissedAssignmentSurvivesOfflineAnyOneRevision() async throws {
        try await checkRecordedAssignment(state: .missed)
    }

    func testRecordedReversalAssignmentSurvivesOfflineAnyOneRevision() async throws {
        try await checkRecordedAssignment(state: .unmarked)
    }

    private func checkRecordedAssignment(state: DailyStateKind) async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let id = try family.chore(.multiple, ids: [family.hanna.id, family.alek.id])
        try await family.store.connect()
        let peer = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                      transport: TestTransport(server: server, account: "owner"),
                                      clock: { family.clock.now }, automaticSync: false)
        try await peer.joinExisting(family.store.session.location!)
        family.move(to: "2026-09-13T16:00:00Z")
        try family.store.saveChore(choreID: id, weekday: .monday, title: "Water plants",
                                  mode: .anyOne, memberIDs: [family.hanna.id, family.alek.id])
        family.move(to: "2026-09-14T16:00:00Z")
        try peer.selectProfile(family.parent.id)
        try peer.setCompletion(choreID: id, memberID: family.hanna.id, date: family.clock.now, state: state)
        try await family.store.synchronize()
        try await peer.synchronize()
        try await family.store.synchronize()
        XCTAssertEqual(peer.snapshot, family.store.snapshot)
        let chore = try XCTUnwrap(peer.dailyList().first)
        XCTAssertEqual(chore.configuration.mode, .anyOne)
        XCTAssertEqual(chore.requiredCompletionCount, 2)
        XCTAssertFalse(chore.isFullyComplete)
        XCTAssertEqual(Set(chore.remainingMembers.map(\.id)), state.isAccountedFor ? [family.alek.id] : [family.hanna.id, family.alek.id])
        XCTAssertEqual(peer.weekFacts(for: family.hanna.id)[0].accountedCount, state.isAccountedFor ? 1 : 0)
        XCTAssertEqual(peer.weekFacts(for: family.hanna.id)[0].expectedCount, 1)
        XCTAssertEqual(peer.weekFacts(for: family.alek.id)[0].expectedCount, 1)
        XCTAssertEqual(peer.weekFacts(for: family.alek.id)[0].accountedCount, 0)
        try peer.setCompletion(choreID: id, memberID: family.hanna.id, date: family.clock.now, state: .unmarked)
        XCTAssertEqual(peer.dailyList()[0].requiredCompletionCount, 2)
        XCTAssertEqual(peer.dailyList()[0].creditState(for: family.hanna.id), .unmarked)
    }

    func testRejectedOfflineCompletionAllowsRequestsAndRecoversAfterApproval() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let id = try family.chore()
        try await family.store.connect()
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "guest")
        let guest = try HouseholdStore(repository: repository, transport: transport,
                                       clock: { family.clock.now }, automaticSync: false)
        try await guest.join(url: URL(string: "https://test.invalid/\(family.store.session.location!.zoneName)")!)
        try guest.requestProfiles([family.hanna.id], deviceName: "Tablet")
        try await guest.synchronize()
        try await family.store.synchronize()
        try family.store.approve(family.store.pendingRequests[0], memberIDs: [family.hanna.id])
        try await family.store.synchronize()
        try await guest.synchronize()
        try guest.selectProfile(family.hanna.id)
        try guest.setCompletion(choreID: id, memberID: family.hanna.id, date: family.clock.now, state: .done)
        let completion = try XCTUnwrap(repository.pending(householdID: family.store.household!.id).first)
        try family.store.revoke(family.store.snapshot.grants[0])
        try await family.store.synchronize()
        try guest.requestProfiles([family.hanna.id], deviceName: "Tablet")
        try await guest.synchronize()
        XCTAssertEqual(guest.pendingCount, 0)
        XCTAssertNotNil(guest.rejectedChanges[completion.id])
        XCTAssertFalse(transport.uploadedIDs.contains(completion.id))
        XCTAssertEqual(guest.snapshot.completions.first?.state, .done)
        let reopened = try HouseholdStore(repository: repository, transport: transport,
                                          clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.rejectedChanges, guest.rejectedChanges)
        try await family.store.synchronize()
        XCTAssertEqual(family.store.pendingRequests.count, 1)
        try family.store.approve(family.store.pendingRequests[0], memberIDs: [family.hanna.id])
        try await family.store.synchronize()
        try await reopened.synchronize()
        XCTAssertTrue(reopened.rejectedChanges.isEmpty)
        XCTAssertTrue(transport.uploadedIDs.contains(completion.id))
    }

    func testConcurrentParentArchivesRetainOriginalParentInBothMergeOrders() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let second = try family.store.saveMember(name: "Second Parent", role: .parent, avatar: .star)
        family.move(to: "2026-09-13T16:00:00Z")
        try await family.store.connect()
        let peerRepository = try HouseholdRepository(inMemory: true)
        let peer = try HouseholdStore(repository: peerRepository,
                                      transport: TestTransport(server: server, account: "owner"),
                                      clock: { family.clock.now }, automaticSync: false)
        try await peer.joinExisting(family.store.session.location!)
        try peer.selectProfile(second.id)
        try peer.archiveMember(family.parent.id)
        try family.store.archiveMember(second.id)
        let householdID = family.store.household!.id
        let local = try family.repository.facts(householdID: householdID)
        let remote = try peerRepository.facts(householdID: householdID)
        let combined = Array(Dictionary((local + remote).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        let forward = HouseholdSnapshot(facts: combined)
        XCTAssertEqual(forward, HouseholdSnapshot(facts: combined.reversed()))
        XCTAssertTrue(forward.isActive(forward.member(family.parent.id)!, on: family.store.tomorrow))
        XCTAssertNotNil(forward.member(family.parent.id)?.archivedFrom)
        XCTAssertNotNil(forward.member(second.id)?.archivedFrom)
        XCTAssertTrue(combined.contains { fact in
            if case .member(let member) = fact.body { return member.id == family.parent.id && member.archivedFrom != nil }
            return false
        })
        try await family.store.synchronize()
        try await peer.synchronize()
        try await family.store.synchronize()
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertEqual(family.store.profiles.filter { $0.role == .parent }.map(\.id), [family.parent.id])
        XCTAssertEqual(family.store.snapshot, peer.snapshot)
        let replacement = try family.store.saveMember(name: "Replacement Parent", role: .parent, avatar: .sun)
        XCTAssertEqual(replacement.joinedDay.rawValue, "2026-09-15")
        XCTAssertEqual(family.store.profiles.filter { $0.role == .parent }.map(\.id), [family.parent.id])
        let replacementFacts = try family.repository.facts(householdID: householdID)
        XCTAssertEqual(HouseholdSnapshot(facts: replacementFacts), HouseholdSnapshot(facts: replacementFacts.reversed()))
        try await family.store.synchronize()
        try await peer.synchronize()
        XCTAssertEqual(family.store.snapshot, peer.snapshot)
        family.move(to: "2026-09-15T16:00:00Z")
        XCTAssertEqual(family.store.profiles.filter { $0.role == .parent }.map(\.id), [replacement.id])
        let monday = CivilDay(rawValue: "2026-09-14")!
        XCTAssertTrue(family.store.snapshot.isActive(family.store.snapshot.member(family.parent.id)!, on: monday))
    }

    func testArchivedAuthorRejectionRetainsEvidenceAcrossDisconnect() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let chore = try family.chore()
        try await family.store.connect()
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "owner")
        let peer = try HouseholdStore(repository: repository, transport: transport,
                                      clock: { family.clock.now }, automaticSync: false)
        let location = family.store.session.location!
        try await peer.joinExisting(location)
        try peer.selectProfile(family.hanna.id)
        try peer.setCompletion(choreID: chore, memberID: family.hanna.id, date: family.clock.now, state: .done)
        let completion = try XCTUnwrap(repository.pending(householdID: location.householdID).first)
        try family.store.archiveMember(family.hanna.id)
        try await family.store.synchronize()
        family.clock.set("2026-09-08T16:00:00Z")
        try await peer.synchronize()
        XCTAssertNotNil(peer.rejectedChanges[completion.id])
        XCTAssertFalse(transport.uploadedIDs.contains(completion.id))
        try peer.selectProfile(family.parent.id)
        try peer.saveMember(name: "New Child", role: .child, avatar: .star)
        try await peer.synchronize()
        XCTAssertEqual(peer.pendingCount, 0)
        try peer.resetLocalData()
        XCTAssertNil(peer.household)
        XCTAssertTrue(try repository.facts(householdID: location.householdID).contains(completion))
        try await peer.joinExisting(location)
        XCTAssertNotNil(peer.rejectedChanges[completion.id])
        XCTAssertEqual(peer.snapshot.completions.first?.state, .done)
    }

    func testRejectedChoreRetainsDependentCompletionAndAllowsFreshJoin() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let second = try family.store.saveMember(name: "Second Parent", role: .parent, avatar: .star)
        family.move(to: "2026-09-14T16:00:00Z")
        let existing = try family.chore()
        try await family.store.connect()
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "owner")
        let peer = try HouseholdStore(repository: repository, transport: transport,
                                      clock: { family.clock.now }, automaticSync: false)
        let location = family.store.session.location!
        try await peer.joinExisting(location)
        try peer.selectProfile(second.id)
        let rejectedChore = try peer.saveChore(weekday: .monday, title: "Offline chore", mode: .all, memberIDs: [])
        try peer.selectProfile(family.hanna.id)
        try peer.setCompletion(choreID: rejectedChore, memberID: family.hanna.id, date: family.clock.now, state: .done)
        try peer.setCompletion(choreID: existing, memberID: family.hanna.id, date: family.clock.now, state: .done)
        let pending = try repository.pending(householdID: location.householdID)
        let dependent = try XCTUnwrap(pending.first { fact in
            if case .completion(let value) = fact.body { return value.choreID == rejectedChore }
            return false
        })
        try family.store.archiveMember(second.id)
        try await family.store.synchronize()
        family.clock.set("2026-09-15T16:00:00Z")
        try await peer.synchronize()
        XCTAssertEqual(peer.rejectedChanges.count, 2)
        XCTAssertNotNil(peer.rejectedChanges[dependent.id])
        XCTAssertFalse(transport.uploadedIDs.contains(dependent.id))
        XCTAssertTrue(try repository.facts(householdID: location.householdID).contains(dependent))
        let fresh = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: "owner"),
                                       clock: { family.clock.now }, automaticSync: false)
        try await fresh.joinExisting(location)
        XCTAssertEqual(fresh.household?.id, location.householdID)
        XCTAssertEqual(fresh.snapshot.completions.count, 1)
        XCTAssertEqual(fresh.snapshot.completions.first?.choreID, existing)
        XCTAssertFalse(fresh.snapshot.revisions.contains { $0.choreID == rejectedChore })
    }

}

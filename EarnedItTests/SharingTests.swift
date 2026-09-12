import XCTest
import CloudKit
@testable import EarnedIt

@MainActor
final class SharingTests: XCTestCase {
    func testNewChildAndOfflineCompletionReconcileWithoutBackdatingOrReplacingContributions() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let all = try family.chore()
        let particular = try family.chore(.particular, ids: [family.hanna.id])
        let previousMonday = family.clock.now
        try family.complete(all, as: family.hanna)
        try family.store.selectProfile(family.parent.id)
        try await family.store.connect()
        let guestRepository = try HouseholdRepository(inMemory: true)
        let guestTransport = TestTransport(server: server, account: "guest")
        let guest = try HouseholdStore(repository: guestRepository, transport: guestTransport,
                                       clock: { family.clock.now }, automaticSync: false)
        let location = try XCTUnwrap(family.store.session.location)
        try await guest.join(url: URL(string: "https://test.invalid/\(location.zoneName)")!)
        try guest.requestProfiles([family.alek.id], deviceName: "Child device")
        try await guest.synchronize()
        try await family.store.synchronize()
        try family.store.approve(XCTUnwrap(family.store.pendingRequests.first), memberIDs: [family.alek.id])
        try await family.store.synchronize()
        try await guest.synchronize()
        family.move(to: "2026-09-14T16:00:00Z")
        try guest.selectProfile(family.alek.id)
        try guest.setCompletion(choreID: all, memberID: family.alek.id, date: family.clock.now, state: .done)
        let offlineCompletion = try XCTUnwrap(guest.snapshot.completions.first { $0.day == family.store.day })
        let child = try family.store.saveMember(name: "New Child", role: .child, avatar: .star)
        try await family.store.synchronize()
        try await guest.synchronize()
        try await family.store.synchronize()
        let row = try XCTUnwrap(guest.dailyList().first { $0.id == all })
        XCTAssertEqual(Set(row.requiredMembers.map(\.id)), [family.hanna.id, family.alek.id, child.id])
        XCTAssertTrue(row.contributions.contains(offlineCompletion))
        XCTAssertEqual(guest.snapshot, family.store.snapshot)
        XCTAssertEqual(guest.dailyList().first { $0.id == particular }?.eligibleMembers.map(\.id), [family.hanna.id])
        XCTAssertFalse(guest.dailyList(on: previousMonday).contains { $0.eligibleMembers.contains { $0.id == child.id } })
        XCTAssertThrowsError(try guest.selectProfile(child.id))
        try guest.requestProfiles([family.alek.id, child.id], deviceName: "Child device")
        try await guest.synchronize()
        try await family.store.synchronize()
        try family.store.approve(XCTUnwrap(family.store.pendingRequests.first), memberIDs: [family.alek.id, child.id])
        try await family.store.synchronize()
        try await guest.synchronize()
        try guest.selectProfile(child.id)
        try guest.setCompletion(choreID: all, memberID: child.id, date: family.clock.now, state: .done)
        try await guest.synchronize()
        try await family.store.synchronize()
        try guest.setCompletion(choreID: all, memberID: child.id, date: family.clock.now, state: .unmarked)
        try await guest.synchronize()
        try await family.store.synchronize()
        let reopened = try HouseholdStore(repository: guestRepository, transport: guestTransport,
                                          clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.dailyList(), family.store.dailyList())
        XCTAssertEqual(reopened.dailyList().first { $0.id == all }?.state(for: family.alek.id), .done)
        XCTAssertEqual(reopened.dailyList().first { $0.id == all }?.state(for: child.id), .unmarked)
        let facts = try guestRepository.facts(householdID: location.householdID)
        XCTAssertEqual(HouseholdSnapshot(facts: facts.reversed()), reopened.snapshot)
        let newInstallation = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                                 transport: TestTransport(server: server, account: "owner"),
                                                 clock: { family.clock.now }, automaticSync: false)
        try await newInstallation.joinExisting(location)
        XCTAssertEqual(newInstallation.dailyList(), reopened.dailyList())
    }

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
        let invitation = try await family.store.createChildInvitation(memberID: family.alek.id)
        let peer = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                      transport: TestTransport(server: server, account: "alek-device"),
                                      clock: { family.clock.now }, automaticSync: false)
        try await peer.redeemInvitation(invitation.qrPayload)
        XCTAssertNotEqual(peer.session.deviceID, family.store.session.deviceID)
        try family.complete(id, as: family.hanna)
        XCTAssertEqual(peer.selectedMember?.id, family.alek.id)
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
    func testLosingRequiredAssignmentBecomesHistoryAfterOfflineReassignment() async throws {
        try await checkRecordedAssignment(state: .done)
    }

    func testLosingMissedAssignmentBecomesHistoryAfterOfflineReassignment() async throws {
        try await checkRecordedAssignment(state: .missed)
    }

    func testLosingReversalAssignmentBecomesHistoryAfterOfflineReassignment() async throws {
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
        try await authorizeLegacyInstallation(peer, memberIDs: [family.parent.id], parentStore: family.store)
        family.move(to: "2026-09-13T16:00:00Z")
        try family.store.saveChore(choreID: id, weekday: .monday, title: "Water plants",
                                  mode: .particular, memberIDs: [family.alek.id])
        family.move(to: "2026-09-14T16:00:00Z")
        try peer.selectProfile(family.parent.id)
        try peer.setCompletion(choreID: id, memberID: family.hanna.id, date: family.clock.now, state: state)
        try await family.store.synchronize()
        try await peer.synchronize()
        try await family.store.synchronize()
        XCTAssertEqual(peer.snapshot, family.store.snapshot)
        let chore = try XCTUnwrap(peer.dailyList().first)
        XCTAssertEqual(chore.configuration.mode, .particular)
        XCTAssertEqual(chore.requiredCompletionCount, 1)
        XCTAssertFalse(chore.isFullyComplete)
        XCTAssertEqual(chore.remainingMembers.map(\.id), [family.alek.id])
        XCTAssertEqual(peer.weekFacts(for: family.hanna.id)[0].accountedCount, 0)
        XCTAssertEqual(peer.weekFacts(for: family.hanna.id)[0].expectedCount, 0)
        XCTAssertEqual(peer.weekFacts(for: family.alek.id)[0].expectedCount, 1)
        XCTAssertEqual(peer.weekFacts(for: family.alek.id)[0].accountedCount, 0)
        XCTAssertEqual(chore.historicalContributions.map(\.state), [state])
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
        try await authorizeLegacyInstallation(peer, memberIDs: [second.id], parentStore: family.store)
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
        try await authorizeLegacyInstallation(peer, memberIDs: [family.hanna.id, family.parent.id], parentStore: family.store)
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
        try await authorizeLegacyInstallation(peer, memberIDs: [second.id, family.hanna.id], parentStore: family.store)
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

    func testConfirmedCloudKitSavesStopBeforeDependentAcrossOldBatchBoundary() async throws {
        let family = try TestFamily()
        for index in 0..<101 {
            _ = try family.store.saveChore(weekday: .monday, title: "Chore \(index)", mode: .all, memberIDs: [])
        }
        let chore = try family.chore()
        try family.complete(chore, as: family.hanna)
        let facts = try family.repository.facts(householdID: family.store.household!.id)
        let revision = try XCTUnwrap(facts.first { fact in
            if case .chore(let value) = fact.body { return value.choreID == chore }
            return false
        })
        let completion = try XCTUnwrap(facts.first { fact in
            if case .completion(let value) = fact.body { return value.choreID == chore }
            return false
        })
        let location = CloudLocation(householdID: family.store.household!.id, zoneName: "Test", ownerName: "Owner", isOwner: true)
        var saved: [CKRecord.ID: CKRecord] = [:]
        var rejectRevision = true
        var attempted: [String] = []
        func save(_ record: CKRecord) async throws -> CKRecord {
            attempted.append(record.recordID.recordName)
            if record.recordID.recordName == revision.id.uuidString && rejectRevision { throw CKError(.networkFailure) }
            if let existing = saved[record.recordID] {
                throw CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: existing])
            }
            saved[record.recordID] = record
            return record
        }
        do {
            try await CloudKitHouseholdTransport.uploadConfirmed(facts.reversed(), to: location, save: save)
            XCTFail("Expected prerequisite save failure")
        } catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
        XCTAssertGreaterThan(saved.count, 100)
        XCTAssertFalse(attempted.contains(completion.id.uuidString))
        XCTAssertFalse(saved.values.contains { $0.recordID.recordName == completion.id.uuidString })
        rejectRevision = false
        try await CloudKitHouseholdTransport.uploadConfirmed(facts.reversed(), to: location, save: save)
        XCTAssertEqual(saved.count, facts.count)
        try await CloudKitHouseholdTransport.uploadConfirmed(facts, to: location, save: save)
        XCTAssertEqual(saved.count, facts.count)
        let remoteFacts = try saved.values.map { try JSONDecoder().decode(HouseholdFact.self, from: $0["payload"] as! Data) }
        XCTAssertEqual(HouseholdSnapshot(facts: remoteFacts), family.store.snapshot)
    }

    func testSuspendedConnectionCannotAttachAfterResetAndNewFamily() async throws {
        for createReplacement in [false, true] {
            let server = TestCloudServer()
            let transport = TestTransport(server: server, account: "owner")
            let family = try TestFamily(transport: transport)
            let suspended = expectation(description: "Zone creation suspended")
            var resume: CheckedContinuation<Void, Never>?
            transport.beforeCreateZone = {
                await withCheckedContinuation { continuation in
                    resume = continuation
                    suspended.fulfill()
                }
            }
            let connection = Task { try await family.store.connect() }
            await fulfillment(of: [suspended], timeout: 5)
            try family.store.resetLocalData()
            if createReplacement { try family.store.createFamily(name: "Replacement", parentName: "New Parent") }
            let expectedSession = family.store.session
            resume?.resume()
            do { try await connection.value; XCTFail("Stale connection must fail") }
            catch { XCTAssertEqual(error as? HouseholdError, .noHousehold) }
            XCTAssertEqual(family.store.session, expectedSession)
            XCTAssertNil(family.store.session.location)
            XCTAssertTrue(transport.uploadedIDs.isEmpty)
            XCTAssertEqual(family.store.household?.name, createReplacement ? "Replacement" : nil)
        }
    }

    func testApprovedParentCanDisconnectFromReadOnlyShare() async throws {
        let fixture = try await approvedParentInstallation()
        fixture.server.writeAllowed = false
        try await fixture.store.synchronize()
        XCTAssertTrue(fixture.store.cloudIsReadOnly)
        try checkLocalDisconnect(fixture)
    }

    func testApprovedParentCanDisconnectFromRevokedShare() async throws {
        let fixture = try await approvedParentInstallation()
        let location = try XCTUnwrap(fixture.store.session.location)
        fixture.server.zones[location.zoneName]?.participants.remove("guest")
        do { try await fixture.store.synchronize(); XCTFail("Revocation must fail cloud fetch") }
        catch { XCTAssertEqual((error as? CKError)?.code, .permissionFailure) }
        XCTAssertTrue(fixture.store.cloudAccessBlocked)
        try checkLocalDisconnect(fixture)
    }

    func testApprovedParentCanDisconnectFromWritableShare() async throws {
        try checkLocalDisconnect(try await approvedParentInstallation())
    }

    func testDisconnectStillRequiresLocalParentAndKeepsPendingWritesAfterCloudLoss() async throws {
        for readOnly in [true, false] {
            let fixture = try await approvedParentInstallation()
            _ = try fixture.store.saveChore(weekday: .monday, title: "Offline chore", mode: .all, memberIDs: [])
            let location = try XCTUnwrap(fixture.store.session.location)
            if readOnly { fixture.server.writeAllowed = false }
            else { fixture.server.zones[location.zoneName]?.participants.remove("guest") }
            do { try await fixture.store.synchronize(); XCTFail("Cloud cannot accept the pending write") } catch {}
            let facts = try fixture.repository.facts(householdID: location.householdID)
            XCTAssertGreaterThan(fixture.store.pendingCount, 0)
            for profile in [fixture.family.hanna.id, nil] as [UUID?] {
                try fixture.store.selectProfile(profile)
                let session = fixture.store.session
                XCTAssertThrowsError(try fixture.store.resetLocalData()) {
                    XCTAssertEqual($0 as? HouseholdError, .permission)
                }
                XCTAssertEqual(try fixture.repository.session(), session)
            }
            try fixture.store.selectProfile(fixture.family.parent.id)
            let session = fixture.store.session
            XCTAssertThrowsError(try fixture.store.resetLocalData()) {
                XCTAssertEqual($0 as? HouseholdError, .pendingChanges)
            }
            XCTAssertEqual(fixture.store.session, session)
            XCTAssertEqual(try fixture.repository.session(), session)
            XCTAssertEqual(Set(try fixture.repository.facts(householdID: location.householdID).map(\.id)), Set(facts.map(\.id)))
            XCTAssertThrowsError(try fixture.store.saveMember(name: "Still blocked", role: .child, avatar: .star))
        }
    }

    func testDisconnectRetainsRejectedEvidenceAfterCloudLoss() async throws {
        for readOnly in [true, false] {
            let fixture = try await approvedParentInstallation()
            let chore = try fixture.family.chore()
            try await fixture.family.store.synchronize()
            try await fixture.store.synchronize()
            try fixture.store.selectProfile(fixture.family.hanna.id)
            try fixture.store.setCompletion(choreID: chore, memberID: fixture.family.hanna.id,
                                            date: fixture.family.clock.now, state: .done)
            let location = try XCTUnwrap(fixture.store.session.location)
            let completion = try XCTUnwrap(fixture.repository.pending(householdID: location.householdID).first)
            try fixture.family.store.approve(XCTUnwrap(fixture.store.currentRequest), memberIDs: [fixture.family.parent.id])
            try await fixture.family.store.synchronize()
            try await fixture.store.synchronize()
            try fixture.store.selectProfile(fixture.family.parent.id)
            XCTAssertEqual(fixture.store.pendingCount, 0)
            XCTAssertNotNil(fixture.store.rejectedChanges[completion.id])
            let facts = try fixture.repository.facts(householdID: location.householdID)
            if readOnly {
                fixture.server.writeAllowed = false
                try await fixture.store.synchronize()
            } else {
                fixture.server.zones[location.zoneName]?.participants.remove("guest")
                do { try await fixture.store.synchronize(); XCTFail("Share was revoked") } catch {}
            }
            let reasons = fixture.store.rejectedChanges
            try fixture.store.resetLocalData()
            XCTAssertNil(fixture.store.household)
            XCTAssertEqual(Set(try fixture.repository.facts(householdID: location.householdID).map(\.id)), Set(facts.map(\.id)))
            XCTAssertEqual(try fixture.repository.rejections(householdID: location.householdID), reasons)
            XCTAssertFalse(fixture.transport.uploadedIDs.contains(completion.id))
            let reopened = try HouseholdStore(repository: fixture.repository, transport: fixture.transport,
                                              clock: { fixture.family.clock.now }, automaticSync: false)
            XCTAssertNil(reopened.household)
            fixture.server.writeAllowed = true
            try await reopened.join(url: URL(string: "https://test.invalid/\(location.zoneName)")!)
            XCTAssertEqual(reopened.rejectedChanges, reasons)
            XCTAssertEqual(reopened.snapshot.completions.first?.state, .done)
        }
    }

    func testDisconnectCannotInterruptAnActiveSynchronization() async throws {
        let fixture = try await approvedParentInstallation()
        let suspended = expectation(description: "Fetch suspended")
        var resume: CheckedContinuation<Void, Never>?
        fixture.transport.beforeFetch = {
            await withCheckedContinuation { continuation in
                resume = continuation
                suspended.fulfill()
            }
        }
        let session = fixture.store.session
        let syncing = Task { try await fixture.store.synchronize() }
        await fulfillment(of: [suspended], timeout: 5)
        XCTAssertTrue(fixture.store.isSyncing)
        XCTAssertThrowsError(try fixture.store.resetLocalData()) {
            XCTAssertEqual($0 as? HouseholdError, .pendingChanges)
        }
        XCTAssertEqual(fixture.store.session, session)
        XCTAssertEqual(try fixture.repository.session(), session)
        resume?.resume()
        try await syncing.value
        XCTAssertFalse(fixture.store.isSyncing)
    }

    private typealias ParentInstallation = (family: TestFamily, server: TestCloudServer,
        store: HouseholdStore, repository: HouseholdRepository, transport: TestTransport)

    private func approvedParentInstallation() async throws -> ParentInstallation {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "guest")
        let store = try HouseholdStore(repository: repository, transport: transport,
                                       clock: { family.clock.now }, automaticSync: false)
        let location = try XCTUnwrap(family.store.session.location)
        try await store.join(url: URL(string: "https://test.invalid/\(location.zoneName)")!)
        try store.requestProfiles([family.parent.id, family.hanna.id], deviceName: "Parent tablet")
        try await store.synchronize()
        try await family.store.synchronize()
        try family.store.approve(XCTUnwrap(family.store.pendingRequests.first),
                                memberIDs: [family.parent.id, family.hanna.id])
        try await family.store.synchronize()
        try await store.synchronize()
        try store.selectProfile(family.parent.id)
        return (family, server, store, repository, transport)
    }

    private func authorizeLegacyInstallation(_ store: HouseholdStore, memberIDs: [UUID],
                                             parentStore: HouseholdStore) async throws {
        try store.requestProfiles(memberIDs, deviceName: "Existing shared installation")
        try await store.synchronize()
        try await parentStore.synchronize()
        try parentStore.approve(XCTUnwrap(parentStore.pendingRequests.first), memberIDs: memberIDs)
        try await parentStore.synchronize()
        try await store.synchronize()
    }

    private func checkLocalDisconnect(_ fixture: ParentInstallation) throws {
        XCTAssertEqual(fixture.store.selectedMember?.role, .parent)
        XCTAssertEqual(fixture.store.pendingCount, 0)
        let householdID = try XCTUnwrap(fixture.store.household?.id)
        let location = try XCTUnwrap(fixture.store.session.location)
        let remoteFacts = fixture.server.zones[location.zoneName]?.facts
        let oldDeviceID = fixture.store.session.deviceID
        try fixture.store.resetLocalData()
        XCTAssertNil(fixture.store.household)
        XCTAssertNil(fixture.store.session.location)
        XCTAssertNotEqual(fixture.store.session.deviceID, oldDeviceID)
        XCTAssertTrue(try fixture.repository.facts(householdID: householdID).isEmpty)
        XCTAssertEqual(fixture.server.zones[location.zoneName]?.facts, remoteFacts)
        let reopened = try HouseholdStore(repository: fixture.repository, automaticSync: false)
        XCTAssertNil(reopened.household)
        XCTAssertEqual(reopened.session, fixture.store.session)
    }

}

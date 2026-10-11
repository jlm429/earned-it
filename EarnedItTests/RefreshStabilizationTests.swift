import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class RefreshStabilizationTests: XCTestCase {
    private func peer(_ family: TestFamily, server: TestCloudServer) async throws
        -> (HouseholdStore, HouseholdRepository, TestTransport) {
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "child-account")
        let store = try HouseholdStore(repository: repository, transport: transport,
            clock: { family.clock.now }, automaticSync: false)
        try await store.redeemInvitation(invitation.qrPayload)
        return (store, repository, transport)
    }

    private func available(_ family: TestFamily, title: String) throws -> UUID {
        let id = try family.store.saveChore(weekday: .monday, title: title, mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded)
        try family.store.activateAsNeededChore(choreID: id)
        return id
    }

    func testCancelledWaitingChildRefreshAfterDeleteAndRecreateDoesNotPresentError() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let old = try available(family, title: "test")
        let (child, repository, transport) = try await peer(family, server: server)
        XCTAssertTrue(child.dailyList().contains { $0.choreID == old })
        try family.store.deleteChore(old)
        let replacement = try available(family, title: "test2")
        XCTAssertNotEqual(old, replacement)
        try await family.store.synchronize()

        // Startup reconciliation owns the same mutation lock as automatic sync.
        let gate = TestSuspensionGate()
        transport.beforeFetch = { transport.beforeFetch = nil; await gate.wait() }
        let startup = Task { try await child.reconcileAccountMembershipLockAutomatically() }
        while !gate.isWaiting { await Task.yield() }
        let refresh = Task {
            await child.refresh()
        }
        await Task.yield()
        refresh.cancel()
        gate.resume()
        await refresh.value
        try await startup.value
        XCTAssertNil(child.errorMessage, "View cancellation must not show Unable to Update")
        try await child.synchronize()
        XCTAssertFalse(child.dailyList().contains { $0.choreID == old && $0.isActionableOccurrence })
        XCTAssertTrue(child.dailyList().contains { $0.choreID == replacement && $0.isActionableOccurrence })
        try await family.store.synchronize()
        XCTAssertEqual(child.snapshot, family.store.snapshot)
        let reopened = try HouseholdStore(repository: repository, transport: transport,
            clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.snapshot, child.snapshot)
        XCTAssertEqual(reopened.dailyList(), child.dailyList())
    }

    func testOverlappingManualAutomaticAndCancelledRefreshFetchReplacementInOneTrailingPass() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let old = try available(family, title: "test")
        let (_, repository, transport) = try await peer(family, server: server)
        let child = try HouseholdStore(repository: repository, transport: transport,
            clock: { family.clock.now }, automaticSync: true)
        let gate = TestSuspensionGate()
        transport.afterFetch = { transport.afterFetch = nil; await gate.wait() }
        let before = transport.fetchCalls
        let first = Task { await child.refresh() }
        while !gate.isWaiting { await Task.yield() }
        try family.store.deleteChore(old)
        let replacement = try available(family, title: "test2")
        try await family.store.synchronize()
        child.scheduleSync()
        let cancelled = Task { await child.refresh() }
        let overlap = Task { await child.refresh() }
        await Task.yield()
        cancelled.cancel()
        await cancelled.value
        first.cancel()
        await first.value
        XCTAssertTrue(child.isSyncing, "Caller cancellation must leave shared work running")
        XCTAssertNil(child.errorMessage)
        gate.resume()
        await overlap.value
        XCTAssertEqual(transport.fetchCalls, before + 2, "All arrivals coalesce into one trailing fetch")
        XCTAssertNil(child.errorMessage)
        XCTAssertFalse(child.isSyncing)
        XCTAssertFalse(child.dailyList().contains { $0.choreID == old && $0.isActionableOccurrence })
        XCTAssertTrue(child.dailyList().contains { $0.choreID == replacement && $0.isActionableOccurrence })
        XCTAssertEqual(child.snapshot, family.store.snapshot)
        let reopened = try HouseholdStore(repository: repository, transport: transport,
            clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.snapshot, child.snapshot)
        XCTAssertEqual(reopened.dailyList(), child.dailyList())
    }

    func testTransportCancellationWithoutCancelledCallerIsVisibleAndRetryAfterRelaunchConverges() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let old = try available(family, title: "test")
        let (child, repository, transport) = try await peer(family, server: server)
        try family.store.deleteChore(old)
        let replacement = try available(family, title: "test2")
        try await family.store.synchronize()
        transport.fetchError = CancellationError()
        let lastSuccess = child.lastSyncedAt
        await child.refresh()
        XCTAssertEqual(child.lastSyncedAt, lastSuccess)
        XCTAssertEqual(child.errorMessage, "Update interrupted. Your changes are kept. Pull to refresh to try again.")
        XCTAssertTrue(child.dailyList().contains { $0.choreID == old && $0.isActionableOccurrence })
        XCTAssertFalse(child.cloudAccessBlocked)
        transport.fetchError = nil
        let reopened = try HouseholdStore(repository: repository, transport: transport,
            clock: { family.clock.now }, automaticSync: false)
        await reopened.refresh()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.snapshot, family.store.snapshot)
        XCTAssertFalse(reopened.dailyList().contains { $0.choreID == old && $0.isActionableOccurrence })
        XCTAssertTrue(reopened.dailyList().contains { $0.choreID == replacement && $0.isActionableOccurrence })
    }

    func testPartialCancelledUploadRetainsPendingFactsAndRelaunchRetryIsIdempotent() async throws {
        let server = TestCloudServer()
        let ownerTransport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: ownerTransport)
        let old = try available(family, title: "test")
        let (child, _, _) = try await peer(family, server: server)
        try family.store.deleteChore(old)
        let replacement = try available(family, title: "test2")
        let pending = family.store.pendingCount
        server.failUploadAfter = 1
        server.uploadFailure = CancellationError()
        await family.store.refresh()
        XCTAssertEqual(family.store.pendingCount, pending)
        XCTAssertNotNil(family.store.errorMessage)
        server.failUploadAfter = nil
        let reopened = try HouseholdStore(repository: family.repository, transport: ownerTransport,
            clock: { family.clock.now }, automaticSync: false)
        try await reopened.synchronize()
        try await child.synchronize()
        try await reopened.synchronize()
        XCTAssertEqual(reopened.pendingCount, 0)
        XCTAssertEqual(child.snapshot, reopened.snapshot)
        XCTAssertEqual(child.dailyList(), reopened.dailyList())
        XCTAssertFalse(child.dailyList().contains { $0.choreID == old && $0.isActionableOccurrence })
        XCTAssertTrue(child.dailyList().contains { $0.choreID == replacement && $0.isActionableOccurrence })
        XCTAssertEqual(server.zones[try XCTUnwrap(reopened.session.location).zoneName]?.facts.count,
                       reopened.snapshot.orderedFacts.count)
    }

    func testQueuedRefreshRecoversInterruptedFetchAndRealNetworkFailureStillPresents() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        try await family.store.connect()
        let gate = TestSuspensionGate()
        transport.beforeFetch = {
            transport.beforeFetch = nil
            await gate.wait()
            transport.fetchError = CancellationError()
        }
        transport.afterFetch = nil
        let first = Task { await family.store.refresh() }
        while !gate.isWaiting { await Task.yield() }
        // The first failed fetch consumes this error; the next participant lookup clears it.
        transport.beforeParticipantIDReturn = { transport.fetchError = nil }
        let second = Task { await family.store.refresh() }
        await Task.yield()
        gate.resume()
        await first.value
        await second.value
        XCTAssertNil(family.store.errorMessage)
        XCTAssertEqual(family.store.syncMessage, "Up to date")
        transport.beforeParticipantIDReturn = nil
        transport.fetchError = CKError(.networkUnavailable)
        await family.store.refresh()
        XCTAssertNotNil(family.store.errorMessage)
        XCTAssertEqual(family.store.syncMessage, "Sync needs attention. Changes are kept.")
    }
}

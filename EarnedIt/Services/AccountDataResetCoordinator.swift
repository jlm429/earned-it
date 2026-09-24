import Foundation

struct CloudResetZone: Codable, Hashable {
    let zoneName: String
    let ownerName: String
}

enum CloudAccountResetTarget: Codable, Hashable {
    case ownedZone(CloudResetZone)
    case sharedParticipation(CloudResetZone)
    case publicRecord(recordType: String, recordName: String)
    case privateRecord(recordType: String, recordName: String)

    var stableDescription: String {
        switch self {
        case .ownedZone(let zone):
            "owned-zone:\(zone.ownerName)/\(zone.zoneName)"
        case .sharedParticipation(let zone):
            "shared-participation:\(zone.ownerName)/\(zone.zoneName)"
        case .publicRecord(let recordType, let recordName):
            "public-record:\(recordType)/\(recordName)"
        case .privateRecord(let recordType, let recordName):
            "private-record:\(recordType)/\(recordName)"
        }
    }

    private var deletionOrder: Int {
        switch self {
        case .ownedZone: 0
        case .sharedParticipation: 1
        case .publicRecord: 2
        case .privateRecord: 3
        }
    }

    static func ordered(_ targets: some Sequence<Self>) -> [Self] {
        Set(targets).sorted {
            if $0.deletionOrder != $1.deletionOrder { return $0.deletionOrder < $1.deletionOrder }
            return $0.stableDescription < $1.stableDescription
        }
    }
}

struct AccountDataResetProgress: Codable, Equatable {
    let expectedParticipantID: String
    var remainingTargets: [CloudAccountResetTarget]?
    var completedDiscoveryPasses: Int

    init(expectedParticipantID: String) {
        self.expectedParticipantID = expectedParticipantID
        remainingTargets = nil
        completedDiscoveryPasses = 0
    }
}

protocol AccountLocalDataResetting {
    func clearNonJournalData() throws
    func clearActiveStoreArtifacts() throws
}

struct NoOpAccountLocalDataResetter: AccountLocalDataResetting {
    func clearNonJournalData() throws {}
    func clearActiveStoreArtifacts() throws {}
}

struct AppAccountLocalDataResetter: AccountLocalDataResetting {
    let applicationSupportDirectory: URL
    let documentsDirectory: URL
    let cachesDirectory: URL
    let bundleIdentifier: String?
    let userDefaults: UserDefaults
    let fileManager: FileManager
    let activeStoreURL: URL

    init(
        applicationSupportDirectory: URL = .applicationSupportDirectory,
        documentsDirectory: URL = .documentsDirectory,
        cachesDirectory: URL = .cachesDirectory,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        activeStoreURL: URL? = nil
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.documentsDirectory = documentsDirectory
        self.cachesDirectory = cachesDirectory
        self.bundleIdentifier = bundleIdentifier
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.activeStoreURL = activeStoreURL
            ?? applicationSupportDirectory.appending(path: "shared-household-v1.store")
    }

    func clearNonJournalData() throws {
        let obsoleteStores = [
            applicationSupportDirectory.appending(path: "default.store"),
            documentsDirectory.appending(path: "isolated-ui-tests.store"),
            documentsDirectory.appending(path: "shared-household-ui-tests.store")
        ]
        for store in obsoleteStores where store.standardizedFileURL != activeStoreURL.standardizedFileURL {
            for artifact in Self.storeArtifacts(for: store) where fileManager.fileExists(atPath: artifact.path) {
                try fileManager.removeItem(at: artifact)
            }
        }
        if fileManager.fileExists(atPath: cachesDirectory.path) {
            for item in try fileManager.contentsOfDirectory(
                at: cachesDirectory,
                includingPropertiesForKeys: nil
            ) {
                try fileManager.removeItem(at: item)
            }
        }
        if let bundleIdentifier {
            userDefaults.removePersistentDomain(forName: bundleIdentifier)
        }
    }

    func clearActiveStoreArtifacts() throws {
        for artifact in Self.storeArtifacts(for: activeStoreURL)
            where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }
    }

    private static func storeArtifacts(for store: URL) -> [URL] {
        [
            store,
            URL(fileURLWithPath: store.path + "-shm"),
            URL(fileURLWithPath: store.path + "-wal"),
            URL(fileURLWithPath: store.path + "_SUPPORT", isDirectory: true)
        ]
    }
}

@MainActor
final class AccountDataResetCoordinator {
    private static let maximumVerificationPasses = 4
    private let repository: HouseholdRepository
    private let transport: any AccountDataResetCloudBoundary
    private let localDataResetter: any AccountLocalDataResetting

    init(
        repository: HouseholdRepository,
        transport: any AccountDataResetCloudBoundary,
        localDataResetter: any AccountLocalDataResetting
    ) {
        self.repository = repository
        self.transport = transport
        self.localDataResetter = localDataResetter
    }

    func run(progressDidPersist: (DeviceSession) -> Void) async throws {
        var session = try repository.session()
        var progress: AccountDataResetProgress
        if let pending = session.accountDataResetProgress {
            progress = pending
        } else {
            let generation = transport.accountGeneration
            let participant = try await transport.participantID()
            guard transport.accountGeneration == generation else { throw HouseholdError.wrongAccount }
            progress = AccountDataResetProgress(expectedParticipantID: participant)
            session.accountDataResetProgress = progress
            try repository.commit(facts: [], session: session)
        }
        progressDidPersist(session)

        let generation = transport.accountGeneration
        try await requireExpectedAccount(progress.expectedParticipantID, generation: generation)

        while true {
            if progress.remainingTargets == nil {
                let discovered = try await transport.accountDataResetTargets(
                    expectedParticipantID: progress.expectedParticipantID,
                    expectedAccountGeneration: generation
                )
                progress.remainingTargets = CloudAccountResetTarget.ordered(discovered)
                progressDidPersist(try persist(progress))
            }

            while let target = progress.remainingTargets?.first {
                try await transport.deleteAccountDataResetTarget(
                    target,
                    expectedParticipantID: progress.expectedParticipantID,
                    expectedAccountGeneration: generation
                )
                progress.remainingTargets?.removeFirst()
                progressDidPersist(try persist(progress))
            }

            progress.completedDiscoveryPasses += 1
            progress.remainingTargets = nil
            progressDidPersist(try persist(progress))
            let remaining = try await transport.accountDataResetTargets(
                expectedParticipantID: progress.expectedParticipantID,
                expectedAccountGeneration: generation
            )
            guard !remaining.isEmpty else { break }
            progress.remainingTargets = CloudAccountResetTarget.ordered(remaining)
            progressDidPersist(try persist(progress))
            guard progress.completedDiscoveryPasses < Self.maximumVerificationPasses else {
                throw HouseholdError.cloudUnavailable
            }
        }

        try await requireExpectedAccount(progress.expectedParticipantID, generation: generation)
        try localDataResetter.clearNonJournalData()
        try repository.completeAccountDataReset {
            try localDataResetter.clearActiveStoreArtifacts()
        }
    }

    private func persist(_ progress: AccountDataResetProgress) throws -> DeviceSession {
        var session = try repository.session()
        guard let current = session.accountDataResetProgress,
              current.expectedParticipantID == progress.expectedParticipantID else {
            throw HouseholdError.accountMembershipConflict
        }
        session.accountDataResetProgress = progress
        try repository.commit(facts: [], session: session)
        return session
    }

    private func requireExpectedAccount(_ participantID: String, generation: UInt64) async throws {
        try Task.checkCancellation()
        guard transport.accountGeneration == generation,
              try await transport.participantID() == participantID,
              transport.accountGeneration == generation else { throw HouseholdError.wrongAccount }
        try Task.checkCancellation()
    }
}

#if DEBUG
@MainActor
final class UITestAccountDataResetCloudBoundary: AccountDataResetCloudBoundary {
    let accountGeneration: UInt64 = 0

    func participantID() async throws -> String { "ui-test-account" }

    func accountDataResetTargets(
        expectedParticipantID: String,
        expectedAccountGeneration: UInt64
    ) async throws -> [CloudAccountResetTarget] {
        guard expectedParticipantID == "ui-test-account", expectedAccountGeneration == 0 else {
            throw HouseholdError.wrongAccount
        }
        return []
    }

    func deleteAccountDataResetTarget(
        _ target: CloudAccountResetTarget,
        expectedParticipantID: String,
        expectedAccountGeneration: UInt64
    ) async throws {
        throw HouseholdError.cloudUnavailable
    }
}
#endif

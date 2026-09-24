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
    func clearActiveStoreAuxiliaryArtifacts() throws
    func clearActiveStoreFile() throws
}

struct NoOpAccountLocalDataResetter: AccountLocalDataResetting {
    func clearNonJournalData() throws {}
    func clearActiveStoreAuxiliaryArtifacts() throws {}
    func clearActiveStoreFile() throws {}
}

struct FileAccountDataResetJournal {
    static let fileName = "account-data-reset-v1.json"

    let url: URL
    let fileManager: FileManager

    init(storeURL: URL, fileManager: FileManager = .default) {
        url = storeURL.deletingLastPathComponent().appending(path: Self.fileName)
        self.fileManager = fileManager
    }

    func progress() throws -> AccountDataResetProgress? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AccountDataResetProgress.self, from: Data(contentsOf: url))
    }

    func persist(_ progress: AccountDataResetProgress) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(progress).write(to: url, options: .atomic)
    }

    func clear() throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
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

    func clearActiveStoreAuxiliaryArtifacts() throws {
        for artifact in Self.storeArtifacts(for: activeStoreURL).dropFirst()
            where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }
    }

    func clearActiveStoreFile() throws {
        if fileManager.fileExists(atPath: activeStoreURL.path) {
            try fileManager.removeItem(at: activeStoreURL)
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
protocol AccountDataResetLocalBoundary {
    func accountDataResetProgress() throws -> AccountDataResetProgress?
    func persistAccountDataResetProgress(_ progress: AccountDataResetProgress) throws
    func completeAccountDataReset() throws
}

@MainActor
final class RepositoryAccountDataResetLocalBoundary: AccountDataResetLocalBoundary {
    private let repository: HouseholdRepository
    private let localDataResetter: any AccountLocalDataResetting
    private let journal: FileAccountDataResetJournal?

    init(
        repository: HouseholdRepository,
        localDataResetter: any AccountLocalDataResetting,
        journal: FileAccountDataResetJournal?
    ) {
        self.repository = repository
        self.localDataResetter = localDataResetter
        self.journal = journal
    }

    func accountDataResetProgress() throws -> AccountDataResetProgress? {
        var session = try repository.session()
        if let durable = try journal?.progress() {
            if let stored = session.accountDataResetProgress,
               stored.expectedParticipantID != durable.expectedParticipantID {
                throw HouseholdError.accountMembershipConflict
            }
            if session.accountDataResetProgress != durable {
                session.accountDataResetProgress = durable
                try repository.commit(facts: [], session: session)
            }
            return durable
        }
        if let stored = session.accountDataResetProgress {
            try journal?.persist(stored)
            return stored
        }
        return nil
    }

    func persistAccountDataResetProgress(_ progress: AccountDataResetProgress) throws {
        var session = try repository.session()
        if let stored = session.accountDataResetProgress,
           stored.expectedParticipantID != progress.expectedParticipantID {
            throw HouseholdError.accountMembershipConflict
        }
        if let durable = try journal?.progress(),
           durable.expectedParticipantID != progress.expectedParticipantID {
            throw HouseholdError.accountMembershipConflict
        }
        try journal?.persist(progress)
        session.accountDataResetProgress = progress
        do {
            try repository.commit(facts: [], session: session)
        } catch {
            guard journal != nil else { throw error }
        }
    }

    func completeAccountDataReset() throws {
        try localDataResetter.clearNonJournalData()
        try repository.completeAccountDataReset(
            removingPersistentStoreAuxiliaryArtifacts: {
                try localDataResetter.clearActiveStoreAuxiliaryArtifacts()
            },
            removingPersistentStoreFile: {
                try localDataResetter.clearActiveStoreFile()
            }
        )
        try journal?.clear()
    }
}

@MainActor
final class StartupFailureAccountDataResetLocalBoundary: AccountDataResetLocalBoundary {
    private let localDataResetter: any AccountLocalDataResetting
    private let journal: FileAccountDataResetJournal

    init(
        localDataResetter: any AccountLocalDataResetting,
        journal: FileAccountDataResetJournal
    ) {
        self.localDataResetter = localDataResetter
        self.journal = journal
    }

    func accountDataResetProgress() throws -> AccountDataResetProgress? {
        try journal.progress()
    }

    func persistAccountDataResetProgress(_ progress: AccountDataResetProgress) throws {
        if let durable = try journal.progress(),
           durable.expectedParticipantID != progress.expectedParticipantID {
            throw HouseholdError.accountMembershipConflict
        }
        try journal.persist(progress)
    }

    func completeAccountDataReset() throws {
        try localDataResetter.clearNonJournalData()
        try localDataResetter.clearActiveStoreAuxiliaryArtifacts()
        try localDataResetter.clearActiveStoreFile()
        try journal.clear()
    }
}

@MainActor
final class AccountDataResetCoordinator {
    private static let maximumVerificationPasses = 4
    private let transport: any AccountDataResetCloudBoundary
    private let localBoundary: any AccountDataResetLocalBoundary

    init(
        repository: HouseholdRepository,
        transport: any AccountDataResetCloudBoundary,
        localDataResetter: any AccountLocalDataResetting,
        journal: FileAccountDataResetJournal? = nil
    ) {
        self.transport = transport
        localBoundary = RepositoryAccountDataResetLocalBoundary(
            repository: repository,
            localDataResetter: localDataResetter,
            journal: journal
        )
    }

    init(
        transport: any AccountDataResetCloudBoundary,
        localBoundary: any AccountDataResetLocalBoundary
    ) {
        self.transport = transport
        self.localBoundary = localBoundary
    }

    func restoredProgress() throws -> AccountDataResetProgress? {
        try localBoundary.accountDataResetProgress()
    }

    func accountDidChange() {
        transport.accountDidChange()
    }

    func run(progressDidPersist: (AccountDataResetProgress?) -> Void) async throws {
        var progress: AccountDataResetProgress
        if let pending = try localBoundary.accountDataResetProgress() {
            progress = pending
            progressDidPersist(progress)
        } else {
            let generation = transport.accountGeneration
            let participant = try await transport.participantID()
            guard transport.accountGeneration == generation else { throw HouseholdError.wrongAccount }
            progress = AccountDataResetProgress(expectedParticipantID: participant)
            try persist(progress, progressDidPersist: progressDidPersist)
        }

        let generation = transport.accountGeneration
        try await requireExpectedAccount(progress.expectedParticipantID, generation: generation)

        while true {
            if progress.remainingTargets == nil {
                let discovered = try await transport.accountDataResetTargets(
                    expectedParticipantID: progress.expectedParticipantID,
                    expectedAccountGeneration: generation
                )
                progress.remainingTargets = CloudAccountResetTarget.ordered(discovered)
                try persist(progress, progressDidPersist: progressDidPersist)
            }

            while let target = progress.remainingTargets?.first {
                try await transport.deleteAccountDataResetTarget(
                    target,
                    expectedParticipantID: progress.expectedParticipantID,
                    expectedAccountGeneration: generation
                )
                progress.remainingTargets?.removeFirst()
                try persist(progress, progressDidPersist: progressDidPersist)
            }

            progress.completedDiscoveryPasses += 1
            progress.remainingTargets = nil
            try persist(progress, progressDidPersist: progressDidPersist)
            let remaining = try await transport.accountDataResetTargets(
                expectedParticipantID: progress.expectedParticipantID,
                expectedAccountGeneration: generation
            )
            guard !remaining.isEmpty else { break }
            progress.remainingTargets = CloudAccountResetTarget.ordered(remaining)
            try persist(progress, progressDidPersist: progressDidPersist)
            guard progress.completedDiscoveryPasses < Self.maximumVerificationPasses else {
                throw HouseholdError.cloudUnavailable
            }
        }

        try await requireExpectedAccount(progress.expectedParticipantID, generation: generation)
        try localBoundary.completeAccountDataReset()
        progressDidPersist(nil)
    }

    private func persist(
        _ progress: AccountDataResetProgress,
        progressDidPersist: (AccountDataResetProgress?) -> Void
    ) throws {
        try localBoundary.persistAccountDataResetProgress(progress)
        progressDidPersist(progress)
    }

    private func requireExpectedAccount(_ participantID: String, generation: UInt64) async throws {
        try await transport.requireAccountForReset(participantID, generation: generation)
    }
}

#if DEBUG
@MainActor
final class UITestAccountDataResetCloudBoundary: AccountDataResetCloudBoundary {
    private(set) var accountGeneration: UInt64 = 0

    func accountDidChange() { accountGeneration &+= 1 }

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

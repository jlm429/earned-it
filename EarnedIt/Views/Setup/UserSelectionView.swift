import SwiftData
import SwiftUI

struct UserSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FamilyUser.createdAt) private var users: [FamilyUser]
    @Query private var settings: [AppSetting]

    @State private var confirmation: DevelopmentAction?
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    private var displayUsers: [FamilyUser] {
        users.sorted {
            if $0.role != $1.role { return $0.role == .parent }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("Who’s using Earned It?")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                        Text("Allowance Tracker")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(displayUsers) { user in
                            Button {
                                select(user)
                            } label: {
                                VStack(spacing: 10) {
                                    AvatarView(user: user, size: 72)
                                    Text(user.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.center)
                                    Text(user.role.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, minHeight: 154)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Continue as \(user.displayName), \(user.role.title)")
                            .accessibilityIdentifier("user-card-\(user.displayName.accessibilitySlug)")
                        }
                    }

                    DevelopmentDataView(
                        isSampleMode: SettingsStore.value(for: SettingsStore.dataModeKey, in: settings) == "sample",
                        onLoad: { confirmation = .loadSample },
                        onReset: { confirmation = .resetSample },
                        onClear: { confirmation = .clearAll }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarHidden(true)
            .confirmationDialog(
                confirmation?.title ?? "Development Data",
                isPresented: Binding(
                    get: { confirmation != nil },
                    set: { if !$0 { confirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let confirmation {
                    Button(confirmation.buttonTitle, role: .destructive) {
                        perform(confirmation)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                Text("This replaces all local family and responsibility data on this Simulator.")
            }
            .alert("Unable to Update Data", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }

    private func select(_ user: FamilyUser) {
        do {
            try DataCoordinator.prepareDailyData(context: modelContext)
            try SettingsStore.set(user.id.uuidString, for: SettingsStore.selectedUserIDKey, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ action: DevelopmentAction) {
        do {
            switch action {
            case .loadSample, .resetSample:
                try SampleDataService.seed(context: modelContext)
            case .clearAll:
                try SampleDataService.clearAll(context: modelContext)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        confirmation = nil
    }
}

private enum DevelopmentAction {
    case loadSample
    case resetSample
    case clearAll

    var title: String {
        switch self {
        case .loadSample: "Load Generic Sample Data?"
        case .resetSample: "Reset Generic Sample Data?"
        case .clearAll: "Clear All Local Data?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .loadSample: "Load Sample Data"
        case .resetSample: "Reset Sample Data"
        case .clearAll: "Clear All Data"
        }
    }
}

private struct DevelopmentDataView: View {
    let isSampleMode: Bool
    let onLoad: () -> Void
    let onReset: () -> Void
    let onClear: () -> Void

    var body: some View {
        DisclosureGroup("Development Data") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generic data for Simulator review. Never mixed into a normal family automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Load Generic Sample Data", action: onLoad)
                    .accessibilityIdentifier("load-sample-data")
                if isSampleMode {
                    Button("Reset Generic Sample Data", action: onReset)
                        .accessibilityIdentifier("reset-sample-data")
                }
                Button("Clear All Local Data", role: .destructive, action: onClear)
                    .accessibilityIdentifier("clear-all-data")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

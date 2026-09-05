import SwiftData
import SwiftUI

struct HouseholdSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSetting]
    @State private var confirmingReset = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Family Setup") {
                if OnboardingService.disposition(in: settings) == .skipped {
                    Button("Resume Setup") { restart(resuming: true) }
                        .accessibilityIdentifier("resume-setup")
                }
                Button("Restart Setup") { restart(resuming: false) }
                    .accessibilityIdentifier("restart-setup")
                Text("Setup keeps all saved family members, chores, and history. You can review the guide or add people and chores.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Local Data") {
                Text("Your family data stays on this device. Switch to a parent to manage family members and responsibilities.")
                Button("Delete All Local Data", role: .destructive) { confirmingReset = true }
                    .accessibilityIdentifier("clear-all-data")
            }
        }
        .navigationTitle("Settings")
        .alert("Delete all local data?", isPresented: $confirmingReset) {
            Button("Delete All Data", role: .destructive) {
                perform { try OnboardingService.clearAll(context: modelContext) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently delete all family members, chores, and history on this device? This cannot be undone.")
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

    private func restart(resuming: Bool) {
        perform { try OnboardingService.restart(resuming: resuming, context: modelContext) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

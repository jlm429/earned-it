import SwiftUI

struct BonusAllowanceEditor: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let child: FamilyMember
    @State private var awardID = UUID()
    @State private var amount = ""
    @State private var note = ""
    @State private var currencyCode = Locale.autoupdatingCurrent.currency?.identifier ?? "USD"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("A bonus for \(child.displayName)", systemImage: "gift.fill").font(.headline)
                    Text("Recognize an extra effort. This bonus adds to this week only.")
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Section("Bonus amount") {
                    TextField("Amount", text: $amount).keyboardType(.decimalPad)
                        .accessibilityIdentifier("bonus-amount")
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(Locale.commonISOCurrencyCodes, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Reason for bonus (optional)", text: $note, axis: .vertical)
                        .accessibilityIdentifier("bonus-note")
                }
                Section {
                    Text("Saving records an award in family history. Earned It does not move money or record a payment.")
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .themedListBackground()
            .navigationTitle("Award a Bonus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Award") {
                        do {
                            try store.awardBonus(memberID: child.id, text: amount, currencyCode: currencyCode,
                                                 note: note, awardID: awardID)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 120)
                    .accessibilityIdentifier("save-bonus")
                }
            }
            .onAppear { currencyCode = store.allowanceWeek(for: child.id).amount?.currencyCode ?? currencyCode }
            .alert("Unable to Award Bonus", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
        }
    }
}

struct BonusHistoryView: View {
    @Environment(HouseholdStore.self) private var store
    let memberID: UUID
    var week: AllowanceWeek? = nil

    private var awards: [RecordedBonus] {
        store.bonusHistory(for: memberID).filter {
            guard let week else { return true }
            return week.start <= $0.award.day && $0.award.day <= week.end
        }
    }

    var body: some View {
        if !awards.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Bonus awards", systemImage: "gift.fill").font(.headline).foregroundStyle(AppTheme.accent)
                ForEach(awards) { recorded in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(recorded.award.amount.formatted()) \(recorded.award.amount.currencyCode) · \(AppCalendar.displayDay(recorded.award.day, calendar: store.calendar))")
                            .font(.subheadline.weight(.semibold))
                        if !recorded.award.note.isEmpty { Text(recorded.award.note).font(.subheadline) }
                        Text("Awarded by \(store.snapshot.member(recorded.award.recordedByMemberID)?.displayName ?? "a parent")")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Bonuses apply only to the week awarded. No payments are recorded.")
                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bonus-history")
        }
    }
}

struct WeeklyBonusNote: View {
    let week: AllowanceWeek

    var body: some View {
        ForEach(week.bonuses, id: \.currencyCode) { bonus in
            Text("+\(bonus.formatted()) bonus \(week.isFinished ? "that week" : "this week")")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("weekly-bonus-\(bonus.currencyCode)")
        }
    }
}

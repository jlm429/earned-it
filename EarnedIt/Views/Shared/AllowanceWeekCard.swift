import SwiftUI

struct WeekHeading: View {
    @Environment(HouseholdStore.self) private var store
    let week: AllowanceWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(week.isFinished ? "Finished week" : "Current allowance week")
                .font(.caption.weight(.semibold)).foregroundStyle(.primary.opacity(0.7))
            Text("Week of \(label(week.start))").font(.headline)
            Text("\(label(week.start)) – \(label(week.end))")
                .font(.subheadline).foregroundStyle(.primary.opacity(0.7))
        }
    }

    private func label(_ day: CivilDay) -> String {
        let formatter = DateFormatter()
        formatter.calendar = store.calendar
        formatter.timeZone = store.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return formatter.string(from: day.date(in: store.calendar))
    }
}

struct AllowanceWeekCard: View {
    let week: AllowanceWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WeekHeading(week: week)
            Text(week.amount.map { "\($0.formatted()) weekly allowance" } ?? "Allowance amount not set")
                .font(.subheadline.weight(.medium))
            if week.earned {
                Label { Text("Earned It").foregroundStyle(.primary) } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                    .font(.title2.bold())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Earned It. Every required item accounted for.")
                    .accessibilityIdentifier("earned-it-badge")
                Text("Every required item accounted for. Allowance eligible.").font(.subheadline)
            } else if week.items.isEmpty {
                Label("No required items", systemImage: "minus.circle")
                Text("No allowance earned for a week without required items.")
                    .font(.footnote).foregroundStyle(.primary.opacity(0.7))
            } else {
                StatusBadge(status: week.status)
                if week.isFinished { Text("Allowance not yet earned").font(.subheadline.weight(.medium)) }
                Text("\(week.accountedCount) of \(week.dueCount) required items accounted for\(week.isFinished ? "" : " so far")")
                    .accessibilityIdentifier("parent-weekly-count")
                if !week.missing.isEmpty {
                    Label("\(week.missing.count) missing \(week.missing.count == 1 ? "item" : "items")", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                }
            }
            if !week.isFinished {
                Text("\(week.dueToday.count) left today · \(week.scheduled.count) scheduled later")
                    .font(.subheadline).foregroundStyle(.primary.opacity(0.7))
                Text("A fresh week starts every Monday. All required items (100%) must be accounted for after Sunday.")
                    .font(.footnote).foregroundStyle(.primary.opacity(0.7))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct WeeklyItemsView: View {
    @Environment(HouseholdStore.self) private var store
    let week: AllowanceWeek
    let actor: FamilyMember

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            itemGroup("Missing items", items: week.missing)
            itemGroup("Due today", items: week.dueToday)
            itemGroup("Scheduled later", items: week.scheduled)
            if !week.missing.isEmpty {
                Text("You can mark an item on its scheduled day and the following calendar day in the family timezone. After that, only a parent can correct it.")
                    .font(.footnote).foregroundStyle(.primary.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private func itemGroup(_ title: String, items: [WeeklyItem]) -> some View {
        if !items.isEmpty {
            Text(title).font(.headline)
            ForEach(items) { item in
                NavigationLink {
                    DatedChoresView(actor: actor, day: item.day)
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).foregroundStyle(.primary)
                            Text(item.day.date(in: store.calendar), format: .dateTime.weekday().month().day().year())
                                .font(.caption).foregroundStyle(.primary.opacity(0.7))
                        }
                        Spacer(minLength: 8)
                        Image(systemName: item.day > week.today ? "calendar" : "chevron.right").foregroundStyle(Color.accentColor)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("weekly-item-\(item.day)-\(item.title.accessibilitySlug)")
            }
        }
    }
}

struct DatedChoresView: View {
    @Environment(HouseholdStore.self) private var store
    let actor: FamilyMember
    let day: CivilDay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(day.date(in: store.calendar), format: .dateTime.weekday(.wide).month().day().year()).font(.headline)
                if actor.role == .child {
                    Label(day > store.day ? "Scheduled for this date. You can mark these items when the day arrives."
                          : PermissionService.canChildEdit(day: day, today: store.day)
                          ? "You can finish this day’s items until the end of the following calendar day."
                          : "Check in with your parent. Only a parent can correct this day now.",
                          systemImage: "calendar.badge.clock")
                        .font(.subheadline).accessibilityIdentifier("completion-cutoff")
                } else {
                    Text("Corrections update this child’s weekly result, including finished weeks.")
                        .font(.subheadline).foregroundStyle(.primary.opacity(0.7))
                }
                SharedDailyList(actor: actor, date: day.date(in: store.calendar))
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Day’s Items")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AllowanceEditorView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let child: FamilyMember
    @State private var text: String
    @State private var currencyCode: String
    @State private var errorMessage: String?

    init(child: FamilyMember, amount: AllowanceAmount?) {
        self.child = child
        _text = State(initialValue: amount?.inputText() ?? "")
        _currencyCode = State(initialValue: amount?.currencyCode ?? Locale.current.currency?.identifier ?? "USD")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(child.displayName)’s weekly allowance") {
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(Locale.commonISOCurrencyCodes.sorted(), id: \.self) { code in
                            Text("\(code) · \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(code)
                        }
                    }.accessibilityIdentifier("allowance-currency")
                    TextField("Amount (optional)", text: $text)
                        .keyboardType(.decimalPad).accessibilityIdentifier("allowance-amount")
                    Text("Leave blank for not set. Use up to \(AllowanceAmount.fractionDigits(for: currencyCode)) decimal places, without grouping separators.")
                        .font(.footnote).foregroundStyle(.primary.opacity(0.7))
                }
                Section {
                    Text("Changes apply to the current week and future weeks. Finished weeks keep their previous amount.")
                    Text("Earned It tracks allowance eligibility. It does not record payments or transfer money.")
                        .foregroundStyle(.primary.opacity(0.7))
                }
            }
            .navigationTitle("Weekly Allowance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.saveAllowance(memberID: child.id, text: text, currencyCode: currencyCode)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }.accessibilityIdentifier("save-allowance")
                }
            }
            .alert("Unable to Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Please try again.") }
        }
    }
}

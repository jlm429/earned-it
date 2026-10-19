import SwiftUI

struct WeekHeading: View {
    @Environment(HouseholdStore.self) private var store
    let week: AllowanceWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(week.isFinished ? "Finished week" : "Current week")
                .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.secondaryText)
            Text(dateRange)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Week of \(label(week.start)) through \(label(week.end))")
        }
    }

    private var dateRange: String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = store.calendar
        formatter.timeZone = store.calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(
            from: week.start.date(in: store.calendar),
            to: week.end.date(in: store.calendar)
        )
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let week: AllowanceWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WeekHeading(week: week)
            allowanceSummary
            .font(.system(.title, design: .rounded, weight: .bold))
            .foregroundStyle(week.amount == nil ? AppTheme.secondaryText : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            if week.earned {
                Label { Text("Earned It").foregroundStyle(.primary) } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(AppTheme.success)
                }
                    .font(.title2.bold())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Earned It. Every required item accounted for.")
                    .accessibilityIdentifier("earned-it-badge")
            } else if week.items.isEmpty {
                Label("No required items", systemImage: "minus.circle")
            } else {
                StatusBadge(status: week.status)
                if week.isFinished { Text("Allowance not yet earned").font(.subheadline.weight(.medium)) }
                if !week.missing.isEmpty {
                    Label("\(week.missing.count) missing \(week.missing.count == 1 ? "item" : "items")", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.warning)
                }
            }
            if !week.items.isEmpty {
                WeeklyProgressBar(week: week, accessibilityIdentifier: "parent-weekly-count")
            }
            if !week.isFinished {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { timingLabels }
                    VStack(alignment: .leading, spacing: 8) { timingLabels }
                }
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
            }
            if !week.items.isEmpty {
                DisclosureGroup {
                    Text("Weeks run Monday through Sunday. Done and legacy per-child Not Needed count toward the result. Current Not Needed Today occurrences are excluded from both the completed and required totals. Every included required chore must be accounted for to earn the week.")
                        .padding(.top, 4)
                } label: {
                    Label("How weekly progress works", systemImage: "info.circle")
                        .frame(minHeight: 44)
                }
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityIdentifier("weekly-progress-details")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var allowanceSummary: some View {
        let description = week.amount.map { "\($0.formatted()) weekly allowance" } ?? "Allowance not set"
        if dynamicTypeSize.isAccessibilitySize {
            Text(description)
        } else {
            Label(description, systemImage: "banknote")
        }
    }

    @ViewBuilder
    private var timingLabels: some View {
        Label("\(week.dueToday.count) left today", systemImage: "sun.max")
        Label("\(week.scheduled.count) later", systemImage: "calendar")
    }

}

struct WeeklyProgressBar: View {
    let week: AllowanceWeek
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    progressLabel
                    Spacer(minLength: 12)
                    percentageLabel
                }
                progressLabel
            }
            ProgressView(value: Double(week.accountedCount), total: Double(max(week.items.count, 1)))
                .tint(AppTheme.accent)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
                .padding(.vertical, 4)
        }
        .font(.subheadline.weight(.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(week.accountedCount) of \(week.items.count) required items accounted for \(week.isFinished ? "that week" : "this week")")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var progressLabel: some View {
        Text("\(week.accountedCount) of \(week.items.count) \(week.isFinished ? "that week" : "this week")")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var percentageLabel: some View {
        Text(progressPercentage, format: .percent.precision(.fractionLength(0)))
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var progressPercentage: Double {
        guard !week.items.isEmpty else { return 0 }
        return Double(week.accountedCount) / Double(week.items.count)
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
                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
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
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
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
                        .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
                SharedDailyList(actor: actor, date: day.date(in: store.calendar))
            }.padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(AppTheme.canvas)
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
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }
                Section {
                    Text("Changes apply to the current week and future weeks. Finished weeks keep their previous amount.")
                    Text("Earned It tracks allowance eligibility. It does not record payments or transfer money.")
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .themedListBackground()
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

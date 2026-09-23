import SwiftData
import SwiftUI

/// The canonical read-only view for a saved transaction, with a separate
/// editing presentation so imported source data remains safe and visible.
struct TransactionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.name) private var categories: [Category]

    let transaction: Transaction

    @State private var isEditing = false
    @State private var isDeleteConfirmationPresented = false
    @State private var errorMessage: String?

    private var currencyCode: String {
        transaction.account?.currency ?? "AUD"
    }

    private var hasDistinctOriginalBankDescription: Bool {
        guard let originalBankDescription = transaction.originalBankDescription else {
            return false
        }
        return originalBankDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(transaction.merchantDescription.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
    }

    private var showsPostedDate: Bool {
        guard let postedDate = transaction.postedDate else {
            return false
        }
        return !Calendar.current.isDate(postedDate, inSameDayAs: transaction.transactionDate)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                TransactionDetailHero(
                    merchantDescription: transaction.merchantDescription,
                    amount: transaction.amount,
                    transactionDate: transaction.transactionDate,
                    currencyCode: currencyCode,
                    transactionType: transaction.transactionType
                )

                TransactionDetailSection(title: "Details") {
                    Button {
                        isEditing = true
                    } label: {
                        TransactionDetailActionRow(
                            title: "Category",
                            value: transaction.category?.name ?? "Uncategorised",
                            systemImage: transaction.category?.iconName ?? "tag"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Category, \(transaction.category?.name ?? "Uncategorised"). Edit category")

                    if let account = transaction.account {
                        Divider()
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            TransactionDetailActionRow(
                                title: "Account",
                                value: account.name,
                                detail: account.detailDisplayName,
                                systemImage: account.accountType.iconName
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Account, \(account.name), \(account.detailDisplayName)")
                    }
                }

                if let notes = transaction.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TransactionDetailSection(title: "Notes") {
                        Text(notes)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    TransactionDetailSection(title: "Notes") {
                        Button("Add note") {
                            isEditing = true
                        }
                        .buttonStyle(.borderless)
                    }
                }

                TransactionDetailSection(title: "Source details") {
                    if hasDistinctOriginalBankDescription, let originalBankDescription = transaction.originalBankDescription {
                        TransactionDetailValueRow(
                            title: "Original bank description",
                            value: originalBankDescription
                        )
                        Divider()
                    }

                    if showsPostedDate, let postedDate = transaction.postedDate {
                        TransactionDetailValueRow(
                            title: "Posted",
                            value: postedDate.formatted(.dateTime.day().month(.abbreviated).year())
                        )
                        Divider()
                    }

                    TransactionDetailValueRow(
                        title: "Source",
                        value: transaction.source.detailTitle
                    )
                    Divider()
                    TransactionDetailValueRow(
                        title: "Type",
                        value: transaction.transactionType.detailTitle
                    )
                }
                .accessibilityElement(children: .combine)

                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Delete transaction", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .padding(.top, 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 20)
        }
        .background {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    isEditing = true
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            TransactionEditView(transaction: transaction, categories: categories)
        }
        .confirmationDialog(
            "Delete transaction?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteTransaction()
            }
        } message: {
            Text("This permanently removes this transaction from Nett.")
        }
        .alert("Couldn’t save transaction", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func deleteTransaction() {
        modelContext.delete(transaction)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TransactionDetailHero: View {
    let merchantDescription: String
    let amount: Decimal
    let transactionDate: Date
    let currencyCode: String
    let transactionType: TransactionType

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(transactionType.detailTitle, systemImage: transactionType.detailIconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(merchantDescription)
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Text(amount, format: .currency(code: currencyCode))
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()

            Text(transactionDate, format: .dateTime.day().month(.wide).year())
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.12), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TransactionDetailSection<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private struct TransactionDetailActionRow: View {
    let title: LocalizedStringResource
    let value: String
    var detail: String? = nil
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TransactionDetailValueRow: View {
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TransactionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let transaction: Transaction
    let categories: [Category]

    @State private var draft: TransactionEditDraft
    @State private var errorMessage: String?

    init(transaction: Transaction, categories: [Category]) {
        self.transaction = transaction
        self.categories = categories
        _draft = State(initialValue: TransactionEditDraft(transaction: transaction))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TransactionDetailSection(title: "Transaction") {
                        TextField("Merchant", text: $draft.merchantDescription)
                            .textInputAutocapitalization(.words)

                        Divider()

                        Picker("Category", selection: $draft.categoryID) {
                            Text("Uncategorised").tag(UUID?.none)
                            ForEach(categories) { category in
                                Label(category.name, systemImage: category.iconName ?? "tag")
                                    .tag(Optional(category.id))
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }

                    TransactionDetailSection(title: "Notes") {
                        TextEditor(text: $draft.notes)
                            .font(.body)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel("Notes")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 20)
            }
            .navigationTitle("Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(draft.merchantDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Couldn’t save transaction", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            try TransactionEditService.save(
                draft,
                to: transaction,
                categories: categories,
                in: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension Account {
    var detailDisplayName: String {
        guard let lastFourDigits, !lastFourDigits.isEmpty else {
            return institutionName
        }
        return "\(institutionName) · •••• \(lastFourDigits)"
    }
}

private extension TransactionSource {
    var detailTitle: String {
        switch self {
        case .manual:
            "Added manually"
        case .csvImport:
            "Imported from CSV"
        case .pdfImport:
            "Imported from PDF statement"
        }
    }
}

private extension TransactionType {
    var detailTitle: String {
        switch self {
        case .expense:
            "Purchase"
        case .income:
            "Income"
        case .transfer:
            "Transfer"
        }
    }

    var detailIconName: String {
        switch self {
        case .expense:
            "arrow.up.circle"
        case .income:
            "arrow.down.circle"
        case .transfer:
            "arrow.left.arrow.right"
        }
    }
}

#Preview {
    let account = Account(
        name: "NAB Rewards Signature",
        accountType: .creditCard,
        institutionName: "NAB",
        lastFourDigits: "6981"
    )
    let category = Category(name: "Pets", iconName: "pawprint")
    let transaction = Transaction(
        transactionDate: .now,
        merchantDescription: "Brisbane Pet Motel",
        originalBankDescription: "MYLACO PTY LTD BOONDALL",
        amount: -190,
        transactionType: .expense,
        category: category,
        account: account,
        notes: "Boarding for the long weekend.",
        source: .csvImport
    )

    NavigationStack {
        TransactionDetailView(transaction: transaction)
    }
    .modelContainer(for: [Account.self, Transaction.self, Category.self, MerchantCategoryRule.self], inMemory: true)
}

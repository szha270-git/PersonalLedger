import SwiftData
import SwiftUI

struct AccountsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var isAddingAccount = false
    @State private var accountToEdit: Account?
    @State private var accountPendingDeletion: Account?

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived }
    }

    private var archivedAccounts: [Account] {
        accounts.filter(\.isArchived)
    }

    var body: some View {
        NavigationStack {
            Group {
                if activeAccounts.isEmpty {
                    ContentUnavailableView(
                        "No accounts yet",
                        systemImage: "building.columns",
                        description: Text("Add an account to start tracking your money locally on this iPhone.")
                    )
                } else {
                    List {
                        Section("Accounts") {
                            ForEach(activeAccounts) { account in
                                NavigationLink {
                                    AccountDetailView(account: account)
                                } label: {
                                    AccountRow(account: account)
                                }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            accountPendingDeletion = account
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }

                                        Button {
                                            account.isArchived = true
                                        } label: {
                                            Label("Archive", systemImage: "archivebox")
                                        }
                                        .tint(.orange)
                                    }
                            }
                            .onDelete(perform: deleteAccounts)
                        }

                        if !archivedAccounts.isEmpty {
                            Section("Archived") {
                                ForEach(archivedAccounts) { account in
                                NavigationLink {
                                    AccountDetailView(account: account)
                                } label: {
                                    AccountRow(account: account)
                                        .foregroundStyle(.secondary)
                                }
                                        .swipeActions {
                                            Button {
                                                account.isArchived = false
                                            } label: {
                                                Label("Restore", systemImage: "arrow.uturn.backward")
                                            }
                                            .tint(.green)
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingAccount = true
                    } label: {
                        Label("Add account", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingAccount) {
                AccountEditorView(account: nil)
            }
            .sheet(item: $accountToEdit) { account in
                AccountEditorView(account: account)
            }
            .confirmationDialog(
                "Delete account?",
                isPresented: Binding(
                    get: { accountPendingDeletion != nil },
                    set: { if !$0 { accountPendingDeletion = nil } }
                ),
                presenting: accountPendingDeletion
            ) { account in
                Button("Delete \(account.name) and its transactions", role: .destructive) {
                    modelContext.delete(account)
                }
            } message: { account in
                Text("This permanently deletes \(account.transactions.count) transaction(s). Archive the account instead if you want to keep its history.")
            }
        }
    }

    private func deleteAccounts(at offsets: IndexSet) {
        for index in offsets {
            accountPendingDeletion = activeAccounts[index]
        }
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.accountType.iconName)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.body.weight(.semibold))

                Text(account.institutionName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(account.accountType == .creditCard ? account.currentCreditCardDebt : account.currentBalance, format: .currency(code: account.currency))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                Text(account.accountType == .creditCard ? "Card debt" : "Current balance")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let lastFourDigits = account.lastFourDigits, !lastFourDigits.isEmpty {
                    Text("•••• \(lastFourDigits)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AccountDetailView: View {
    let account: Account

    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @State private var isEditingAccount = false

    private var accountTransactions: [Transaction] {
        transactions.filter { $0.account?.id == account.id }
    }

    var body: some View {
        List {
            Section("Balance") {
                LabeledContent(
                    account.accountType == .creditCard ? "Card debt" : "Current balance",
                    value: account.accountType == .creditCard ? account.currentCreditCardDebt : account.currentBalance,
                    format: .currency(code: account.currency)
                )
                LabeledContent("Opening balance", value: account.openingBalance, format: .currency(code: account.currency))
            }

            Section("Account") {
                LabeledContent("Institution", value: account.institutionName)
                LabeledContent("Type", value: account.accountType.title)
                if let lastFourDigits = account.lastFourDigits, !lastFourDigits.isEmpty {
                    LabeledContent("Account", value: "•••• \(lastFourDigits)")
                }
            }

            if account.accountType == .creditCard {
                Section("Payment simulator") {
                    CreditCardPaymentSimulator(configuration: paymentSimulatorConfiguration)
                }
            }

            Section("Transactions") {
                if accountTransactions.isEmpty {
                    Text("No imported transactions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(accountTransactions) { transaction in
                        TransactionListRow(transaction: transaction, showsAccount: false)
                    }
                }
            }
        }
        .navigationTitle(account.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    isEditingAccount = true
                }
            }
        }
        .sheet(isPresented: $isEditingAccount) {
            AccountEditorView(account: account)
        }
    }

    private var paymentSimulatorConfiguration: CreditCardPaymentSimulatorConfiguration {
        CreditCardPaymentSimulatorConfiguration(
            currentBalance: account.currentCreditCardDebt,
            statementBalance: account.statementBalance,
            minimumPayment: account.minimumPayment,
            annualPercentageRate: account.creditCardAnnualPercentageRate ?? 0,
            statementClosingDate: account.creditCardStatementClosingDate,
            paymentDueDate: account.creditCardPaymentDueDate,
            interestFreeDays: account.creditCardInterestFreeDays,
            currencyCode: account.currency,
            interestConditions: CreditCardInterestConditions(
                isEligibleForInterestFreePeriod: account.creditCardHasInterestFreePeriod,
                mayHaveAdditionalInterestSources: false
            )
        )
    }
}

private struct AccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: Account?

    @State private var name: String
    @State private var accountType: AccountType
    @State private var institutionName: String
    @State private var lastFourDigits: String
    @State private var openingBalanceText: String
    @State private var currency: String
    @State private var isArchived: Bool
    @State private var statementBalanceText: String
    @State private var minimumPaymentText: String
    @State private var annualPercentageRateText: String
    @State private var statementClosingDate: Date
    @State private var paymentDueDate: Date
    @State private var interestFreeDaysText: String
    @State private var hasInterestFreePeriod: Bool

    init(account: Account?) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _accountType = State(initialValue: account?.accountType ?? .transactionAccount)
        _institutionName = State(initialValue: account?.institutionName ?? "")
        _lastFourDigits = State(initialValue: account?.lastFourDigits ?? "")
        _openingBalanceText = State(initialValue: account?.openingBalance.formatted() ?? "0")
        _currency = State(initialValue: account?.currency ?? "AUD")
        _isArchived = State(initialValue: account?.isArchived ?? false)
        _statementBalanceText = State(initialValue: account?.creditCardStatementBalance?.formatted() ?? "")
        _minimumPaymentText = State(initialValue: account?.creditCardMinimumPayment?.formatted() ?? "")
        _annualPercentageRateText = State(initialValue: account?.creditCardAnnualPercentageRate?.formatted() ?? "")
        _statementClosingDate = State(initialValue: account?.creditCardStatementClosingDate ?? .now)
        _paymentDueDate = State(initialValue: account?.creditCardPaymentDueDate ?? Calendar.current.date(byAdding: .day, value: 21, to: .now) ?? .now)
        _interestFreeDaysText = State(initialValue: account?.creditCardInterestFreeDays.map(String.init) ?? "")
        _hasInterestFreePeriod = State(initialValue: account?.creditCardHasInterestFreePeriod ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account details") {
                    TextField("Name", text: $name)

                    Picker("Type", selection: $accountType) {
                        ForEach(AccountType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }

                    TextField("Institution", text: $institutionName)
                    TextField("Last four digits", text: $lastFourDigits)
                        .keyboardType(.numberPad)
                }

                Section("Starting balance") {
                    TextField("Opening balance", text: $openingBalanceText)
                        .keyboardType(.decimalPad)

                    TextField("Currency code", text: $currency)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                if accountType == .creditCard {
                    Section {
                        TextField("Statement balance", text: $statementBalanceText)
                            .keyboardType(.decimalPad)
                        TextField("Minimum payment", text: $minimumPaymentText)
                            .keyboardType(.decimalPad)
                        TextField("APR (%)", text: $annualPercentageRateText)
                            .keyboardType(.decimalPad)
                        DatePicker("Statement closing date", selection: $statementClosingDate, displayedComponents: .date)
                        DatePicker("Payment due date", selection: $paymentDueDate, displayedComponents: .date)
                        Toggle("Eligible for an interest-free period", isOn: $hasInterestFreePeriod)
                        if hasInterestFreePeriod {
                            TextField("Interest-free days", text: $interestFreeDaysText)
                                .keyboardType(.numberPad)
                        }
                    } header: {
                        Text("Credit card statement")
                    } footer: {
                        Text("The payment simulator is an estimate. Confirm due dates, minimum payment, and interest conditions from your statement.")
                    }
                }

                if account != nil {
                    Section {
                        Toggle("Archive account", isOn: $isArchived)
                    }
                }
            }
            .navigationTitle(account == nil ? "Add account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAccount()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveAccount() {
        let cleanedLastFourDigits = lastFourDigits.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let openingBalance = Decimal(string: openingBalanceText) ?? 0
        let statementBalance = decimal(from: statementBalanceText)
        let minimumPayment = decimal(from: minimumPaymentText)
        let annualPercentageRate = decimal(from: annualPercentageRateText)
        let interestFreeDays = Int(interestFreeDaysText.trimmingCharacters(in: .whitespacesAndNewlines))

        if let account {
            account.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            account.accountType = accountType
            account.institutionName = institutionName.trimmingCharacters(in: .whitespacesAndNewlines)
            account.lastFourDigits = cleanedLastFourDigits.isEmpty ? nil : cleanedLastFourDigits
            account.openingBalance = openingBalance
            account.currency = cleanedCurrency.isEmpty ? "AUD" : cleanedCurrency
            account.isArchived = isArchived
            account.creditCardStatementBalance = accountType == .creditCard ? statementBalance : account.creditCardStatementBalance
            account.creditCardMinimumPayment = accountType == .creditCard ? minimumPayment : account.creditCardMinimumPayment
            account.creditCardAnnualPercentageRate = accountType == .creditCard ? annualPercentageRate : account.creditCardAnnualPercentageRate
            account.creditCardStatementClosingDate = accountType == .creditCard ? statementClosingDate : account.creditCardStatementClosingDate
            account.creditCardPaymentDueDate = accountType == .creditCard ? paymentDueDate : account.creditCardPaymentDueDate
            account.creditCardInterestFreeDays = accountType == .creditCard && hasInterestFreePeriod ? interestFreeDays : nil
            account.creditCardHasInterestFreePeriod = accountType == .creditCard && hasInterestFreePeriod
        } else {
            let newAccount = Account(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                accountType: accountType,
                institutionName: institutionName.trimmingCharacters(in: .whitespacesAndNewlines),
                lastFourDigits: cleanedLastFourDigits.isEmpty ? nil : cleanedLastFourDigits,
                openingBalance: openingBalance,
                currency: cleanedCurrency.isEmpty ? "AUD" : cleanedCurrency,
                creditCardStatementBalance: accountType == .creditCard ? statementBalance : nil,
                creditCardMinimumPayment: accountType == .creditCard ? minimumPayment : nil,
                creditCardAnnualPercentageRate: accountType == .creditCard ? annualPercentageRate : nil,
                creditCardStatementClosingDate: accountType == .creditCard ? statementClosingDate : nil,
                creditCardPaymentDueDate: accountType == .creditCard ? paymentDueDate : nil,
                creditCardInterestFreeDays: accountType == .creditCard && hasInterestFreePeriod ? interestFreeDays : nil,
                creditCardHasInterestFreePeriod: accountType == .creditCard && hasInterestFreePeriod
            )
            modelContext.insert(newAccount)
        }

        dismiss()
    }

    private func decimal(from text: String) -> Decimal? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : Decimal(string: trimmedText)
    }
}

private extension AccountType {
    var iconName: String {
        switch self {
        case .transactionAccount:
            "building.columns"
        case .savings:
            "banknote"
        case .creditCard:
            "creditcard"
        case .cash:
            "banknote.fill"
        case .other:
            "wallet.pass"
        }
    }
}

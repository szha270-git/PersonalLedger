import SwiftData
import SwiftUI

struct HomeView: View {
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived }
    }

    private var monthlyExpenses: [Transaction] {
        let startOfMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
        return transactions.filter {
            $0.transactionDate >= startOfMonth &&
            $0.transactionType == .expense &&
            $0.amount < 0 &&
            $0.account?.currency == displayCurrencyCode
        }
    }

    private var hasSingleCurrency: Bool {
        Set(activeAccounts.map(\.currency)).count <= 1
    }

    private var totalCash: Decimal {
        activeAccounts
            .filter { $0.accountType != .creditCard }
            .reduce(Decimal.zero) { $0 + $1.currentBalance }
    }

    private var totalCreditCardDebt: Decimal {
        activeAccounts
            .filter { $0.accountType == .creditCard }
            .reduce(Decimal.zero) { $0 + $1.currentCreditCardDebt }
    }

    private var netPosition: Decimal {
        activeAccounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }

    private var monthlySpending: Decimal {
        monthlyExpenses.reduce(Decimal.zero) { $0 + (-$1.amount) }
    }

    private var spendingByCategory: [CategorySpending] {
        let totals = Dictionary(grouping: monthlyExpenses) { transaction in
            transaction.category?.name ?? "Uncategorised"
        }

        return totals.map { name, transactions in
            CategorySpending(
                name: name,
                amount: transactions.reduce(Decimal.zero) { $0 + (-$1.amount) }
            )
        }
        .sorted { $0.amount > $1.amount }
        .prefix(4)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            if activeAccounts.isEmpty {
                ContentUnavailableView(
                    "Add an account to get started",
                    systemImage: "chart.pie",
                    description: Text("Your local balances and monthly spending will appear here after you add an account and import a statement.")
                )
                .navigationTitle("Home")
            } else {
                List {
                    if hasSingleCurrency {
                        Section {
                            BalanceSummaryView(
                                totalCash: totalCash,
                                totalCreditCardDebt: totalCreditCardDebt,
                                netPosition: netPosition,
                                currencyCode: displayCurrencyCode
                            )
                        }

                        Section("This month") {
                            LabeledContent("Spent", value: monthlySpending, format: .currency(code: displayCurrencyCode))
                            LabeledContent("Transactions", value: monthlyExpenses.count, format: .number)
                        }

                        if !spendingByCategory.isEmpty {
                            Section("Top spending") {
                                ForEach(spendingByCategory) { spending in
                                    LabeledContent(spending.name, value: spending.amount, format: .currency(code: displayCurrencyCode))
                                }
                            }
                        }
                    } else {
                        Section("Multiple currencies") {
                            Text("Balances and spending are shown per account so currencies are never combined.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Accounts") {
                        ForEach(activeAccounts) { account in
                            NavigationLink {
                                AccountDetailView(account: account)
                            } label: {
                                AccountBalanceRow(account: account)
                            }
                        }
                    }
                }
                .navigationTitle("Home")
            }
        }
    }

    private var displayCurrencyCode: String {
        activeAccounts.first?.currency ?? "AUD"
    }
}

private struct BalanceSummaryView: View {
    let totalCash: Decimal
    let totalCreditCardDebt: Decimal
    let netPosition: Decimal
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Net position")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(netPosition, format: .currency(code: currencyCode))
                .font(.title.bold())
                .monospacedDigit()

            HStack {
                BalanceSummaryValue(title: "Available", amount: totalCash, currencyCode: currencyCode)
                Spacer()
                BalanceSummaryValue(title: "Card debt", amount: totalCreditCardDebt, currencyCode: currencyCode)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BalanceSummaryValue: View {
    let title: String
    let amount: Decimal
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount, format: .currency(code: currencyCode))
                .font(.headline)
                .monospacedDigit()
        }
    }
}

private struct AccountBalanceRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.body.weight(.medium))
                Text(account.institutionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(account.accountType == .creditCard ? account.currentCreditCardDebt : account.currentBalance, format: .currency(code: account.currency))
                    .monospacedDigit()
                Text(account.accountType == .creditCard ? "Card debt" : "Current balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CategorySpending: Identifiable {
    let name: String
    let amount: Decimal

    var id: String { name }
}

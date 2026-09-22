import Charts
import SwiftData
import SwiftUI

struct HomeView: View {
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]

    @State private var isAddingAccount = false

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived }
    }

    // These values deliberately keep the existing Home calculation rules. The
    // dashboard only changes how the results are presented.
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

    private var recentTransactions: [Transaction] {
        let activeAccountIDs = Set(activeAccounts.map(\.id))
        return transactions
            .filter { transaction in
                guard let accountID = transaction.account?.id else { return false }
                return activeAccountIDs.contains(accountID)
            }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if activeAccounts.isEmpty {
                    HomeEmptyState {
                        isAddingAccount = true
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if hasSingleCurrency {
                                HomeBalanceHeroCard(
                                    totalCash: totalCash,
                                    totalCreditCardDebt: totalCreditCardDebt,
                                    netPosition: netPosition,
                                    currencyCode: displayCurrencyCode
                                )

                                MonthlySpendingCard(
                                    spending: monthlySpending,
                                    transactionCount: monthlyExpenses.count,
                                    currencyCode: displayCurrencyCode
                                )

                                if monthlySpending > 0, !spendingByCategory.isEmpty {
                                    SpendingCategoryDonutChart(
                                        spending: spendingByCategory,
                                        totalSpending: monthlySpending,
                                        currencyCode: displayCurrencyCode
                                    )
                                }
                            } else {
                                MultiCurrencyHomeCard()
                            }

                            HomeAccountsSection(accounts: activeAccounts)

                            if !recentTransactions.isEmpty {
                                RecentTransactionsSection(transactions: recentTransactions)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 20)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle("Home")
            .sheet(isPresented: $isAddingAccount) {
                AccountEditorView(account: nil)
            }
        }
    }

    private var displayCurrencyCode: String {
        activeAccounts.first?.currency ?? "AUD"
    }
}

private struct HomeBalanceHeroCard: View {
    let totalCash: Decimal
    let totalCreditCardDebt: Decimal
    let netPosition: Decimal
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("NET POSITION", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(netPosition, format: .currency(code: currencyCode))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)

            HStack(alignment: .top, spacing: 16) {
                HomeBalanceMetric(
                    title: "Available",
                    amount: totalCash,
                    currencyCode: currencyCode,
                    systemImage: "wallet.pass"
                )

                Divider()
                    .frame(height: 42)

                HomeBalanceMetric(
                    title: "Card debt",
                    amount: totalCreditCardDebt,
                    currencyCode: currencyCode,
                    systemImage: "creditcard"
                )
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.22), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Net position")
    }
}

private struct HomeBalanceMetric: View {
    let title: String
    let amount: Decimal
    let currencyCode: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(amount, format: .currency(code: currencyCode))
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonthlySpendingCard: View {
    let spending: Decimal
    let transactionCount: Int
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HomeSectionLabel(title: "This Month", systemImage: "calendar")

            HStack(alignment: .lastTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spent")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(spending, format: .currency(code: currencyCode))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Transactions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(transactionCount, format: .number)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .dashboardCard()
        .accessibilityElement(children: .combine)
    }
}

private struct SpendingCategoryDonutChart: View {
    let spending: [CategorySpending]
    let totalSpending: Decimal
    let currencyCode: String

    private var chartSpending: [DonutCategorySpending] {
        let topCategoryTotal = spending.reduce(Decimal.zero) { $0 + $1.amount }
        let remainingSpending = totalSpending - topCategoryTotal

        var slices = spending.map {
            DonutCategorySpending(
                id: "category-\($0.name)",
                name: $0.name,
                amount: $0.amount
            )
        }

        if remainingSpending > 0 {
            if let otherIndex = slices.firstIndex(where: { $0.name.caseInsensitiveCompare("Other") == .orderedSame }) {
                let existingOther = slices[otherIndex]
                slices[otherIndex] = DonutCategorySpending(
                    id: existingOther.id,
                    name: existingOther.name,
                    amount: existingOther.amount + remainingSpending
                )
            } else {
                slices.append(
                    DonutCategorySpending(
                        id: "other-remainder",
                        name: "Other",
                        amount: remainingSpending
                    )
                )
            }
        }

        return slices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HomeSectionLabel(title: "Top Spending", systemImage: "chart.pie")

            ZStack {
                Chart(chartSpending) { item in
                    SectorMark(
                        angle: .value("Monthly spending", NSDecimalNumber(decimal: item.amount).doubleValue),
                        innerRadius: .ratio(0.62),
                        outerRadius: .inset(8),
                        angularInset: 1
                    )
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("Category", item.name))
                    .accessibilityLabel(item.name)
                    .accessibilityValue(
                        "\(item.amount.formatted(.currency(code: currencyCode))), \(item.percentage(of: totalSpending).formatted(.number.precision(.fractionLength(0)))) percent of this month's spending"
                    )
                }
                .chartLegend(.hidden)
                .accessibilityLabel("Top spending donut chart")

                VStack(spacing: 4) {
                    Text(totalSpending, format: .currency(code: currencyCode))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                    Text("This month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
            .frame(height: 230)

            VStack(spacing: 12) {
                ForEach(chartSpending) { item in
                    SpendingCategoryLegendRow(
                        item: item,
                        totalSpending: totalSpending,
                        currencyCode: currencyCode
                    )
                }
            }
        }
        .dashboardCard()
    }
}

private struct SpendingCategoryLegendRow: View {
    let item: DonutCategorySpending
    let totalSpending: Decimal
    let currencyCode: String

    private var percentage: Decimal {
        item.percentage(of: totalSpending)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            Spacer(minLength: 12)

            Text(item.amount, format: .currency(code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(percentage, format: .number.precision(.fractionLength(0)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)

            Text("%")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.name), \(item.amount.formatted(.currency(code: currencyCode))), \(percentage.formatted(.number.precision(.fractionLength(0)))) percent of this month's spending"
        )
    }
}

private struct MultiCurrencyHomeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionLabel(title: "Multiple Currencies", systemImage: "coloncurrencysign.circle")
            Text("Balances and spending are shown per account so currencies are never combined.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .dashboardCard()
        .accessibilityElement(children: .combine)
    }
}

private struct HomeAccountsSection: View {
    let accounts: [Account]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionLabel(title: "Accounts", systemImage: "building.columns")

            LazyVStack(spacing: 12) {
                ForEach(accounts) { account in
                    NavigationLink {
                        AccountDetailView(account: account)
                    } label: {
                        HomeAccountCard(account: account)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct HomeAccountCard: View {
    let account: Account

    private var amount: Decimal {
        account.accountType == .creditCard ? account.currentCreditCardDebt : account.currentBalance
    }

    private var balanceLabel: String {
        account.accountType == .creditCard ? "Card debt" : "Current balance"
    }

    private var subtitle: String {
        guard let lastFourDigits = account.lastFourDigits, !lastFourDigits.isEmpty else {
            return account.institutionName
        }
        return "\(account.institutionName) · •••• \(lastFourDigits)"
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: account.accountType.homeIconName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(account.accountType.homeTint)
                .frame(width: 44, height: 44)
                .background(account.accountType.homeTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(amount, format: .currency(code: account.currency))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(balanceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .dashboardCard(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

private struct RecentTransactionsSection: View {
    let transactions: [Transaction]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionLabel(title: "Recent Transactions", systemImage: "clock")

            VStack(spacing: 0) {
                ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                    RecentTransactionRow(transaction: transaction)
                    if index < transactions.count - 1 {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
            .dashboardCard(padding: 16)
        }
    }
}

private struct RecentTransactionRow: View {
    let transaction: Transaction

    private var categoryOrTypeLabel: String {
        transaction.category?.name ?? transactionTypeLabel
    }

    private var transactionTypeLabel: String {
        switch transaction.transactionType {
        case .expense:
            "Uncategorised expense"
        case .income:
            "Income"
        case .transfer:
            "Transfer"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.category?.iconName ?? transaction.transactionType.homeIconName)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantDescription)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(categoryOrTypeLabel) · \(transaction.transactionDate, format: .dateTime.month(.abbreviated).day())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                if let currencyCode = transaction.account?.currency {
                    Text(transaction.amount, format: .currency(code: currencyCode))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text(transaction.amount, format: .number.precision(.fractionLength(2)))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct HomeEmptyState: View {
    let addAccount: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("PersonalLedger", systemImage: "chart.pie")
        } description: {
            Text("Your finances, locally. Add an account and import your first statement to start building your dashboard.")
        } actions: {
            Button("Add Account", action: addAccount)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle)
        }
        .padding()
    }
}

private struct HomeSectionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

private struct CategorySpending: Identifiable {
    let name: String
    let amount: Decimal

    var id: String { name }
}

private struct DonutCategorySpending: Identifiable {
    let id: String
    let name: String
    let amount: Decimal

    func percentage(of total: Decimal) -> Decimal {
        guard total > 0 else { return 0 }
        return (amount / total) * 100
    }
}

private extension AccountType {
    var homeIconName: String {
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

    var homeTint: Color {
        switch self {
        case .creditCard:
            .orange
        case .savings:
            .green
        case .cash:
            .purple
        case .transactionAccount, .other:
            .accentColor
        }
    }
}

private extension TransactionType {
    var homeIconName: String {
        switch self {
        case .expense:
            "arrow.up.right"
        case .income:
            "arrow.down.left"
        case .transfer:
            "arrow.left.arrow.right"
        }
    }
}

private extension View {
    func dashboardCard(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

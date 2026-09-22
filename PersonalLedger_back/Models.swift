import Foundation
import SwiftData

enum AccountType: String, CaseIterable, Codable, Identifiable {
    case transactionAccount
    case savings
    case creditCard
    case cash
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transactionAccount:
            "Transaction account"
        case .savings:
            "Savings"
        case .creditCard:
            "Credit card"
        case .cash:
            "Cash"
        case .other:
            "Other"
        }
    }
}

enum TransactionType: String, CaseIterable, Codable, Identifiable {
    case expense
    case income
    case transfer

    var id: String { rawValue }
}

enum TransactionSource: String, CaseIterable, Codable, Identifiable {
    case manual
    case csvImport
    case pdfImport

    var id: String { rawValue }
}

@Model
final class Account: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    private var accountTypeValue: String
    var institutionName: String
    /// The financial product named on a statement, such as "Platinum Card".
    var productName: String?
    var accountHolderName: String?
    var maskedAccountNumber: String?
    var lastFourDigits: String?
    /// A BSB, routing number, or comparable institution-specific identifier.
    var routingIdentifier: String?
    var openingBalance: Decimal
    var currency: String
    var createdDate: Date
    var isArchived: Bool

    /// Statement metadata is optional: it is only stored when a statement explicitly provides it.
    /// `openingBalance` remains the ledger's starting point, while this value preserves the
    /// opening balance reported on the most recently reviewed statement.
    var statementOpeningBalance: Decimal?
    var statementStartDate: Date?
    var statementEndDate: Date?
    var statementClosingBalance: Decimal?

    /// Credit-card statement settings are optional because non-card accounts don't use them.
    var creditCardStatementBalance: Decimal?
    var creditCardMinimumPayment: Decimal?
    /// The purchase interest rate / APR, when it is stated by the institution.
    var creditCardAnnualPercentageRate: Decimal?
    var creditCardStatementClosingDate: Date?
    var creditCardPaymentDueDate: Date?
    var creditCardInterestFreeDays: Int?
    var creditCardHasInterestFreePeriod: Bool
    var creditCardCreditLimit: Decimal?
    var creditCardAvailableCredit: Decimal?
    /// The interest rate charged to cash advances, when it is stated by the institution.
    var creditCardCashAdvanceInterestRate: Decimal?
    var creditCardBalanceTransferInterestRate: Decimal?
    var creditCardAnnualFee: Decimal?

    @Relationship(deleteRule: .cascade, inverse: \Transaction.account)
    var transactions: [Transaction] = []

    var accountType: AccountType {
        get { AccountType(rawValue: accountTypeValue) ?? .other }
        set { accountTypeValue = newValue.rawValue }
    }

    /// The live balance is derived locally from the opening balance and every saved transaction.
    var currentBalance: Decimal {
        openingBalance + transactions.reduce(Decimal.zero) { partialResult, transaction in
            partialResult + transaction.amount
        }
    }

    /// Credit-card debt is displayed as a positive amount even though card purchases reduce the balance.
    var currentCreditCardDebt: Decimal {
        currentBalance < 0 ? -currentBalance : 0
    }

    var statementBalance: Decimal {
        creditCardStatementBalance ?? currentCreditCardDebt
    }

    var minimumPayment: Decimal {
        guard let creditCardMinimumPayment else {
            return 0
        }
        return creditCardMinimumPayment > statementBalance ? statementBalance : creditCardMinimumPayment
    }

    init(
        id: UUID = UUID(),
        name: String,
        accountType: AccountType,
        institutionName: String,
        productName: String? = nil,
        accountHolderName: String? = nil,
        maskedAccountNumber: String? = nil,
        lastFourDigits: String? = nil,
        routingIdentifier: String? = nil,
        openingBalance: Decimal = 0,
        currency: String = "AUD",
        createdDate: Date = .now,
        isArchived: Bool = false,
        statementOpeningBalance: Decimal? = nil,
        statementStartDate: Date? = nil,
        statementEndDate: Date? = nil,
        statementClosingBalance: Decimal? = nil,
        creditCardStatementBalance: Decimal? = nil,
        creditCardMinimumPayment: Decimal? = nil,
        creditCardAnnualPercentageRate: Decimal? = nil,
        creditCardStatementClosingDate: Date? = nil,
        creditCardPaymentDueDate: Date? = nil,
        creditCardInterestFreeDays: Int? = nil,
        creditCardHasInterestFreePeriod: Bool = false,
        creditCardCreditLimit: Decimal? = nil,
        creditCardAvailableCredit: Decimal? = nil,
        creditCardCashAdvanceInterestRate: Decimal? = nil,
        creditCardBalanceTransferInterestRate: Decimal? = nil,
        creditCardAnnualFee: Decimal? = nil
    ) {
        self.id = id
        self.name = name
        self.accountTypeValue = accountType.rawValue
        self.institutionName = institutionName
        self.productName = productName
        self.accountHolderName = accountHolderName
        self.maskedAccountNumber = maskedAccountNumber
        self.lastFourDigits = lastFourDigits
        self.routingIdentifier = routingIdentifier
        self.openingBalance = openingBalance
        self.currency = currency
        self.createdDate = createdDate
        self.isArchived = isArchived
        self.statementOpeningBalance = statementOpeningBalance
        self.statementStartDate = statementStartDate
        self.statementEndDate = statementEndDate
        self.statementClosingBalance = statementClosingBalance
        self.creditCardStatementBalance = creditCardStatementBalance
        self.creditCardMinimumPayment = creditCardMinimumPayment
        self.creditCardAnnualPercentageRate = creditCardAnnualPercentageRate
        self.creditCardStatementClosingDate = creditCardStatementClosingDate
        self.creditCardPaymentDueDate = creditCardPaymentDueDate
        self.creditCardInterestFreeDays = creditCardInterestFreeDays
        self.creditCardHasInterestFreePeriod = creditCardHasInterestFreePeriod
        self.creditCardCreditLimit = creditCardCreditLimit
        self.creditCardAvailableCredit = creditCardAvailableCredit
        self.creditCardCashAdvanceInterestRate = creditCardCashAdvanceInterestRate
        self.creditCardBalanceTransferInterestRate = creditCardBalanceTransferInterestRate
        self.creditCardAnnualFee = creditCardAnnualFee
    }
}

@Model
final class Category: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var isSystemCategory: Bool
    var iconName: String?

    @Relationship(inverse: \Transaction.category)
    var transactions: [Transaction] = []

    init(
        id: UUID = UUID(),
        name: String,
        isSystemCategory: Bool = false,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isSystemCategory = isSystemCategory
        self.iconName = iconName
    }
}

@Model
final class MerchantCategoryRule: Identifiable {
    @Attribute(.unique) var id: UUID
    var merchantKey: String
    var createdDate: Date
    var category: Category?

    init(
        id: UUID = UUID(),
        merchantKey: String,
        category: Category,
        createdDate: Date = .now
    ) {
        self.id = id
        self.merchantKey = merchantKey
        self.category = category
        self.createdDate = createdDate
    }
}

@Model
final class Transaction: Identifiable {
    @Attribute(.unique) var id: UUID
    var transactionDate: Date
    var postedDate: Date?
    var merchantDescription: String
    /// The raw descriptor received from a bank import, when it differs from the display merchant.
    /// Optional to keep existing local records compatible with this additive SwiftData schema change.
    var originalBankDescription: String?
    var amount: Decimal
    private var transactionTypeValue: String
    var notes: String?
    private var sourceValue: String
    var importIdentifier: String?
    var createdDate: Date

    var category: Category?
    var account: Account?

    var transactionType: TransactionType {
        get { TransactionType(rawValue: transactionTypeValue) ?? .expense }
        set { transactionTypeValue = newValue.rawValue }
    }

    var source: TransactionSource {
        get { TransactionSource(rawValue: sourceValue) ?? .manual }
        set { sourceValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        transactionDate: Date,
        postedDate: Date? = nil,
        merchantDescription: String,
        originalBankDescription: String? = nil,
        amount: Decimal,
        transactionType: TransactionType,
        category: Category? = nil,
        account: Account,
        notes: String? = nil,
        source: TransactionSource = .manual,
        importIdentifier: String? = nil,
        createdDate: Date = .now
    ) {
        self.id = id
        self.transactionDate = transactionDate
        self.postedDate = postedDate
        self.merchantDescription = merchantDescription
        self.originalBankDescription = originalBankDescription
        self.amount = amount
        self.transactionTypeValue = transactionType.rawValue
        self.category = category
        self.account = account
        self.notes = notes
        self.sourceValue = source.rawValue
        self.importIdentifier = importIdentifier
        self.createdDate = createdDate
    }
}

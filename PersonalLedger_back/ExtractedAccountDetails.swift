import Foundation

/// How reliable a value detected from a statement appears before a person reviews it.
enum ExtractionConfidence: String, CaseIterable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func < (lhs: ExtractionConfidence, rhs: ExtractionConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A human-readable location in the imported statement, retained to support review UI later.
struct StatementSourceLocation: Equatable {
    let pageNumber: Int?
    let lineDescription: String?

    init(pageNumber: Int? = nil, lineDescription: String? = nil) {
        self.pageNumber = pageNumber
        self.lineDescription = lineDescription
    }
}

/// A single account value detected from statement text. This is deliberately not persisted:
/// extraction is only a proposal until the user chooses to create or update an Account.
struct ExtractedField<Value> {
    let value: Value
    let confidence: ExtractionConfidence
    let sourceText: String?
    let sourceLocation: StatementSourceLocation?

    init(
        value: Value,
        confidence: ExtractionConfidence,
        sourceText: String? = nil,
        sourceLocation: StatementSourceLocation? = nil
    ) {
        self.value = value
        self.confidence = confidence
        self.sourceText = sourceText
        self.sourceLocation = sourceLocation
    }
}

/// The identifying portion of a statement, detected before account-level values are read.
/// Every value remains a proposal until it is confirmed in a review flow.
struct StatementIdentity {
    let financialInstitution: ExtractedField<String>
    let productName: ExtractedField<String>?
    let accountType: ExtractedField<AccountType>?
    let accountHolderName: ExtractedField<String>?
    let maskedAccountNumber: ExtractedField<String>?
    let lastFourDigits: ExtractedField<String>?
}

/// Account information proposed by a statement import. No field is assumed to exist, and
/// no value in this type is applied to SwiftData until a future review step is confirmed.
struct ExtractedAccountDetails {
    // Common account fields
    var accountDisplayName: ExtractedField<String>?
    var financialInstitution: ExtractedField<String>?
    var accountType: ExtractedField<AccountType>?
    var productName: ExtractedField<String>?
    var currency: ExtractedField<String>?
    var accountHolderName: ExtractedField<String>?
    var maskedAccountNumber: ExtractedField<String>?
    var lastFourDigits: ExtractedField<String>?
    var routingIdentifier: ExtractedField<String>?
    var statementStartDate: ExtractedField<Date>?
    var statementEndDate: ExtractedField<Date>?
    var statementClosingBalance: ExtractedField<Decimal>?
    var openingBalance: ExtractedField<Decimal>?

    // Credit-card fields
    var statementBalance: ExtractedField<Decimal>?
    var currentOrClosingBalance: ExtractedField<Decimal>?
    var creditLimit: ExtractedField<Decimal>?
    var availableCredit: ExtractedField<Decimal>?
    var minimumPayment: ExtractedField<Decimal>?
    var paymentDueDate: ExtractedField<Date>?
    var purchaseInterestRate: ExtractedField<Decimal>?
    var cashAdvanceInterestRate: ExtractedField<Decimal>?
    var balanceTransferInterestRate: ExtractedField<Decimal>?
    var interestFreeDays: ExtractedField<Int>?
    var annualFee: ExtractedField<Decimal>?

    init() {}
}

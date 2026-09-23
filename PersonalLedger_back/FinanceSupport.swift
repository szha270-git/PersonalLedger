import Foundation
import FoundationModels
import SwiftData

enum CategoryDefaults {
    private static let definitions: [(name: String, iconName: String)] = [
        ("Groceries", "cart"),
        ("Dining", "fork.knife"),
        ("Transport", "car"),
        ("Shopping", "bag"),
        ("Bills", "doc.text"),
        ("Health", "cross.case"),
        ("Entertainment", "film"),
        ("Travel", "airplane"),
        ("Income", "arrow.down.circle"),
        ("Transfers", "arrow.left.arrow.right"),
        ("Pets", "pawprint")
    ]

    static func seedIfNeeded(in modelContext: ModelContext) throws {
        let existingCategories = try modelContext.fetch(FetchDescriptor<Category>())
        let existingNames = Set(existingCategories.map { $0.name.lowercased() })

        for definition in definitions where !existingNames.contains(definition.name.lowercased()) {
            modelContext.insert(
                Category(
                    name: definition.name,
                    isSystemCategory: true,
                    iconName: definition.iconName
                )
            )
        }
    }
}

enum MerchantCategoryRuleService {
    static func suggestions(in modelContext: ModelContext) throws -> [String: UUID] {
        let rules = try modelContext.fetch(FetchDescriptor<MerchantCategoryRule>())
        return rules.reduce(into: [:]) { suggestions, rule in
            if let categoryID = rule.category?.id {
                suggestions[rule.merchantKey] = categoryID
            }
        }
    }

    static func rememberCategory(
        for description: String,
        category: Category,
        in modelContext: ModelContext
    ) throws {
        let merchantKey = normalizedMerchantKey(for: description)
        guard !merchantKey.isEmpty else {
            return
        }

        let rules = try modelContext.fetch(FetchDescriptor<MerchantCategoryRule>())
        if let existingRule = rules.first(where: { $0.merchantKey == merchantKey }) {
            existingRule.category = category
        } else {
            modelContext.insert(MerchantCategoryRule(merchantKey: merchantKey, category: category))
        }
    }

    static func normalizedMerchantKey(for description: String) -> String {
        description
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// The editable portion of a transaction. Keeping it separate from the
/// SwiftData model lets the detail editor discard changes safely on Cancel.
struct TransactionEditDraft: Equatable {
    var merchantDescription: String
    var categoryID: UUID?
    var notes: String

    init(transaction: Transaction) {
        merchantDescription = transaction.merchantDescription
        categoryID = transaction.category?.id
        notes = transaction.notes ?? ""
    }
}

enum TransactionEditError: LocalizedError {
    case emptyMerchant
    case unavailableCategory

    var errorDescription: String? {
        switch self {
        case .emptyMerchant:
            "Enter a merchant name before saving."
        case .unavailableCategory:
            "That category is no longer available. Choose another category and try again."
        }
    }
}

/// Applies only user-editable transaction values. Import provenance and raw
/// bank data intentionally remain untouched.
enum TransactionEditService {
    static func save(
        _ draft: TransactionEditDraft,
        to transaction: Transaction,
        categories: [Category],
        in modelContext: ModelContext
    ) throws {
        let merchantDescription = draft.merchantDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchantDescription.isEmpty else {
            throw TransactionEditError.emptyMerchant
        }

        let category = try category(for: draft.categoryID, in: categories)
        let didExplicitlyChangeCategory = transaction.category?.id != draft.categoryID
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        transaction.merchantDescription = merchantDescription
        transaction.category = category
        transaction.notes = notes.isEmpty ? nil : notes

        if didExplicitlyChangeCategory, let category {
            try MerchantCategoryRuleService.rememberCategory(
                for: merchantDescription,
                category: category,
                in: modelContext
            )
        }

        try modelContext.save()
    }

    private static func category(for id: UUID?, in categories: [Category]) throws -> Category? {
        guard let id else {
            return nil
        }
        guard let category = categories.first(where: { $0.id == id }) else {
            throw TransactionEditError.unavailableCategory
        }
        return category
    }
}

/// Applies import-time category precedence without creating categories from bank-provided labels.
enum ImportCategorySuggestionService {
    /// Conservative source labels that have a clear equivalent in the app's category vocabulary.
    /// Keep this table explicit: unknown bank labels must remain unresolved rather than guessed.
    private static let sourceCategoryAliases = [
        "flights": "travel",
        "other shopping": "shopping",
        "internal transfers": "transfers"
    ]

    static func applySuggestions(
        to candidates: inout [ImportedTransactionCandidate],
        merchantRuleSuggestions: [String: UUID],
        categories: [Category]
    ) {
        // Keep the first matching category if a user has accidentally created
        // categories whose names differ only by case or surrounding whitespace.
        let categoryIDsByName = categories.reduce(into: [String: UUID]()) { result, category in
            result[normalizedCategoryName(category.name), default: category.id] = category.id
        }

        for index in candidates.indices {
            let merchantKey = MerchantCategoryRuleService.normalizedMerchantKey(
                for: candidates[index].description
            )
            if let categoryID = merchantRuleSuggestions[merchantKey] {
                candidates[index].proposedCategoryID = categoryID
            } else if let sourceCategorySuggestion = candidates[index].sourceCategorySuggestion {
                candidates[index].proposedCategoryID = categoryID(
                    for: sourceCategorySuggestion,
                    categoryIDsByName: categoryIDsByName
                )
            }
        }
    }

    static func deterministicCategoryID(
        for sourceCategorySuggestion: String?,
        categories: [Category]
    ) -> UUID? {
        let categoryIDsByName = categories.reduce(into: [String: UUID]()) { result, category in
            result[normalizedCategoryName(category.name), default: category.id] = category.id
        }
        guard let sourceCategorySuggestion else {
            return nil
        }
        return categoryID(
            for: sourceCategorySuggestion,
            categoryIDsByName: categoryIDsByName
        )
    }

    private static func categoryID(
        for sourceCategorySuggestion: String,
        categoryIDsByName: [String: UUID]
    ) -> UUID? {
        let normalisedSource = normalizedCategoryName(sourceCategorySuggestion)
        let targetCategory = sourceCategoryAliases[normalisedSource] ?? normalisedSource
        return categoryIDsByName[targetCategory]
    }

    private static func normalizedCategoryName(_ name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Keeps duplicate recommendations stable when a bank supplies a cleaned merchant name.
enum TransactionDuplicateDetector {
    static func isPotentialDuplicate(
        _ candidate: ImportedTransactionCandidate,
        among existingTransactions: [Transaction]
    ) -> Bool {
        guard let accountID = candidate.selectedAccountID else {
            return false
        }

        let candidateSourceDescription = candidate.originalBankDescription ?? candidate.description
        return existingTransactions.contains { transaction in
            let transactionSourceDescription = transaction.originalBankDescription ?? transaction.merchantDescription
            return transaction.account?.id == accountID &&
                (transaction.importIdentifier == candidate.importIdentifier ||
                    (transaction.amount == candidate.amount &&
                        transactionSourceDescription
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .caseInsensitiveCompare(
                                candidateSourceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                            ) == .orderedSame &&
                        abs(transaction.transactionDate.timeIntervalSince(candidate.date)) < 86_400))
        }
    }
}

/// Applies a destination account without changing any parsed transaction or enrichment data.
enum ImportDestinationAccountService {
    static func assign(
        accountID: UUID?,
        to candidates: inout [ImportedTransactionCandidate]
    ) {
        for index in candidates.indices {
            candidates[index].selectedAccountID = accountID
        }
    }
}

enum ImportTransactionReviewState: Equatable {
    case ready
    case needsAttention(ImportTransactionReviewIssue)
}

enum ImportTransactionReviewIssue: Equatable {
    case missingAccount
    case potentialDuplicate
    case parserNeedsReview
    case missingDescription

    var title: String {
        switch self {
        case .missingAccount:
            "Choose a destination account"
        case .potentialDuplicate:
            "Possible duplicate"
        case .parserNeedsReview:
            "Check this transaction"
        case .missingDescription:
            "Missing merchant or description"
        }
    }
}

struct ImportReviewSummary: Equatable {
    let recognisedCount: Int
    let readyCount: Int
    let needsAttentionCount: Int
    let duplicateCount: Int
    let includedCount: Int
    let uncategorisedCount: Int
}

/// Determines review presentation without changing whether a user may explicitly include a duplicate.
enum ImportReviewService {
    nonisolated static func state(for candidate: ImportedTransactionCandidate) -> ImportTransactionReviewState {
        if candidate.status == .potentialDuplicate {
            return .needsAttention(.potentialDuplicate)
        }
        if candidate.selectedAccountID == nil {
            return .needsAttention(.missingAccount)
        }
        if candidate.status == .needsReview {
            return .needsAttention(.parserNeedsReview)
        }
        if candidate.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .needsAttention(.missingDescription)
        }
        return .ready
    }

    nonisolated static func summary(for candidates: [ImportedTransactionCandidate]) -> ImportReviewSummary {
        let states = candidates.map(state(for:))
        return ImportReviewSummary(
            recognisedCount: candidates.count,
            readyCount: states.filter { $0 == .ready }.count,
            needsAttentionCount: states.filter {
                if case .needsAttention = $0 { return true }
                return false
            }.count,
            duplicateCount: candidates.filter { $0.status == .potentialDuplicate }.count,
            includedCount: candidates.filter(\.isIncluded).count,
            uncategorisedCount: candidates.filter { $0.isIncluded && $0.proposedCategoryID == nil }.count
        )
    }

    nonisolated static func canConfirmImport(_ candidates: [ImportedTransactionCandidate]) -> Bool {
        let includedCandidates = candidates.filter(\.isIncluded)
        return !includedCandidates.isEmpty && includedCandidates.allSatisfy { candidate in
            candidate.selectedAccountID != nil &&
                !candidate.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func applyDuplicateRecommendations(
        to candidates: inout [ImportedTransactionCandidate],
        isPotentialDuplicate: (ImportedTransactionCandidate) -> Bool
    ) {
        for index in candidates.indices {
            if isPotentialDuplicate(candidates[index]) {
                if candidates[index].status != .potentialDuplicate {
                    candidates[index].status = .potentialDuplicate
                    candidates[index].isIncluded = false
                }
            } else if candidates[index].status == .potentialDuplicate {
                // Keep an explicitly excluded transaction excluded, but stop presenting it as a duplicate
                // if an edit means it no longer matches an existing record.
                candidates[index].status = .ready
            }
        }
    }
}

enum TransactionImportClassifier {
    /// Conservative markers for movements between a person's own accounts.
    /// Anything less certain remains an expense or income for the user to review.
    private static let transferMarkers = [
        "internal transfer",
        "transfer to",
        "transfer from",
        "card payment",
        "payment thank you"
    ]

    static func transactionType(for candidate: ImportedTransactionCandidate) -> TransactionType {
        let description = candidate.description.lowercased()
        if transferMarkers.contains(where: description.contains) {
            return .transfer
        }
        return candidate.amount < 0 ? .expense : .income
    }
}

/// The only transaction details supplied to the on-device language model.
/// Financial values, account information, identifiers, and full source rows are excluded.
struct TransactionAIEnrichmentRequest: Sendable {
    let displayMerchantName: String
    let originalBankDescription: String?
    let sourceCategorySuggestion: String?
    let transactionDirection: String
    let allowedCategoryNames: [String]
    let allowsMerchantNameCleanup: Bool
}

struct TransactionAIEnrichment: Sendable, Equatable {
    let merchantNameSuggestion: String?
    let categorySuggestion: String?
}

/// Optional enrichment progress. This has no role in deterministic import validation.
enum AIEnrichmentState: Equatable {
    case notNeeded
    case pending
    case enriched
    case noSuggestion
    case unavailable
    case failed
}

enum TransactionAIAvailability: Equatable {
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case unavailable

    var isAvailable: Bool { self == .available }

    var standardCategorisationMessage: String? {
        switch self {
        case .available: nil
        case .appleIntelligenceNotEnabled: "Apple Intelligence is unavailable — using standard categorisation."
        case .deviceNotEligible: "This device does not support Apple Intelligence — using standard categorisation."
        case .modelNotReady: "Apple Intelligence is not ready — using standard categorisation."
        case .unavailable: "Apple Intelligence is unavailable — using standard categorisation."
        }
    }
}

enum TransactionAIEnrichmentError: Error {
    case unavailable
    case guidedGenerationUnsupported
}

protocol TransactionEnrichmentProviding: Sendable {
    func availability() -> TransactionAIAvailability
    func enrich(_ request: TransactionAIEnrichmentRequest) async throws -> TransactionAIEnrichment
}

/// Uses only SystemLanguageModel.default. No transaction content leaves the device.
struct AppleFoundationModelTransactionEnricher: TransactionEnrichmentProviding {
    private let model = SystemLanguageModel.default

    func availability() -> TransactionAIAvailability {
        switch model.availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .unavailable
        @unknown default: .unavailable
        }
    }

    func enrich(_ request: TransactionAIEnrichmentRequest) async throws -> TransactionAIEnrichment {
        guard availability().isAvailable else { throw TransactionAIEnrichmentError.unavailable }
        guard model.capabilities.contains(.guidedGeneration) else {
            throw TransactionAIEnrichmentError.guidedGenerationUnsupported
        }

        let instructions = Instructions {
            "You help classify imported bank transactions. Never modify financial values. Choose a category only from the supplied categories. Do not invent merchant identities, locations, addresses, or branches. Return no merchant suggestion when uncertain. When merchant cleanup is not permitted, return no merchant suggestion. Prefer an understandable source merchant name over a cleanup suggestion."
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(
            to: prompt(for: request),
            generating: GeneratedTransactionAIEnrichment.self
        )
        return TransactionAIEnrichment(
            merchantNameSuggestion: response.content.merchantNameSuggestion,
            categorySuggestion: response.content.categorySuggestion
        )
    }

    private func prompt(for request: TransactionAIEnrichmentRequest) -> String {
        [
            "Display merchant: \(request.displayMerchantName)",
            "Original bank description: \(request.originalBankDescription ?? "Not provided")",
            "Bank category suggestion: \(request.sourceCategorySuggestion ?? "Not provided")",
            "Transaction direction: \(request.transactionDirection)",
            "Allowed categories: \(request.allowedCategoryNames.joined(separator: ", "))",
            "Merchant cleanup permitted: \(request.allowsMerchantNameCleanup ? "yes" : "no")"
        ].joined(separator: "\n")
    }
}

@Generable(description: "A conservative enrichment proposal for one imported transaction.")
private struct GeneratedTransactionAIEnrichment {
    @Guide(description: "A conservative cleanup of the supplied merchant text only. Return nil unless it removes obvious noise without guessing a business identity.")
    var merchantNameSuggestion: String?

    @Guide(description: "One exact category from the supplied allowed categories, or nil.")
    var categorySuggestion: String?

}

struct TransactionAIEnrichmentSnapshot: Equatable {
    let id: UUID
    let description: String
    let originalBankDescription: String?
    let proposedCategoryID: UUID?
    let status: ImportCandidateStatus
    let selectedAccountID: UUID?
    let isIncluded: Bool
    let aiEnrichmentState: AIEnrichmentState

    init(candidate: ImportedTransactionCandidate) {
        id = candidate.id
        description = candidate.description
        originalBankDescription = candidate.originalBankDescription
        proposedCategoryID = candidate.proposedCategoryID
        status = candidate.status
        selectedAccountID = candidate.selectedAccountID
        isIncluded = candidate.isIncluded
        aiEnrichmentState = candidate.aiEnrichmentState
    }

    func matches(_ candidate: ImportedTransactionCandidate) -> Bool {
        self == TransactionAIEnrichmentSnapshot(candidate: candidate)
    }
}

/// Applies only safe, validated AI metadata. It never changes financial values, raw bank
/// descriptions, account selection, duplicate state, or deterministic review status.
enum TransactionAIEnrichmentPolicy {
    static func shouldRequest(for candidate: ImportedTransactionCandidate) -> Bool {
        candidate.status == .ready &&
            candidate.selectedAccountID != nil &&
            candidate.proposedCategoryID == nil &&
            candidate.aiEnrichmentState != .pending &&
            candidate.aiEnrichmentState != .enriched &&
            candidate.aiEnrichmentState != .noSuggestion &&
            !candidate.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func allowsMerchantNameCleanup(for candidate: ImportedTransactionCandidate) -> Bool {
        guard let originalBankDescription = candidate.originalBankDescription else {
            return true
        }
        return originalBankDescription.caseInsensitiveCompare(candidate.description) == .orderedSame
    }

    @discardableResult
    static func apply(
        _ enrichment: TransactionAIEnrichment,
        to candidate: inout ImportedTransactionCandidate,
        categories: [Category]
    ) -> Bool {
        guard candidate.status == .ready,
              candidate.selectedAccountID != nil,
              candidate.proposedCategoryID == nil,
              !candidate.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        var changed = false

        if let categoryID = validatedCategoryID(enrichment.categorySuggestion, categories: categories) {
            candidate.proposedCategoryID = categoryID
            candidate.aiCategorySuggestion = categories.first { $0.id == categoryID }?.name
            changed = true
        }

        if let merchantName = validatedMerchantName(enrichment.merchantNameSuggestion, candidate: candidate) {
            candidate.description = merchantName
            candidate.aiMerchantNameSuggestion = merchantName
            changed = true
        }

        candidate.aiEnrichmentState = changed ? .enriched : .noSuggestion
        return changed
    }

    private static func validatedCategoryID(_ suggestion: String?, categories: [Category]) -> UUID? {
        guard let suggestion else { return nil }
        let normalisedSuggestion = normalisedCategoryName(suggestion)
        guard !normalisedSuggestion.isEmpty else { return nil }
        return categories.first { normalisedCategoryName($0.name) == normalisedSuggestion }?.id
    }

    private static func validatedMerchantName(
        _ suggestion: String?,
        candidate: ImportedTransactionCandidate
    ) -> String? {
        guard let suggestion else { return nil }
        let cleanedSuggestion = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSuggestion.isEmpty,
              cleanedSuggestion.caseInsensitiveCompare(candidate.description) != .orderedSame
        else { return nil }

        // A distinct bank-supplied merchant label is more trustworthy than a model cleanup.
        if let originalBankDescription = candidate.originalBankDescription,
           originalBankDescription.caseInsensitiveCompare(candidate.description) != .orderedSame {
            return nil
        }

        let sourceTokens = Set(
            MerchantCategoryRuleService.normalizedMerchantKey(for: candidate.description)
                .split(separator: " ")
                .map(String.init)
        )
        let suggestionTokens = Set(
            MerchantCategoryRuleService.normalizedMerchantKey(for: cleanedSuggestion)
                .split(separator: " ")
                .map(String.init)
        )
        guard !suggestionTokens.isEmpty,
              suggestionTokens.isSubset(of: sourceTokens),
              suggestionTokens.count < sourceTokens.count
        else { return nil }
        return cleanedSuggestion
    }

    private static func normalisedCategoryName(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum TransactionAISettings {
    static let useAppleIntelligenceKey = "useAppleIntelligenceForTransactionSuggestions"

    static func configureDefault(using availability: TransactionAIAvailability) {
        guard UserDefaults.standard.object(forKey: useAppleIntelligenceKey) == nil else { return }
        UserDefaults.standard.set(availability.isAvailable, forKey: useAppleIntelligenceKey)
    }
}

enum TransactionAIEnrichmentRunState: Equatable {
    case idle
    case categorising(total: Int)
    case completed(enriched: Int, considered: Int, failures: Int)
    case usingStandardCategorisation(String)
    case disabled

    var reviewMessage: String? {
        switch self {
        case .idle, .disabled: return nil
        case let .categorising(total): return "Apple Intelligence categorising \(total) transaction(s)…"
        case let .completed(enriched, considered, failures):
            guard considered > 0 else { return nil }
            if failures > 0 {
                return "Apple Intelligence suggested details for \(enriched) transaction(s); standard categorisation was used for the rest."
            }
            return "Apple Intelligence suggested details for \(enriched) transaction(s)."
        case let .usingStandardCategorisation(message): return message
        }
    }
}

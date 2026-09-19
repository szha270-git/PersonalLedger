import Foundation
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
        ("Transfers", "arrow.left.arrow.right")
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

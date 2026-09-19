import Foundation

/// Conservatively identifies statement account metadata. It only returns values that have
/// an explicit label or a strong statement-specific marker; it never writes SwiftData.
struct StatementAccountDetailsExtractor {
    func extract(from textExtraction: PDFTextExtraction) -> ExtractedAccountDetails? {
        extract(documentText: textExtraction.documentText)
    }

    func extract(documentText: String) -> ExtractedAccountDetails? {
        guard let identity = extractIdentity(documentText: documentText) else {
            return nil
        }

        var details = ExtractedAccountDetails()
        details.financialInstitution = identity.financialInstitution
        details.productName = identity.productName
        details.accountType = identity.accountType
        details.accountHolderName = identity.accountHolderName
        details.maskedAccountNumber = identity.maskedAccountNumber
        details.lastFourDigits = identity.lastFourDigits

        details.currency = stringField(
            patterns: [#"(?im)\bCurrency\s*[:\-]?\s*([A-Z]{3})\b"#, #"\b(AUD|USD|NZD|GBP|EUR|CAD)\b"#],
            in: documentText,
            confidence: .medium
        )
        details.routingIdentifier = stringField(
            patterns: [#"(?im)\b(?:BSB|Routing(?:\s+(?:Number|Identifier))?)\s*[:\-]?\s*(\d{3}[\s-]?\d{3}|[A-Z0-9-]{6,})"#],
            in: documentText,
            confidence: .high
        )
        details.openingBalance = moneyField(labels: ["Opening Balance"], in: documentText)
        details.statementClosingBalance = moneyField(
            labels: ["Closing Balance", "Closing Account Balance"],
            in: documentText
        )
        details.statementStartDate = dateField(
            patterns: [#"(?is)\bStatement\s+Period\s+(?:From\s+)?(.{3,45}?)\s+(?:to|until)\s+"#],
            in: documentText
        )
        details.statementEndDate = dateField(
            patterns: [
                #"(?is)\bStatement\s+Period\s+(?:From\s+)?(?:.{3,45}?)\s+(?:to|until)\s+([A-Za-z]+\s+\d{1,2},?\s+\d{4}|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{1,2}-\d{1,2})"#,
                #"(?im)\bStatement\s+Date\s*[:\-]?\s*([A-Za-z]+\s+\d{1,2},?\s+\d{4}|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{1,2}-\d{1,2})"#
            ],
            in: documentText
        )

        if identity.accountType?.value == .creditCard {
            details.statementBalance = moneyField(
                labels: ["Statement Balance", "Amount Payable"],
                in: documentText
            ) ?? details.statementClosingBalance
            details.currentOrClosingBalance = details.statementClosingBalance
            details.creditLimit = moneyField(labels: ["Credit Limit"], in: documentText)
            details.availableCredit = moneyField(labels: ["Available Credit"], in: documentText)
            details.minimumPayment = moneyField(
                labels: ["Minimum Payment Due", "Minimum Payment"],
                in: documentText
            )
            details.paymentDueDate = dateField(
                patterns: [#"(?im)\b(?:Payment\s+)?Due\s+Date\s*[:\-]?\s*([A-Za-z]+\s+\d{1,2},?\s+\d{4}|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{1,2}-\d{1,2})"#],
                in: documentText
            )
            details.purchaseInterestRate = percentField(
                labels: ["Purchase APR", "Purchase Interest Rate", "Annual Percentage Rate"],
                in: documentText
            )
            details.cashAdvanceInterestRate = percentField(
                labels: ["Cash Advance APR", "Cash Advance Interest Rate"],
                in: documentText
            )
            details.interestFreeDays = integerField(
                patterns: [
                    #"(?im)\b(?:Up\s+to\s+)?(\d{1,3})\s+(?:days?\s+)?interest[-\s]?free\b"#,
                    #"(?im)\bInterest[-\s]?free\s+days?\s*[:\-]?\s*(\d{1,3})\b"#
                ],
                in: documentText
            )
        }

        return details
    }

    func extractIdentity(documentText: String) -> StatementIdentity? {
        identifyStatement(in: documentText)
    }

    private func identifyStatement(in text: String) -> StatementIdentity? {
        guard let institution = financialInstitution(in: text) else {
            return nil
        }

        let cardSource = firstMatchingText(
            pattern: #"(?i)\b(?:credit\s+card|platinum\s+card|gold\s+card|card\s+account)\b"#,
            in: text
        )
        let accountType = cardSource.map {
            ExtractedField(value: AccountType.creditCard, confidence: .high, sourceText: $0)
        }
        let maskedAccountNumber = stringField(
            patterns: [#"(?im)\b(?:Card|Account|Membership)\s+(?:Number|No\.?|#)\s*[:\-]?\s*([Xx*•\d][Xx*•\d\s-]{3,})"#],
            in: text,
            confidence: .high
        )
        let lastFourDigits = maskedAccountNumber.flatMap { field -> ExtractedField<String>? in
            let digits = field.value.filter(\.isNumber)
            guard digits.count >= 4 else { return nil }
            return ExtractedField(
                value: String(digits.suffix(4)),
                confidence: field.confidence,
                sourceText: field.sourceText
            )
        }

        return StatementIdentity(
            financialInstitution: institution,
            productName: productName(in: text, institution: institution.value),
            accountType: accountType,
            accountHolderName: accountHolderName(in: text),
            maskedAccountNumber: maskedAccountNumber,
            lastFourDigits: lastFourDigits
        )
    }

    private func financialInstitution(in text: String) -> ExtractedField<String>? {
        if let sourceText = firstMatchingText(pattern: #"(?i)\bAmerican\s+Express(?:\s+Australia)?\b"#, in: text) {
            let value = sourceText.localizedCaseInsensitiveContains("Australia")
                ? "American Express Australia"
                : "American Express"
            return ExtractedField(value: value, confidence: .high, sourceText: sourceText)
        }
        return stringField(
            patterns: [#"(?im)\b(?:Financial\s+Institution|Institution|Bank)\s*[:\-]\s*([^\n]{2,80})"#],
            in: text,
            confidence: .medium
        )
    }

    private func productName(in text: String, institution: String) -> ExtractedField<String>? {
        if let labelledProduct = stringField(
            patterns: [#"(?im)\b(?:Product|Account\s+Name|Card\s+Type)\s*[:\-]\s*([^\n]{2,80})"#],
            in: text,
            confidence: .high
        ) {
            return labelledProduct
        }

        guard let sourceText = firstMatchingText(
            pattern: #"(?im)^.*\b(?:Platinum|Gold|Silver|Rewards|Credit)\s+Card\b.*$"#,
            in: text
        ) else {
            return nil
        }
        let product = sourceText
            .replacingOccurrences(of: institution, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !product.isEmpty else { return nil }
        return ExtractedField(value: product, confidence: .medium, sourceText: sourceText)
    }

    private func accountHolderName(in text: String) -> ExtractedField<String>? {
        stringField(
            patterns: [
                #"(?im)\b(?:Account\s+Holder|Card\s+Member|Prepared\s+For)\s*[:\-]\s*([A-Z][A-Z .'-]{2,80})"#,
                #"(?im)^\s*([A-Z][A-Z .'-]{2,80})\s+(?:(?:X|\*){2,}[X*\d-]*)\s*$"#
            ],
            in: text,
            confidence: .medium
        )
    }

    private func moneyField(labels: [String], in text: String) -> ExtractedField<Decimal>? {
        let alternatives = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return decimalField(
            pattern: "(?im)\\b(?:\(alternatives))\\b\\s*[:\\-]?\\s*(?:AUD\\s*)?\\$?\\s*([0-9][0-9,]*\\.\\d{2})\\b",
            in: text
        )
    }

    private func percentField(labels: [String], in text: String) -> ExtractedField<Decimal>? {
        let alternatives = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return decimalField(
            pattern: "(?im)\\b(?:\(alternatives))\\b\\s*[:\\-]?\\s*([0-9]{1,3}(?:\\.\\d{1,4})?)\\s*%",
            in: text
        )
    }

    private func decimalField(pattern: String, in text: String) -> ExtractedField<Decimal>? {
        guard let result = firstMatch(pattern: pattern, in: text),
              let rawCapture = result.captures.first
        else {
            return nil
        }
        let rawValue = rawCapture.replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return ExtractedField(value: value, confidence: .high, sourceText: result.text)
    }

    private func integerField(patterns: [String], in text: String) -> ExtractedField<Int>? {
        for pattern in patterns {
            guard let result = firstMatch(pattern: pattern, in: text),
                  let capture = result.captures.first,
                  let value = Int(capture)
            else {
                continue
            }
            return ExtractedField(value: value, confidence: .high, sourceText: result.text)
        }
        return nil
    }

    private func dateField(patterns: [String], in text: String) -> ExtractedField<Date>? {
        for pattern in patterns {
            guard let result = firstMatch(pattern: pattern, in: text),
                  let capture = result.captures.first,
                  let value = parseDate(capture)
            else {
                continue
            }
            return ExtractedField(value: value, confidence: .high, sourceText: result.text)
        }
        return nil
    }

    private func stringField(
        patterns: [String],
        in text: String,
        confidence: ExtractionConfidence
    ) -> ExtractedField<String>? {
        for pattern in patterns {
            guard let result = firstMatch(pattern: pattern, in: text),
                  let capture = result.captures.first
            else {
                continue
            }
            let value = capture.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            return ExtractedField(value: value, confidence: confidence, sourceText: result.text)
        }
        return nil
    }

    private func parseDate(_ text: String) -> Date? {
        let formats = ["MMMM d, yyyy", "MMMM d yyyy", "d/M/yyyy", "d/M/yy", "yyyy-M-d"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date
            }
        }
        return nil
    }

    private func firstMatchingText(pattern: String, in text: String) -> String? {
        firstMatch(pattern: pattern, in: text)?.text
    }

    private func firstMatch(pattern: String, in text: String) -> (text: String, captures: [String])? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text)
        else {
            return nil
        }
        let captures = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text)
            else {
                return nil
            }
            return String(text[range])
        }
        return (String(text[matchRange]), captures)
    }
}

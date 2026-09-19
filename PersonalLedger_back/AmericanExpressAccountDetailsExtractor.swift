import Foundation

/// Reads account-level fields that Australian American Express statements explicitly label.
/// It operates on normalised text so ordinary PDF line wrapping does not change the result.
struct AmericanExpressAccountDetailsExtractor {
    func extractIdentity(documentText: String) -> StatementIdentity? {
        let text = normalizedWhitespace(in: documentText)
        guard let institutionSource = firstMatch(#"(?i)\bAmerican\s+Express(?:\s+Australia)?\b"#, in: text)?.text else {
            return nil
        }

        let cardSource = firstMatch(#"(?i)\b(?:platinum|gold|green|business|credit)\s+card\b"#, in: text)?.text
            ?? firstMatch(#"(?i)\bAmerican\s+Express\s+[^.]{0,50}?\bCard\b"#, in: text)?.text
        let productName = cardSource.map { source in
            let value = source
                .replacingOccurrences(of: "American Express", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "Australia", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ExtractedField(value: value, confidence: .medium, sourceText: source)
        }

        let maskedAccountNumber = stringField(
            patterns: [
                #"(?i)\b(?:Card|Membership)\s+(?:Number|No\.?)\s*[:\-]?\s*([Xx*•\d][Xx*•\d\s-]{3,})"#
            ],
            in: text,
            confidence: .high
        )
        let lastFourDigits = maskedAccountNumber.flatMap { field -> ExtractedField<String>? in
            let digits = field.value.filter(\.isNumber)
            guard digits.count >= 4 else { return nil }
            return ExtractedField(
                value: String(digits.suffix(4)),
                confidence: .high,
                sourceText: field.sourceText
            )
        }

        return StatementIdentity(
            financialInstitution: ExtractedField(
                value: "American Express",
                confidence: .high,
                sourceText: institutionSource
            ),
            productName: productName,
            accountType: ExtractedField(value: .creditCard, confidence: .high, sourceText: cardSource ?? institutionSource),
            accountHolderName: accountHolder(in: text),
            maskedAccountNumber: maskedAccountNumber,
            lastFourDigits: lastFourDigits
        )
    }

    func extractAccountDetails(documentText: String) -> ExtractedAccountDetails? {
        let text = normalizedWhitespace(in: documentText)
        guard let identity = extractIdentity(documentText: text) else {
            return nil
        }

        var details = ExtractedAccountDetails()
        details.financialInstitution = identity.financialInstitution
        details.productName = identity.productName
        details.accountType = identity.accountType
        details.accountHolderName = identity.accountHolderName
        details.maskedAccountNumber = identity.maskedAccountNumber
        details.lastFourDigits = identity.lastFourDigits
        details.currency = currency(in: text)

        let period = statementPeriod(in: text)
        details.statementStartDate = period?.start
        details.statementEndDate = period?.end
        details.statementClosingBalance = moneyField(
            labels: ["Closing Balance"],
            in: text
        )
        details.statementBalance = moneyField(
            labels: ["Statement Balance", "Amount Payable"],
            in: text
        ) ?? details.statementClosingBalance
        details.currentOrClosingBalance = details.statementClosingBalance
        details.minimumPayment = moneyField(
            labels: ["Minimum Payment Due", "Minimum Payment"],
            in: text
        )
        details.paymentDueDate = dateField(
            patterns: [
                #"(?i)\b(?:Payment\s+)?Due(?:\s+Date)?\s*[:\-]?\s*([A-Za-z]+\s+\d{1,2},?\s+\d{4}|\d{1,2}/\d{1,2}/\d{2,4})"#
            ],
            in: text
        )
        details.creditLimit = moneyField(labels: ["Credit Limit"], in: text)
        details.purchaseInterestRate = percentageField(
            labels: ["Purchase APR", "Purchase Interest Rate", "Purchase Annual Percentage Rate", "Annual Percentage Rate"],
            in: text
        )
        details.cashAdvanceInterestRate = percentageField(
            labels: ["Cash Advance APR", "Cash Advance Interest Rate", "Cash Advance Annual Percentage Rate"],
            in: text
        )
        details.interestFreeDays = integerField(
            patterns: [
                #"(?i)\b(?:up\s+to\s+)?(\d{1,3})\s+(?:days?\s+)?interest[-\s]?free\b"#,
                #"(?i)\binterest[-\s]?free\s+days?\s*[:\-]?\s*(\d{1,3})\b"#
            ],
            in: text
        )

        return details
    }

    private func accountHolder(in text: String) -> ExtractedField<String>? {
        stringField(
            patterns: [
                #"(?i)\b(?:Card\s+Member|Account\s+Holder)\s*[:\-]?\s*([A-Za-z][A-Za-z .'-]{2,80})"#
            ],
            in: text,
            confidence: .high
        )
    }

    private func currency(in text: String) -> ExtractedField<String>? {
        stringField(
            patterns: [
                #"(?i)\bCurrency\s*[:\-]?\s*(AUD|USD|NZD|GBP|EUR|CAD)\b"#,
                #"\b(AUD)\s+[0-9][0-9,]*\.\d{2}\b"#
            ],
            in: text,
            confidence: .high
        )
    }

    private func statementPeriod(
        in text: String
    ) -> (start: ExtractedField<Date>?, end: ExtractedField<Date>?)? {
        guard let result = firstMatch(
            #"(?i)\bStatement\s+Period\s+(?:From\s+)?([A-Za-z]+\s+\d{1,2})(?:,?\s+(\d{4}))?\s+to\s+([A-Za-z]+\s+\d{1,2}),?\s+(\d{4})"#,
            in: text
        ), result.captures.count == 4,
        let endDate = parseDate("\(result.captures[2]) \(result.captures[3])")
        else {
            return nil
        }

        let calendar = Calendar(identifier: .gregorian)
        let endYear = calendar.component(.year, from: endDate)
        let endMonth = calendar.component(.month, from: endDate)
        let startMonth = monthNumber(named: result.captures[0].components(separatedBy: " ").first ?? "") ?? endMonth
        let startYear = Int(result.captures[1]) ?? (startMonth > endMonth ? endYear - 1 : endYear)
        let startDate = parseDate("\(result.captures[0]) \(startYear)")
        let sourceText = result.text

        return (
            startDate.map { ExtractedField(value: $0, confidence: .high, sourceText: sourceText) },
            ExtractedField(value: endDate, confidence: .high, sourceText: sourceText)
        )
    }

    private func moneyField(labels: [String], in text: String) -> ExtractedField<Decimal>? {
        let labelPattern = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return decimalField(
            pattern: "(?i)\\b(?:\(labelPattern))\\b\\s*[:\\-]?\\s*(?:AUD\\s*)?\\$?\\s*([0-9][0-9,]*\\.\\d{2})\\b",
            in: text
        )
    }

    private func percentageField(labels: [String], in text: String) -> ExtractedField<Decimal>? {
        let labelPattern = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return decimalField(
            pattern: "(?i)\\b(?:\(labelPattern))\\b\\s*[:\\-]?\\s*([0-9]{1,3}(?:\\.\\d{1,4})?)\\s*%",
            in: text
        )
    }

    private func decimalField(pattern: String, in text: String) -> ExtractedField<Decimal>? {
        guard let result = firstMatch(pattern, in: text),
              let capture = result.captures.first,
              let value = Decimal(
                string: capture.replacingOccurrences(of: ",", with: ""),
                locale: Locale(identifier: "en_US_POSIX")
              )
        else {
            return nil
        }
        return ExtractedField(value: value, confidence: .high, sourceText: result.text)
    }

    private func integerField(patterns: [String], in text: String) -> ExtractedField<Int>? {
        for pattern in patterns {
            guard let result = firstMatch(pattern, in: text),
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
            guard let result = firstMatch(pattern, in: text),
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
            guard let result = firstMatch(pattern, in: text),
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
        let formats = ["MMMM d, yyyy", "MMMM d yyyy", "d/M/yyyy", "d/M/yy"]
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

    private func monthNumber(named month: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.monthSymbols.firstIndex {
            $0.caseInsensitiveCompare(month) == .orderedSame
        }.map { $0 + 1 }
    }

    private func normalizedWhitespace(in text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func firstMatch(_ pattern: String, in text: String) -> (text: String, captures: [String])? {
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

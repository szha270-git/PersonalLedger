import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ImportFormat {
    case csv
    case pdf
}

enum ImportCandidateConfidence: String {
    case high
    case medium
    case low
}

enum ImportCandidateStatus: String {
    case ready
    case needsReview
    case potentialDuplicate
}

struct ImportedTransactionCandidate: Identifiable {
    let id: UUID
    var date: Date
    var description: String
    var amount: Decimal
    var balance: Decimal?
    let sourceText: String
    var confidence: ImportCandidateConfidence
    var status: ImportCandidateStatus
    var selectedAccountID: UUID?
    var proposedCategoryID: UUID?
    let importIdentifier: String
    var isIncluded: Bool

    init(
        id: UUID = UUID(),
        date: Date,
        description: String,
        amount: Decimal,
        balance: Decimal? = nil,
        sourceText: String,
        confidence: ImportCandidateConfidence,
        status: ImportCandidateStatus,
        selectedAccountID: UUID? = nil,
        proposedCategoryID: UUID? = nil,
        importIdentifier: String,
        isIncluded: Bool = true
    ) {
        self.id = id
        self.date = date
        self.description = description
        self.amount = amount
        self.balance = balance
        self.sourceText = sourceText
        self.confidence = confidence
        self.status = status
        self.selectedAccountID = selectedAccountID
        self.proposedCategoryID = proposedCategoryID
        self.importIdentifier = importIdentifier
        self.isIncluded = isIncluded
    }
}

enum CSVColumnRole: String, CaseIterable, Identifiable {
    case date
    case description
    case debit
    case credit
    case amount
    case balance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date:
            "Date"
        case .description:
            "Description"
        case .debit:
            "Debit"
        case .credit:
            "Credit"
        case .amount:
            "Amount"
        case .balance:
            "Balance"
        }
    }
}

struct CSVColumnMapping {
    var dateColumn: Int?
    var descriptionColumn: Int?
    var debitColumn: Int?
    var creditColumn: Int?
    var amountColumn: Int?
    var balanceColumn: Int?

    subscript(role: CSVColumnRole) -> Int? {
        get {
            switch role {
            case .date:
                dateColumn
            case .description:
                descriptionColumn
            case .debit:
                debitColumn
            case .credit:
                creditColumn
            case .amount:
                amountColumn
            case .balance:
                balanceColumn
            }
        }
        set {
            switch role {
            case .date:
                dateColumn = newValue
            case .description:
                descriptionColumn = newValue
            case .debit:
                debitColumn = newValue
            case .credit:
                creditColumn = newValue
            case .amount:
                amountColumn = newValue
            case .balance:
                balanceColumn = newValue
            }
        }
    }

    var hasRequiredColumns: Bool {
        dateColumn != nil &&
        descriptionColumn != nil &&
        (amountColumn != nil || debitColumn != nil || creditColumn != nil)
    }
}

struct CSVAnalysis {
    let headers: [String]
    let rows: [[String]]
    let suggestedMapping: CSVColumnMapping
    let requiresManualMapping: Bool
}

struct CSVParseResult {
    let candidates: [ImportedTransactionCandidate]
    let skippedRowCount: Int
}

enum ImportServiceError: LocalizedError {
    case unreadableFile
    case missingHeader
    case invalidMapping

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "The selected file could not be read as a CSV."
        case .missingHeader:
            "The CSV file needs a header row with column names."
        case .invalidMapping:
            "Choose a date, description, and amount column before continuing."
        }
    }
}

/// A local-only entry point for statement imports. Future PDF importers can
/// conform to the same workflow without changing the review UI.
struct ImportService {
    private let csvParser = CSVTransactionParser()

    func analyseCSV(at url: URL) async throws -> CSVAnalysis {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileContents = try String(contentsOf: url, encoding: .utf8)
        return try csvParser.analyse(fileContents)
    }

    func makeCandidates(
        from analysis: CSVAnalysis,
        mapping: CSVColumnMapping,
        selectedAccountID: UUID? = nil
    ) throws -> CSVParseResult {
        try csvParser.makeCandidates(
            from: analysis,
            mapping: mapping,
            selectedAccountID: selectedAccountID
        )
    }
}

enum PDFPageTextExtractionMethod: String {
    case embeddedText
    case ocr
}

struct PDFPageTextExtraction: Identifiable {
    let pageNumber: Int
    let text: String
    let method: PDFPageTextExtractionMethod

    var id: Int { pageNumber }
}

/// Extracts embedded PDF text first, then uses on-device Vision OCR only when a page
/// has insufficient machine-readable text. Although iOS 27 also offers Vision's
/// RecognizeDocumentsRequest for tables and document sections, this stage retains the
/// ordered text OCR output needed by the parser. Structured table recognition can be
/// added later for transaction rows without weakening this local fallback.
struct PDFTextExtractor {
    private static let minimumMeaningfulCharacterCount = 12
    private static let ocrRenderScale: CGFloat = 3

    func extractText(at url: URL) async throws -> PDFTextExtraction {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw PDFStatementImportError.corruptedDocument
        }

        guard !document.isLocked else {
            throw PDFStatementImportError.passwordProtected
        }

        var pageExtractions: [PDFPageTextExtraction] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw PDFStatementImportError.pageCouldNotBeRead(pageNumber: index + 1)
            }

            let embeddedText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if Self.isMeaningfulText(embeddedText) {
                pageExtractions.append(
                    PDFPageTextExtraction(
                        pageNumber: index + 1,
                        text: embeddedText,
                        method: .embeddedText
                    )
                )
                continue
            }

            guard
                let image = renderedImage(for: page),
                let ocrText = try? recognizeText(in: image),
                Self.isMeaningfulText(ocrText)
            else {
                throw PDFStatementImportError.pageCouldNotBeRead(pageNumber: index + 1)
            }

            pageExtractions.append(
                PDFPageTextExtraction(
                    pageNumber: index + 1,
                    text: ocrText,
                    method: .ocr
                )
            )
        }

        guard !pageExtractions.isEmpty else {
            throw PDFStatementImportError.noMachineReadableText
        }

        return PDFTextExtraction(
            pages: pageExtractions
        )
    }

    static func isMeaningfulText(_ text: String) -> Bool {
        let meaningfulCharacterCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
        return meaningfulCharacterCount >= minimumMeaningfulCharacterCount
    }

    private func renderedImage(for page: PDFPage) -> CGImage? {
        let pageBounds = page.bounds(for: .mediaBox)
        guard !pageBounds.isEmpty else {
            return nil
        }

        let width = Int((pageBounds.width * Self.ocrRenderScale).rounded(.up))
        let height = Int((pageBounds.height * Self.ocrRenderScale).rounded(.up))
        guard
            width > 0,
            height > 0,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: Self.ocrRenderScale, y: -Self.ocrRenderScale)
        context.translateBy(x: -pageBounds.origin.x, y: -pageBounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-AU", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        let orderedObservations = observations.sorted { first, second in
            let verticalDifference = abs(first.boundingBox.midY - second.boundingBox.midY)
            if verticalDifference > 0.015 {
                return first.boundingBox.midY > second.boundingBox.midY
            }
            return first.boundingBox.minX < second.boundingBox.minX
        }

        return orderedObservations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        .joined(separator: "\n")
    }
}

struct PDFTextExtraction {
    let pages: [PDFPageTextExtraction]

    var pageTexts: [String] {
        pages.map(\.text)
    }

    var documentText: String {
        pageTexts.joined(separator: "\n\n")
    }

    var pageCount: Int {
        pages.count
    }

    var ocrPageCount: Int {
        pages.filter { $0.method == .ocr }.count
    }
}

/// A parser's positive match score. Specific parsers receive higher scores than the
/// conservative generic fallback, so statement text is never handled by a giant switch.
struct StatementParserMatch: Comparable {
    let score: Int
    let priority: Int

    static let noMatch = StatementParserMatch(score: 0, priority: 0)

    static func < (lhs: StatementParserMatch, rhs: StatementParserMatch) -> Bool {
        if lhs.score == rhs.score {
            return lhs.priority < rhs.priority
        }
        return lhs.score < rhs.score
    }
}

/// A bank-specific parser owns both identity/account extraction and transaction extraction.
/// This prevents arbitrary PDF text from being treated as financial transactions.
protocol StatementParser {
    var identifier: String { get }

    func canParse(documentText: String) -> Bool
    func parserMatch(documentText: String) -> StatementParserMatch
    func extractIdentity(documentText: String) -> StatementIdentity?
    func extractAccountDetails(documentText: String) -> ExtractedAccountDetails?
    func extractTransactions(documentText: String) -> [ImportedTransactionCandidate]

    /// Compatibility name for existing callers while parsers move to capability methods.
    func parse(documentText: String) -> [ImportedTransactionCandidate]
}

extension StatementParser {
    func parserMatch(documentText: String) -> StatementParserMatch {
        canParse(documentText: documentText)
            ? StatementParserMatch(score: 50, priority: 50)
            : .noMatch
    }

    /// Parsers opt in only when they can safely identify account-level statement metadata.
    func extractIdentity(documentText: String) -> StatementIdentity? {
        nil
    }

    func extractAccountDetails(documentText: String) -> ExtractedAccountDetails? {
        nil
    }

    func extractTransactions(documentText: String) -> [ImportedTransactionCandidate] {
        []
    }

    func parse(documentText: String) -> [ImportedTransactionCandidate] {
        extractTransactions(documentText: documentText)
    }
}

/// The generic fallback only reads values with explicit labels through
/// StatementAccountDetailsExtractor. It never infers transactions or financial values
/// from an unlabelled number.
struct GenericStatementParser: StatementParser {
    let identifier = "generic-conservative"
    private let accountDetailsExtractor: StatementAccountDetailsExtractor

    init(accountDetailsExtractor: StatementAccountDetailsExtractor = StatementAccountDetailsExtractor()) {
        self.accountDetailsExtractor = accountDetailsExtractor
    }

    func canParse(documentText: String) -> Bool {
        !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func parserMatch(documentText: String) -> StatementParserMatch {
        canParse(documentText: documentText)
            ? StatementParserMatch(score: 1, priority: 0)
            : .noMatch
    }

    func extractIdentity(documentText: String) -> StatementIdentity? {
        accountDetailsExtractor.extractIdentity(documentText: documentText)
    }

    func extractAccountDetails(documentText: String) -> ExtractedAccountDetails? {
        accountDetailsExtractor.extract(documentText: documentText)
    }

    func extractTransactions(documentText: String) -> [ImportedTransactionCandidate] {
        []
    }
}

struct StatementImportPreparation {
    let textExtraction: PDFTextExtraction
    let matchedParserIdentifier: String?
    let candidates: [ImportedTransactionCandidate]
    /// Proposed account metadata to be shown in a future create/update review screen.
    /// It is never written to SwiftData during extraction.
    let extractedAccountDetails: ExtractedAccountDetails?
}

enum PDFStatementImportError: LocalizedError {
    case passwordProtected
    case corruptedDocument
    case noMachineReadableText
    case pageCouldNotBeRead(pageNumber: Int)
    case failedImport

    var errorDescription: String? {
        switch self {
        case .passwordProtected:
            "This PDF is password-protected. Remove the password before importing it."
        case .corruptedDocument:
            "This PDF could not be opened. It may be corrupted or incomplete."
        case .noMachineReadableText:
            "This PDF has no readable text. On-device OCR could not recover the statement text."
        case .pageCouldNotBeRead(let pageNumber):
            "Page \(pageNumber) could not be read as embedded text or with on-device OCR. Import was stopped to avoid incomplete financial data."
        case .failedImport:
            "The PDF statement could not be imported."
        }
    }
}

/// Coordinates the PDF pipeline. There are deliberately no generic parsers:
/// specialised parsers must explicitly opt in by recognising their own statement format.
struct StatementImportService {
    private let textExtractor: PDFTextExtractor
    private let parsers: [any StatementParser]

    init(
        textExtractor: PDFTextExtractor = PDFTextExtractor(),
        accountDetailsExtractor: StatementAccountDetailsExtractor = StatementAccountDetailsExtractor(),
        parsers: [any StatementParser] = [AmericanExpressStatementParser()]
    ) {
        self.textExtractor = textExtractor
        self.parsers = parsers + [GenericStatementParser(accountDetailsExtractor: accountDetailsExtractor)]
    }

    func prepareImport(at url: URL) async throws -> StatementImportPreparation {
        do {
            let textExtraction = try await textExtractor.extractText(at: url)
            let parser = selectedParser(for: textExtraction.documentText)

            return StatementImportPreparation(
                textExtraction: textExtraction,
                matchedParserIdentifier: parser?.identifier,
                candidates: parser?.extractTransactions(documentText: textExtraction.documentText) ?? [],
                extractedAccountDetails: parser?.extractAccountDetails(documentText: textExtraction.documentText)
            )
        } catch let error as PDFStatementImportError {
            throw error
        } catch {
            throw PDFStatementImportError.failedImport
        }
    }

    func parserIdentifier(for documentText: String) -> String? {
        selectedParser(for: documentText)?.identifier
    }

    private func selectedParser(for documentText: String) -> (any StatementParser)? {
        var selected: (parser: any StatementParser, match: StatementParserMatch)?
        for parser in parsers {
            let match = parser.parserMatch(documentText: documentText)
            guard match > .noMatch else { continue }
            if let selected, match <= selected.match {
                continue
            }
            selected = (parser, match)
        }
        return selected?.parser
    }
}

struct AmericanExpressStatementAnalysis {
    let accountIdentifier: String?
    let statementStartDate: Date?
    let statementEndDate: Date?
    let candidates: [ImportedTransactionCandidate]
}

/// Parses the predictable dated transaction blocks in Australian American Express statements.
/// It intentionally only activates after identifying Amex-specific statement markers.
struct AmericanExpressStatementParser: StatementParser {
    let identifier = "american-express-australia"

    func canParse(documentText: String) -> Bool {
        let normalizedText = normalizedWhitespace(in: documentText).lowercased()
        return normalizedText.contains("american express") &&
            normalizedText.contains("statement of account") &&
            normalizedText.contains("new transactions for")
    }

    /// Account detail extraction does not require a transaction section, while the legacy
    /// transaction parser still uses canParse's stricter marker set.
    func parserMatch(documentText: String) -> StatementParserMatch {
        let normalizedText = normalizedWhitespace(in: documentText).lowercased()
        return normalizedText.contains("american express") &&
            normalizedText.contains("statement of account")
            ? StatementParserMatch(score: 100, priority: 100)
            : .noMatch
    }

    func parse(documentText: String) -> [ImportedTransactionCandidate] {
        extractTransactions(documentText: documentText)
    }

    func extractIdentity(documentText: String) -> StatementIdentity? {
        AmericanExpressAccountDetailsExtractor().extractIdentity(documentText: documentText)
    }

    func extractAccountDetails(documentText: String) -> ExtractedAccountDetails? {
        AmericanExpressAccountDetailsExtractor().extractAccountDetails(documentText: documentText)
    }

    func extractTransactions(documentText: String) -> [ImportedTransactionCandidate] {
        guard canParse(documentText: documentText) else {
            return []
        }
        return analyse(documentText: documentText).candidates
    }

    func analyse(documentText: String) -> AmericanExpressStatementAnalysis {
        let statementEndDate = statementEndDate(in: documentText)
        let statementStartDate = statementStartDate(in: documentText, endDate: statementEndDate)
        let accountIdentifier = accountIdentifier(in: documentText)
        let records = transactionRecords(in: documentText)

        let candidates = records.compactMap { record in
            makeCandidate(
                from: record,
                statementEndDate: statementEndDate,
                accountIdentifier: accountIdentifier
            )
        }

        return AmericanExpressStatementAnalysis(
            accountIdentifier: accountIdentifier,
            statementStartDate: statementStartDate,
            statementEndDate: statementEndDate,
            candidates: candidates
        )
    }

    private func transactionRecords(in documentText: String) -> [[String]] {
        let lines = documentText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var records: [[String]] = []
        var currentRecord: [String] = []

        for line in lines {
            if isTransactionStart(line) {
                if !currentRecord.isEmpty {
                    records.append(currentRecord)
                }
                currentRecord = [line]
            } else if !currentRecord.isEmpty {
                currentRecord.append(line)
            }
        }

        if !currentRecord.isEmpty {
            records.append(currentRecord)
        }

        return records
    }

    private func makeCandidate(
        from record: [String],
        statementEndDate: Date?,
        accountIdentifier: String?
    ) -> ImportedTransactionCandidate? {
        guard
            let firstLine = record.first,
            let dateParts = transactionDateParts(in: firstLine),
            let date = transactionDate(from: dateParts, statementEndDate: statementEndDate),
            let amountMatch = firstAmount(in: record)
        else {
            return nil
        }

        let description = transactionDescription(
            from: record,
            amountLineIndex: amountMatch.lineIndex,
            amountRange: amountMatch.amountRange
        )
        guard !description.isEmpty else {
            return nil
        }

        let amount = amountMatch.isCredit ? amountMatch.amount : -amountMatch.amount
        let sourceText = record.joined(separator: " ")
        let importIdentifier = [
            "amex",
            accountIdentifier ?? "unknown-account",
            String(date.timeIntervalSince1970),
            description.lowercased(),
            amount.description
        ].joined(separator: "|")

        return ImportedTransactionCandidate(
            date: date,
            description: description,
            amount: amount,
            sourceText: sourceText,
            confidence: .medium,
            status: .needsReview,
            importIdentifier: importIdentifier
        )
    }

    private func isTransactionStart(_ line: String) -> Bool {
        transactionDateParts(in: line) != nil
    }

    private func transactionDateParts(in line: String) -> (month: String, day: Int, description: String)? {
        guard let match = match(
            pattern: "^(January|February|March|April|May|June|July|August|September|October|November|December)\\s+(\\d{1,2})\\s+(.+)$",
            in: line
        ),
        let day = Int(match[2]),
        !match[3].hasPrefix(",")
        else {
            return nil
        }

        return (match[1], day, match[3])
    }

    private func firstAmount(in record: [String]) -> (lineIndex: Int, amountRange: Range<String.Index>, amount: Decimal, isCredit: Bool)? {
        for (lineIndex, line) in record.enumerated() {
            guard let match = matchWithRange(
                pattern: "(?:^|\\s)([0-9][0-9,]*\\.[0-9]{2})\\s*(CR)?\\s*$",
                in: line,
                captureGroup: 1
            ),
            let amount = Decimal(
                string: String(line[match]).replacingOccurrences(of: ",", with: ""),
                locale: Locale(identifier: "en_US_POSIX")
            )
            else {
                continue
            }

            let isCredit = line.uppercased().contains("CR") ||
                record.dropFirst(lineIndex + 1).contains { $0.uppercased() == "CR" }
            return (lineIndex, match, amount, isCredit)
        }
        return nil
    }

    private func transactionDescription(
        from record: [String],
        amountLineIndex: Int,
        amountRange: Range<String.Index>
    ) -> String {
        var descriptionLines: [String] = []

        for index in 0...amountLineIndex {
            var line = record[index]
            if index == amountLineIndex {
                line.removeSubrange(amountRange)
            }
            if index == 0, let parts = transactionDateParts(in: line) {
                line = parts.description
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLine.isEmpty && !isTransactionMetadata(trimmedLine) {
                descriptionLines.append(trimmedLine)
            }
        }

        return normalizedWhitespace(in: descriptionLines.joined(separator: " "))
    }

    private func isTransactionMetadata(_ line: String) -> Bool {
        let normalizedLine = line.uppercased()
        return normalizedLine == "CR" ||
            normalizedLine.hasPrefix("REFERENCE:") ||
            normalizedLine.hasPrefix("ARRIVE DATE:") ||
            normalizedLine.hasPrefix("DEPART DATE:")
    }

    private func accountIdentifier(in documentText: String) -> String? {
        match(
            pattern: "(?:Membership Number|Card Number)\\s*([Xx0-9]{4}-[Xx0-9]{4,}-[Xx0-9]{4,})",
            in: normalizedWhitespace(in: documentText)
        )?[1]
    }

    private func statementStartDate(in documentText: String, endDate: Date?) -> Date? {
        guard let match = match(
            pattern: "Statement\\s+Period\\s+From\\s+([A-Za-z]+\\s+\\d{1,2})\\s+to\\s+([A-Za-z]+\\s+\\d{1,2},\\s+\\d{4})",
            in: normalizedWhitespace(in: documentText)
        ) else {
            return nil
        }

        let endYear = Calendar(identifier: .gregorian).component(.year, from: endDate ?? .now)
        let endMonth = Calendar(identifier: .gregorian).component(.month, from: endDate ?? .now)
        let startMonth = monthNumber(named: match[1].components(separatedBy: " ").first ?? "") ?? endMonth
        let startYear = startMonth > endMonth ? endYear - 1 : endYear
        return parseDate("\(match[1]) \(startYear)")
    }

    private func statementEndDate(in documentText: String) -> Date? {
        guard let match = match(
            pattern: "Statement\\s+Period\\s+From\\s+[A-Za-z]+\\s+\\d{1,2}\\s+to\\s+([A-Za-z]+\\s+\\d{1,2},\\s+\\d{4})",
            in: normalizedWhitespace(in: documentText)
        ) else {
            return nil
        }
        return parseDate(match[1])
    }

    private func transactionDate(
        from parts: (month: String, day: Int, description: String),
        statementEndDate: Date?
    ) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let endDate = statementEndDate ?? .now
        let endYear = calendar.component(.year, from: endDate)
        let endMonth = calendar.component(.month, from: endDate)
        let month = monthNumber(named: parts.month) ?? endMonth
        let year = month > endMonth ? endYear - 1 : endYear
        return parseDate("\(parts.month) \(parts.day) \(year)")
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MMMM d yyyy"
        return formatter.date(from: value.replacingOccurrences(of: ",", with: ""))
    }

    private func monthNumber(named month: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.monthSymbols.firstIndex { $0.caseInsensitiveCompare(month) == .orderedSame }.map { $0 + 1 }
    }

    private func normalizedWhitespace(in text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func match(pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let result = expression.firstMatch(in: value, range: range) else {
            return nil
        }
        return (0..<result.numberOfRanges).compactMap { index in
            guard let range = Range(result.range(at: index), in: value) else {
                return nil
            }
            return String(value[range])
        }
    }

    private func matchWithRange(
        pattern: String,
        in value: String,
        captureGroup: Int
    ) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let searchRange = NSRange(value.startIndex..., in: value)
        guard
            let result = expression.firstMatch(in: value, range: searchRange),
            let range = Range(result.range(at: captureGroup), in: value)
        else {
            return nil
        }
        return range
    }
}

struct CSVTransactionParser {
    func analyse(_ fileContents: String) throws -> CSVAnalysis {
        let delimiter = detectDelimiter(in: fileContents)
        let rows = CSVReader.parse(fileContents, delimiter: delimiter)
            .filter { row in !row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

        guard let rawHeaders = rows.first, !rawHeaders.isEmpty else {
            throw ImportServiceError.missingHeader
        }

        let headers = rawHeaders.enumerated().map { index, value in
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? "Column \(index + 1)" : trimmedValue
        }
        let suggestedMapping = suggestMapping(for: headers)

        return CSVAnalysis(
            headers: headers,
            rows: Array(rows.dropFirst()),
            suggestedMapping: suggestedMapping,
            requiresManualMapping: !suggestedMapping.hasRequiredColumns
        )
    }

    func makeCandidates(
        from analysis: CSVAnalysis,
        mapping: CSVColumnMapping,
        selectedAccountID: UUID? = nil
    ) throws -> CSVParseResult {
        guard mapping.hasRequiredColumns else {
            throw ImportServiceError.invalidMapping
        }

        var candidates: [ImportedTransactionCandidate] = []
        var skippedRowCount = 0

        for row in analysis.rows {
            guard
                let dateText = value(in: row, at: mapping.dateColumn),
                let date = CSVDateParser.parse(dateText),
                let description = value(in: row, at: mapping.descriptionColumn),
                !description.isEmpty,
                let amount = amount(in: row, mapping: mapping)
            else {
                skippedRowCount += 1
                continue
            }

            let balance = value(in: row, at: mapping.balanceColumn).flatMap(CSVAmountParser.parse)
            let confidence: ImportCandidateConfidence = mapping.amountColumn == nil ? .medium : .high
            let status: ImportCandidateStatus = confidence == .high ? .ready : .needsReview
            let identifier = "\(date.timeIntervalSince1970)|\(description.lowercased())|\(amount)"

            candidates.append(
                ImportedTransactionCandidate(
                    date: date,
                    description: description,
                    amount: amount,
                    balance: balance,
                    sourceText: row.joined(separator: " | "),
                    confidence: confidence,
                    status: status,
                    selectedAccountID: selectedAccountID,
                    importIdentifier: identifier
                )
            )
        }

        return CSVParseResult(candidates: candidates, skippedRowCount: skippedRowCount)
    }

    private func suggestMapping(for headers: [String]) -> CSVColumnMapping {
        var mapping = CSVColumnMapping()

        for (index, header) in headers.enumerated() {
            let normalisedHeader = header
                .lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")

            if mapping.dateColumn == nil,
               containsAny(normalisedHeader, terms: ["date", "transaction date", "posted"]) {
                mapping.dateColumn = index
            } else if mapping.descriptionColumn == nil,
                      containsAny(normalisedHeader, terms: ["description", "narration", "details", "merchant", "memo", "particulars"]) {
                mapping.descriptionColumn = index
            } else if mapping.debitColumn == nil,
                      containsAny(normalisedHeader, terms: ["debit", "withdrawal", "money out", "spent"]) {
                mapping.debitColumn = index
            } else if mapping.creditColumn == nil,
                      containsAny(normalisedHeader, terms: ["credit", "deposit", "money in", "received"]) {
                mapping.creditColumn = index
            } else if mapping.amountColumn == nil,
                      containsAny(normalisedHeader, terms: ["amount", "value", "transaction amount"]) {
                mapping.amountColumn = index
            } else if mapping.balanceColumn == nil,
                      containsAny(normalisedHeader, terms: ["balance", "running balance", "available balance"]) {
                mapping.balanceColumn = index
            }
        }

        return mapping
    }

    private func amount(in row: [String], mapping: CSVColumnMapping) -> Decimal? {
        if let amount = value(in: row, at: mapping.amountColumn).flatMap(CSVAmountParser.parse) {
            return amount
        }

        let debit = value(in: row, at: mapping.debitColumn).flatMap(CSVAmountParser.parse)
        let credit = value(in: row, at: mapping.creditColumn).flatMap(CSVAmountParser.parse)

        if let debit, debit != 0 {
            return -abs(debit)
        }
        if let credit, credit != 0 {
            return abs(credit)
        }
        return nil
    }

    private func value(in row: [String], at index: Int?) -> String? {
        guard let index, row.indices.contains(index) else {
            return nil
        }

        let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func containsAny(_ value: String, terms: [String]) -> Bool {
        terms.contains { value.contains($0) }
    }

    private func abs(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }

    private func detectDelimiter(in fileContents: String) -> Character {
        let firstLine = fileContents.split(whereSeparator: \.isNewline).first ?? ""
        let commaCount = firstLine.filter { $0 == "," }.count
        let semicolonCount = firstLine.filter { $0 == ";" }.count
        return semicolonCount > commaCount ? ";" : ","
    }
}

enum CSVDateParser {
    nonisolated static var formats: [String] {
        ["dd/MM/yyyy", "d/MM/yyyy", "yyyy-MM-dd"]
    }

    nonisolated static func parse(_ value: String) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format

            if let date = formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date
            }
        }
        return nil
    }
}

enum CSVAmountParser {
    nonisolated static func parse(_ value: String) -> Decimal? {
        var text = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let isNegative = text.hasPrefix("(") && text.hasSuffix(")") || text.contains(" DR")
        text = text
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "CR", with: "")
            .replacingOccurrences(of: "DR", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard var amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }

        if isNegative, amount > 0 {
            amount = -amount
        }
        return amount
    }
}

private enum CSVReader {
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character == "\"" {
                let nextIndex = text.index(after: index)
                if isInsideQuotes, nextIndex < text.endIndex, text[nextIndex] == "\"" {
                    field.append("\"")
                    index = text.index(after: nextIndex)
                    continue
                }
                isInsideQuotes.toggle()
            } else if character == delimiter, !isInsideQuotes {
                row.append(field)
                field = ""
            } else if character == "\n", !isInsideQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }

            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows
    }
}

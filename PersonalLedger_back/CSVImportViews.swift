import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TransactionsView: View {
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \Category.name) private var categories: [Category]

    @State private var isCSVImportPresented = false
    @State private var isPDFImportPresented = false
    @State private var selectedAccountID: UUID?
    @State private var selectedCategoryID: UUID?
    @State private var selectedPeriod = TransactionPeriod.allTime
    @State private var searchText = ""
    @State private var importCompletionMessage: String?

    private var filteredTransactions: [Transaction] {
        let startOfMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .distantPast

        return transactions.filter { transaction in
            let matchesAccount = selectedAccountID == nil || transaction.account?.id == selectedAccountID
            let matchesCategory = selectedCategoryID == nil || transaction.category?.id == selectedCategoryID
            let matchesPeriod = selectedPeriod == .allTime || transaction.transactionDate >= startOfMonth
            let matchesSearch = searchText.isEmpty || transaction.merchantDescription.localizedCaseInsensitiveContains(searchText)
            return matchesAccount && matchesCategory && matchesPeriod && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredTransactions.isEmpty {
                    ContentUnavailableView(
                        transactions.isEmpty ? "No transactions yet" : "No matching transactions",
                        systemImage: "list.bullet.rectangle",
                        description: Text(transactions.isEmpty ? "Import a statement to begin reviewing your spending." : "Try changing the account, category, or date filters.")
                    )
                } else {
                    List(filteredTransactions) { transaction in
                        TransactionListRow(transaction: transaction, showsAccount: true)
                    }
                }
            }
            .navigationTitle("Transactions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isCSVImportPresented = true
                        } label: {
                            Label("Import CSV", systemImage: "tablecells")
                        }

                        Button {
                            isPDFImportPresented = true
                        } label: {
                            Label("Import PDF statement", systemImage: "doc.text")
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Account", selection: $selectedAccountID) {
                            Text("All accounts").tag(UUID?.none)
                            ForEach(accounts.filter { !$0.isArchived }) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }

                        Picker("Category", selection: $selectedCategoryID) {
                            Text("All categories").tag(UUID?.none)
                            ForEach(categories) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }

                        Picker("Date", selection: $selectedPeriod) {
                            ForEach(TransactionPeriod.allCases) { period in
                                Text(period.title).tag(period)
                            }
                        }
                    } label: {
                        Label("Filter transactions", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $isCSVImportPresented) {
                CSVImportFlowView { message in
                    importCompletionMessage = message
                }
            }
            .sheet(isPresented: $isPDFImportPresented) {
                PDFImportFlowView()
            }
            .searchable(text: $searchText, prompt: "Search transactions")
            .alert("Import complete", isPresented: Binding(
                get: { importCompletionMessage != nil },
                set: { if !$0 { importCompletionMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importCompletionMessage ?? "")
            }
        }
    }
}

private enum TransactionPeriod: String, CaseIterable, Identifiable {
    case allTime
    case thisMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTime:
            "All time"
        case .thisMonth:
            "This month"
        }
    }
}

struct TransactionListRow: View {
    let transaction: Transaction
    let showsAccount: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantDescription)
                    .font(.body.weight(.medium))
                Text(transaction.transactionDate, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showsAccount {
                    Text([transaction.account?.name, transaction.category?.name]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let categoryName = transaction.category?.name {
                    Text(categoryName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(transaction.amount, format: .currency(code: transaction.account?.currency ?? "AUD"))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PDFImportFlowView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isFilePickerPresented = false
    @State private var isExtracting = false
    @State private var preparation: StatementImportPreparation?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isExtracting {
                    ProgressView("Extracting PDF text…")
                } else if let preparation {
                    PDFTextDebugPreview(preparation: preparation)
                } else {
                    PDFFileSelectionView {
                        isFilePickerPresented = true
                    }
                }
            }
            .navigationTitle("Import PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $isFilePickerPresented,
                allowedContentTypes: [.pdf]
            ) { result in
                handleFileSelection(result)
            }
            .alert("Import couldn't continue", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func handleFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            isExtracting = true
            Task {
                do {
                    preparation = try await StatementImportService().prepareImport(at: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isExtracting = false
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

private struct PDFFileSelectionView: View {
    let selectFile: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Choose a PDF statement", systemImage: "doc.text")
        } description: {
            Text("The statement remains on this device. This first version extracts text only and will not create transactions.")
        } actions: {
            Button("Select PDF file", action: selectFile)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct PDFTextDebugPreview: View {
    let preparation: StatementImportPreparation

    var body: some View {
        List {
            Section {
                Label("Text extracted from \(preparation.textExtraction.pageCount) page(s).", systemImage: "checkmark.circle")

                if preparation.textExtraction.ocrPageCount > 0 {
                    Label("On-device OCR was used for \(preparation.textExtraction.ocrPageCount) page(s).", systemImage: "text.viewfinder")
                }

                if let matchedParserIdentifier = preparation.matchedParserIdentifier {
                    Text("Recognised by \(matchedParserIdentifier). Parsed candidates will go through transaction review before any records are saved.")
                } else {
                    Text("No specialised statement parser matched this PDF. No transaction candidates or records were created.")
                }
            } header: {
                Text("Import status")
            }

            Section {
                Text(preparation.textExtraction.documentText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Developer preview")
            } footer: {
                Text("PDF → text extraction → statement identification → parser → review → transaction. Transaction recognition is intentionally not enabled yet.")
            }
        }
    }
}

private struct CSVImportFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var existingTransactions: [Transaction]

    @State private var isFilePickerPresented = false
    @State private var isAnalysing = false
    @State private var analysis: CSVAnalysis?
    @State private var mapping = CSVColumnMapping()
    @State private var candidates: [ImportedTransactionCandidate] = []
    @State private var selectedAccountID: UUID?
    @State private var bulkCategoryID: UUID?
    @State private var skippedRowCount = 0
    @State private var errorMessage: String?

    let onCompletion: (String) -> Void

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived }
    }

    private var includedCandidates: [ImportedTransactionCandidate] {
        candidates.filter(\.isIncluded)
    }

    private var canConfirm: Bool {
        !includedCandidates.isEmpty && includedCandidates.allSatisfy { $0.selectedAccountID != nil }
    }

    private var duplicateCount: Int {
        candidates.filter { $0.status == .potentialDuplicate }.count
    }

    private var uncategorisedCount: Int {
        includedCandidates.filter { $0.proposedCategoryID == nil }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if isAnalysing {
                    ProgressView("Analysing CSV…")
                } else if let analysis, analysis.requiresManualMapping, candidates.isEmpty {
                    CSVColumnMappingView(
                        analysis: analysis,
                        mapping: $mapping,
                        onContinue: makeCandidates
                    )
                } else if !candidates.isEmpty {
                    importReview
                } else {
                    fileSelection
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(candidates.isEmpty ? "Cancel" : "Start over") {
                        if candidates.isEmpty {
                            dismiss()
                        } else {
                            resetImport()
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $isFilePickerPresented,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) { result in
                handleFileSelection(result)
            }
            .alert("Import couldn't continue", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var fileSelection: some View {
        ContentUnavailableView {
            Label("Choose a CSV statement", systemImage: "tablecells")
        } description: {
            Text("The file stays on this device while you map columns and review every transaction.")
        } actions: {
            Button("Select CSV file") {
                isFilePickerPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var importReview: some View {
        List {
            Section {
                Picker("Import into", selection: $selectedAccountID) {
                    Text("Choose an account").tag(UUID?.none)
                    ForEach(activeAccounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }

                if skippedRowCount > 0 {
                    Label(
                        "\(skippedRowCount) row(s) were skipped because a date, description, or amount could not be read.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Destination")
            } footer: {
                Text("Potential duplicates are excluded initially but can be included after you check them.")
            }

            Section("Import summary") {
                LabeledContent("Read", value: candidates.count, format: .number)
                LabeledContent("Will import", value: includedCandidates.count, format: .number)
                if duplicateCount > 0 {
                    Label("\(duplicateCount) potential duplicate(s) excluded", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if uncategorisedCount > 0 {
                    Label("\(uncategorisedCount) transaction(s) need a category", systemImage: "tag")
                        .foregroundStyle(.secondary)
                }
            }

            if uncategorisedCount > 0 {
                Section {
                    Picker("Set category for uncategorised", selection: $bulkCategoryID) {
                        Text("Choose a category").tag(UUID?.none)
                        ForEach(categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                } header: {
                    Text("Categorise remaining")
                } footer: {
                    Text("This only changes rows that do not already have a suggested category.")
                }
            }

            Section("Review \(candidates.count) transaction(s)") {
                ForEach($candidates) { $candidate in
                    ImportedTransactionReviewRow(
                        candidate: $candidate,
                        categories: categories,
                        isPotentialDuplicate: isPotentialDuplicate(candidate)
                    )
                }
            }
        }
        .onChange(of: selectedAccountID) { _, newAccountID in
            for index in candidates.indices {
                candidates[index].selectedAccountID = newAccountID
            }
            applyDuplicateRecommendations()
        }
        .onChange(of: bulkCategoryID) { _, newCategoryID in
            guard let newCategoryID else {
                return
            }
            for index in candidates.indices where candidates[index].proposedCategoryID == nil {
                candidates[index].proposedCategoryID = newCategoryID
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                confirmImport()
            } label: {
                Text("Import \(includedCandidates.count) transaction(s)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.bar)
            .disabled(!canConfirm)
        }
    }

    private var navigationTitle: String {
        if !candidates.isEmpty {
            "Review import"
        } else if analysis?.requiresManualMapping == true {
            "Map columns"
        } else {
            "Import CSV"
        }
    }

    private func handleFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            isAnalysing = true
            Task {
                do {
                    let analysedCSV = try await ImportService().analyseCSV(at: url)
                    analysis = analysedCSV
                    mapping = analysedCSV.suggestedMapping

                    if !analysedCSV.requiresManualMapping {
                        makeCandidates()
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
                isAnalysing = false
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func makeCandidates() {
        guard let analysis else {
            return
        }

        do {
            let result = try ImportService().makeCandidates(
                from: analysis,
                mapping: mapping,
                selectedAccountID: selectedAccountID
            )
            var parsedCandidates = result.candidates
            let categorySuggestions = try MerchantCategoryRuleService.suggestions(in: modelContext)
            for index in parsedCandidates.indices {
                let merchantKey = MerchantCategoryRuleService.normalizedMerchantKey(for: parsedCandidates[index].description)
                parsedCandidates[index].proposedCategoryID = categorySuggestions[merchantKey]
            }
            candidates = parsedCandidates
            skippedRowCount = result.skippedRowCount
            applyDuplicateRecommendations()

            if candidates.isEmpty {
                errorMessage = "No transactions could be read with this column mapping."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isPotentialDuplicate(_ candidate: ImportedTransactionCandidate) -> Bool {
        guard let accountID = candidate.selectedAccountID else {
            return false
        }

        return existingTransactions.contains { transaction in
            transaction.account?.id == accountID &&
            (transaction.importIdentifier == candidate.importIdentifier ||
                (transaction.amount == candidate.amount &&
                 transaction.merchantDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(candidate.description.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame &&
                 abs(transaction.transactionDate.timeIntervalSince(candidate.date)) < 86_400))
        }
    }

    private func applyDuplicateRecommendations() {
        for index in candidates.indices where isPotentialDuplicate(candidates[index]) {
            candidates[index].status = .potentialDuplicate
            candidates[index].isIncluded = false
        }
    }

    private func confirmImport() {
        let importedCount = includedCandidates.count
        for candidate in includedCandidates {
            guard let account = accounts.first(where: { $0.id == candidate.selectedAccountID }) else {
                continue
            }

            let category = categories.first { $0.id == candidate.proposedCategoryID }
            let transaction = Transaction(
                transactionDate: candidate.date,
                merchantDescription: candidate.description,
                amount: candidate.amount,
                transactionType: TransactionImportClassifier.transactionType(for: candidate),
                category: category,
                account: account,
                source: .csvImport,
                importIdentifier: candidate.importIdentifier
            )
            modelContext.insert(transaction)

            if let category {
                try? MerchantCategoryRuleService.rememberCategory(
                    for: candidate.description,
                    category: category,
                    in: modelContext
                )
            }
        }

        do {
            try modelContext.save()
            dismiss()
            let duplicateMessage = duplicateCount > 0 ? " \(duplicateCount) potential duplicate(s) were left out." : ""
            let categoryMessage = uncategorisedCount > 0 ? " \(uncategorisedCount) imported transaction(s) remain uncategorised." : ""
            onCompletion("Imported \(importedCount) transaction(s).\(duplicateMessage)\(categoryMessage)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetImport() {
        analysis = nil
        mapping = CSVColumnMapping()
        candidates = []
        selectedAccountID = nil
        bulkCategoryID = nil
        skippedRowCount = 0
    }
}

private struct CSVColumnMappingView: View {
    let analysis: CSVAnalysis
    @Binding var mapping: CSVColumnMapping
    let onContinue: () -> Void

    var body: some View {
        Form {
            Section {
                Text("We couldn't confidently identify every required field. Confirm the columns before continuing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("CSV columns") {
                ForEach(CSVColumnRole.allCases) { role in
                    Picker(role.title, selection: columnBinding(for: role)) {
                        Text("Not used").tag(Int?.none)
                        ForEach(analysis.headers.indices, id: \.self) { index in
                            Text(analysis.headers[index]).tag(Optional(index))
                        }
                    }
                }
            }

            Section {
                Button("Preview transactions", action: onContinue)
                    .frame(maxWidth: .infinity)
                    .disabled(!mapping.hasRequiredColumns)
            }
        }
    }

    private func columnBinding(for role: CSVColumnRole) -> Binding<Int?> {
        Binding(
            get: { mapping[role] },
            set: { mapping[role] = $0 }
        )
    }
}

private struct ImportedTransactionReviewRow: View {
    @Binding var candidate: ImportedTransactionCandidate
    let categories: [Category]
    let isPotentialDuplicate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Include", isOn: $candidate.isIncluded)
                .font(.subheadline.weight(.semibold))

            if candidate.isIncluded {
                TextField("Description", text: $candidate.description)

                DatePicker(
                    "Date",
                    selection: $candidate.date,
                    displayedComponents: .date
                )

                TextField("Amount", value: $candidate.amount, format: .number)
                    .keyboardType(.decimalPad)

                Picker("Category", selection: $candidate.proposedCategoryID) {
                    Text("No category").tag(UUID?.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }

                if isPotentialDuplicate {
                    Label("Potential duplicate", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                } else if candidate.status == .needsReview {
                    Label("Check this row", systemImage: "questionmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(candidate.sourceText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

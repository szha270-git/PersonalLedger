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

struct CSVImportFlowView: View {
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
    @State private var isBulkCategoryPickerPresented = false
    @State private var editingCandidate: ImportCandidateSelection?
    @State private var isCreatingDestinationAccount = false
    @State private var skippedRowCount = 0
    @State private var errorMessage: String?
    @AppStorage(TransactionAISettings.useAppleIntelligenceKey)
    private var usesAppleIntelligenceSuggestions = false
    @State private var aiEnrichmentState: TransactionAIEnrichmentRunState = .idle

    private let transactionEnricher = AppleFoundationModelTransactionEnricher()

    let onCompletion: (String) -> Void

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived }
    }

    private var includedCandidates: [ImportedTransactionCandidate] {
        candidates.filter(\.isIncluded)
    }

    private var canConfirm: Bool {
        ImportReviewService.canConfirmImport(candidates)
    }

    private var duplicateCount: Int {
        candidates.filter { $0.status == .potentialDuplicate }.count
    }

    private var uncategorisedCount: Int {
        includedCandidates.filter { $0.proposedCategoryID == nil }.count
    }

    private var reviewSummary: ImportReviewSummary {
        ImportReviewService.summary(for: candidates)
    }

    private var readyCandidates: [ImportedTransactionCandidate] {
        candidates.filter { ImportReviewService.state(for: $0) == .ready }
    }

    private var needsAttentionCandidates: [ImportedTransactionCandidate] {
        candidates.filter {
            if case .needsAttention = ImportReviewService.state(for: $0) {
                return true
            }
            return false
        }
    }

    private var selectedAccount: Account? {
        accounts.first { $0.id == selectedAccountID }
    }

    private var importedAccountSuggestion: ImportedAccountSuggestion? {
        analysis?.accountSuggestion
    }

    private var matchingDestinationAccounts: [Account] {
        ImportedAccountSuggestionService.exactMatches(
            for: importedAccountSuggestion,
            among: activeAccounts
        )
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
                if activeAccounts.isEmpty {
                    ContentUnavailableView {
                        Label("No account available", systemImage: "building.columns")
                    } description: {
                        Text("Create an account to import these transactions.")
                    } actions: {
                        Button("Create Account") {
                            isCreatingDestinationAccount = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Picker("Import into", selection: $selectedAccountID) {
                        Text("Choose an account").tag(UUID?.none)
                        ForEach(activeAccounts) { account in
                            Text(destinationAccountLabel(for: account)).tag(Optional(account.id))
                        }
                    }

                    if selectedAccountID == nil, importedAccountSuggestion != nil,
                       matchingDestinationAccounts.isEmpty {
                        Text("No matching account found")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("Create New Account…") {
                        isCreatingDestinationAccount = true
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
                Text("Import into")
            } footer: {
                if selectedAccountID == nil {
                    Text("Choose a destination account before importing. Transactions can still be inspected without selecting one.")
                } else {
                    Text("Potential duplicates remain excluded unless you explicitly include them after review.")
                }
            }

            Section("Import summary") {
                ImportSummaryView(summary: reviewSummary)

                if let message = aiEnrichmentState.reviewMessage {
                    Label(message, systemImage: "apple.intelligence")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if uncategorisedCount > 0 {
                Section {
                    Button("Categorise \(uncategorisedCount) uncategorised") {
                        isBulkCategoryPickerPresented = true
                    }
                }
                .confirmationDialog(
                    "Set a category for uncategorised transactions",
                    isPresented: $isBulkCategoryPickerPresented,
                    titleVisibility: .visible
                ) {
                    ForEach(categories) { category in
                        Button(category.name) {
                            bulkCategoryID = category.id
                        }
                    }
                } message: {
                    Text("This applies only to included transactions without a proposed category.")
                }
            }

            if !needsAttentionCandidates.isEmpty {
                Section("Needs Attention (\(needsAttentionCandidates.count))") {
                    ForEach(needsAttentionCandidates) { candidate in
                        NeedsAttentionImportTransactionRow(
                            candidate: candidate,
                            issue: reviewIssue(for: candidate),
                            categoryName: categoryName(for: candidate),
                            currencyCode: selectedAccount?.currency,
                            onEdit: { editingCandidate = ImportCandidateSelection(id: candidate.id) }
                        )
                    }
                }
            }

            Section("Ready to Import (\(readyCandidates.count))") {
                ForEach(readyCandidates) { candidate in
                    CompactImportTransactionRow(
                        candidate: candidate,
                        categoryName: categoryName(for: candidate),
                        currencyCode: selectedAccount?.currency,
                        hasAISuggestion: candidate.aiCategorySuggestion != nil || candidate.aiMerchantNameSuggestion != nil,
                        onEdit: { editingCandidate = ImportCandidateSelection(id: candidate.id) }
                    )
                }
            }
        }
        .onChange(of: selectedAccountID) { _, newAccountID in
            applyDestinationAccount(newAccountID)
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
        .sheet(item: $editingCandidate) { selection in
            if let index = candidates.firstIndex(where: { $0.id == selection.id }) {
                NavigationStack {
                    ImportTransactionEditView(
                        candidate: $candidates[index],
                        categories: categories
                    )
                    .navigationTitle("Edit transaction")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                editingCandidate = nil
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isCreatingDestinationAccount) {
            AccountEditorView(
                account: nil,
                prefill: importedAccountSuggestion,
                onSaved: selectNewDestinationAccount
            )
        }
        .onChange(of: editingCandidate) { _, newValue in
            if newValue == nil {
                applyDuplicateRecommendations()
            }
        }
        .task {
            TransactionAISettings.configureDefault(using: transactionEnricher.availability())
            beginAIEnrichmentIfNeeded()
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
            ImportCategorySuggestionService.applySuggestions(
                to: &parsedCandidates,
                merchantRuleSuggestions: categorySuggestions,
                categories: categories
            )
            #if DEBUG
            reportDeterministicCategoryDiagnostics(
                for: parsedCandidates,
                merchantRuleSuggestions: categorySuggestions
            )
            #endif
            candidates = parsedCandidates
            skippedRowCount = result.skippedRowCount
            if selectedAccountID == nil, matchingDestinationAccounts.count == 1,
               let matchingAccount = matchingDestinationAccounts.first {
                selectDestinationAccount(matchingAccount.id)
            } else {
                applyDuplicateRecommendations()
                beginAIEnrichmentIfNeeded()
            }

            if candidates.isEmpty {
                errorMessage = "No transactions could be read with this column mapping."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isPotentialDuplicate(_ candidate: ImportedTransactionCandidate) -> Bool {
        TransactionDuplicateDetector.isPotentialDuplicate(candidate, among: existingTransactions)
    }

    private func applyDuplicateRecommendations() {
        ImportReviewService.applyDuplicateRecommendations(
            to: &candidates,
            isPotentialDuplicate: isPotentialDuplicate
        )
    }

    private func selectNewDestinationAccount(_ account: Account) {
        selectDestinationAccount(account.id)
    }

    private func selectDestinationAccount(_ accountID: UUID?) {
        selectedAccountID = accountID
        applyDestinationAccount(accountID)
    }

    private func applyDestinationAccount(_ accountID: UUID?) {
        ImportDestinationAccountService.assign(
            accountID: accountID,
            to: &candidates
        )
        applyDuplicateRecommendations()
        beginAIEnrichmentIfNeeded()
    }

    private func destinationAccountLabel(for account: Account) -> String {
        guard let lastFourDigits = account.lastFourDigits, !lastFourDigits.isEmpty else {
            return account.name
        }
        return "\(account.name) •••• \(lastFourDigits)"
    }

    /// Parsing and deterministic category rules have already completed when this runs. The
    /// bounded, sequential requests keep the review screen responsive and never delay import.
    private func beginAIEnrichmentIfNeeded() {
        guard !candidates.isEmpty else {
            return
        }

        let availability = transactionEnricher.availability()
        TransactionAISettings.configureDefault(using: availability)

        guard usesAppleIntelligenceSuggestions else {
            aiEnrichmentState = .disabled
            return
        }
        guard availability.isAvailable else {
            for index in candidates.indices where TransactionAIEnrichmentPolicy.shouldRequest(for: candidates[index]) {
                candidates[index].aiEnrichmentState = .unavailable
            }
            aiEnrichmentState = .usingStandardCategorisation(
                availability.standardCategorisationMessage ?? "Apple Intelligence is unavailable — using standard categorisation."
            )
            return
        }

        var workItems: [(TransactionAIEnrichmentSnapshot, TransactionAIEnrichmentRequest)] = []
        for index in candidates.indices {
            guard TransactionAIEnrichmentPolicy.shouldRequest(for: candidates[index]) else {
                continue
            }

            candidates[index].aiEnrichmentState = .pending
            let candidate = candidates[index]
            workItems.append((
                TransactionAIEnrichmentSnapshot(candidate: candidate),
                TransactionAIEnrichmentRequest(
                    displayMerchantName: candidate.description,
                    originalBankDescription: candidate.originalBankDescription,
                    sourceCategorySuggestion: candidate.sourceCategorySuggestion,
                    transactionDirection: candidate.amount < 0 ? "outgoing" : "incoming",
                    allowedCategoryNames: categories.map(\.name),
                    allowsMerchantNameCleanup: TransactionAIEnrichmentPolicy.allowsMerchantNameCleanup(
                        for: candidate
                    )
                )
            ))
        }

        guard !workItems.isEmpty else {
            aiEnrichmentState = .completed(enriched: 0, considered: 0, failures: 0)
            return
        }

        aiEnrichmentState = .categorising(total: workItems.count)
        let categorySnapshot = categories

        Task {
            var enrichedCount = 0
            var failureCount = 0

            for (snapshot, request) in workItems {
                guard !Task.isCancelled else {
                    return
                }

                do {
                    let enrichment = try await transactionEnricher.enrich(request)
                    guard let index = candidates.firstIndex(where: { $0.id == snapshot.id }),
                          snapshot.matches(candidates[index])
                    else {
                        continue
                    }

                    if TransactionAIEnrichmentPolicy.apply(
                        enrichment,
                        to: &candidates[index],
                        categories: categorySnapshot
                    ) {
                        enrichedCount += 1
                    }
                } catch {
                    if let index = candidates.firstIndex(where: { $0.id == snapshot.id }),
                       snapshot.matches(candidates[index]) {
                        candidates[index].aiEnrichmentState = .failed
                    }
                    // The deterministic import path remains valid if one local model request fails.
                    failureCount += 1
                }
            }

            aiEnrichmentState = .completed(
                enriched: enrichedCount,
                considered: workItems.count,
                failures: failureCount
            )

            #if DEBUG
            let noSuggestionCount = workItems.count - enrichedCount - failureCount
            debugPrint(
                "AI enrichment summary: \(candidates.count) parsed; \(candidates.count - workItems.count) skipped because deterministic categorisation or validation applied; \(workItems.count) sent; \(enrichedCount) enriched; \(noSuggestionCount) no suggestion; \(failureCount) failed; 0 AI-caused review states."
            )
            reportFinalCategoryDiagnostics()
            #endif
        }
    }

    #if DEBUG
    /// Category-level diagnostics deliberately exclude merchant names and raw bank descriptions.
    private func reportDeterministicCategoryDiagnostics(
        for candidates: [ImportedTransactionCandidate],
        merchantRuleSuggestions: [String: UUID]
    ) {
        let availability = transactionEnricher.availability()
        for sourceCategory in Set(candidates.compactMap(\.sourceCategorySuggestion)).sorted() {
            let matchingCandidates = candidates.filter { $0.sourceCategorySuggestion == sourceCategory }
            let merchantRuleMatches = matchingCandidates.filter {
                let merchantKey = MerchantCategoryRuleService.normalizedMerchantKey(for: $0.description)
                return merchantRuleSuggestions[merchantKey] != nil
            }.count
            let deterministicMatches = matchingCandidates.filter { $0.proposedCategoryID != nil }.count
            let eligibleAfterAccountSelection = matchingCandidates.filter {
                $0.status == .ready &&
                    $0.proposedCategoryID == nil &&
                    !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            debugPrint(
                "Category diagnostic [\(sourceCategory)]: \(matchingCandidates.count) rows; \(merchantRuleMatches) merchant-rule matches; \(deterministicMatches) deterministic local matches; \(eligibleAfterAccountSelection) AI-eligible after account selection; model \(availability)."
            )
        }
    }

    private func reportFinalCategoryDiagnostics() {
        for sourceCategory in Set(candidates.compactMap(\.sourceCategorySuggestion)).sorted() {
            let matchingCandidates = candidates.filter { $0.sourceCategorySuggestion == sourceCategory }
            let aiEnriched = matchingCandidates.filter { $0.aiEnrichmentState == .enriched }.count
            let aiNoSuggestion = matchingCandidates.filter { $0.aiEnrichmentState == .noSuggestion }.count
            let aiUnavailable = matchingCandidates.filter { $0.aiEnrichmentState == .unavailable }.count
            let aiFailed = matchingCandidates.filter { $0.aiEnrichmentState == .failed }.count
            let finalCategories = matchingCandidates.filter { $0.proposedCategoryID != nil }.count
            debugPrint(
                "Category diagnostic [\(sourceCategory)]: AI enriched \(aiEnriched); no suggestion or invalid \(aiNoSuggestion); unavailable \(aiUnavailable); failed \(aiFailed); final local category IDs \(finalCategories)."
            )
        }
    }
    #endif

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
                originalBankDescription: candidate.originalBankDescription,
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

    private func reviewIssue(for candidate: ImportedTransactionCandidate) -> ImportTransactionReviewIssue {
        guard case let .needsAttention(issue) = ImportReviewService.state(for: candidate) else {
            return .parserNeedsReview
        }
        return issue
    }

    private func categoryName(for candidate: ImportedTransactionCandidate) -> String? {
        categories.first { $0.id == candidate.proposedCategoryID }?.name
    }

    private func resetImport() {
        analysis = nil
        mapping = CSVColumnMapping()
        candidates = []
        selectedAccountID = nil
        bulkCategoryID = nil
        skippedRowCount = 0
        aiEnrichmentState = .idle
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

private struct ImportCandidateSelection: Identifiable, Equatable {
    let id: UUID
}

private struct ImportSummaryView: View {
    let summary: ImportReviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Transactions recognised", value: summary.recognisedCount, format: .number)
            LabeledContent("Ready to import", value: summary.readyCount, format: .number)
            LabeledContent("Needs attention", value: summary.needsAttentionCount, format: .number)

            if summary.duplicateCount > 0 {
                Label(
                    "\(summary.duplicateCount) possible duplicate(s) excluded",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }

            if summary.uncategorisedCount > 0 {
                Label(
                    "\(summary.uncategorisedCount) uncategorised",
                    systemImage: "tag"
                )
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CompactImportTransactionRow: View {
    let candidate: ImportedTransactionCandidate
    let categoryName: String?
    let currencyCode: String?
    let hasAISuggestion: Bool
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.description)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if let categoryName {
                        Text(categoryName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Uncategorised")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if hasAISuggestion {
                        Text("Suggested by Apple Intelligence")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(candidate.date, format: .dateTime.day().month(.abbreviated))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    CandidateAmountText(amount: candidate.amount, currencyCode: currencyCode)
                    Label("Ready", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("\(candidate.description), ready to import")
        .accessibilityHint("Double-tap to inspect or edit this transaction")
    }
}

private struct NeedsAttentionImportTransactionRow: View {
    let candidate: ImportedTransactionCandidate
    let issue: ImportTransactionReviewIssue
    let categoryName: String?
    let currencyCode: String?
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.description)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    CandidateAmountText(amount: candidate.amount, currencyCode: currencyCode)
                }

                Label(issue.title, systemImage: issue == .potentialDuplicate ? "exclamationmark.triangle" : "exclamationmark.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)

                HStack(spacing: 4) {
                    Text(candidate.date, format: .dateTime.day().month(.abbreviated))
                    if let categoryName {
                        Text("•")
                        Text(categoryName)
                    }
                    if !candidate.isIncluded {
                        Text("•")
                        Text("Excluded")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("\(candidate.description), needs attention: \(issue.title)")
        .accessibilityHint("Double-tap to inspect and edit this transaction")
    }
}

private struct CandidateAmountText: View {
    let amount: Decimal
    let currencyCode: String?

    var body: some View {
        Group {
            if let currencyCode {
                Text(amount, format: .currency(code: currencyCode))
            } else {
                Text(amount, format: .number)
            }
        }
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
    }
}

private struct ImportTransactionEditView: View {
    @Binding var candidate: ImportedTransactionCandidate
    let categories: [Category]

    var body: some View {
        Form {
            Section {
                Toggle("Include in import", isOn: $candidate.isIncluded)
            }

            Section("Transaction") {
                TextField("Merchant or description", text: $candidate.description)
                DatePicker("Date", selection: $candidate.date, displayedComponents: .date)
                TextField("Amount", value: $candidate.amount, format: .number)
                    .keyboardType(.decimalPad)
                Picker("Category", selection: $candidate.proposedCategoryID) {
                    Text("No category").tag(UUID?.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
            }

            if let originalBankDescription = candidate.originalBankDescription,
               originalBankDescription.caseInsensitiveCompare(candidate.description) != .orderedSame {
                Section("Source information") {
                    LabeledContent("Original bank description", value: originalBankDescription)
                    if let sourceCategorySuggestion = candidate.sourceCategorySuggestion {
                        LabeledContent("Bank suggestion", value: sourceCategorySuggestion)
                    }
                    if let aiCategorySuggestion = candidate.aiCategorySuggestion {
                        LabeledContent("Apple Intelligence suggestion", value: aiCategorySuggestion)
                    }
                }
            } else if let sourceCategorySuggestion = candidate.sourceCategorySuggestion {
                Section("Source information") {
                    LabeledContent("Bank suggestion", value: sourceCategorySuggestion)
                    if let aiCategorySuggestion = candidate.aiCategorySuggestion {
                        LabeledContent("Apple Intelligence suggestion", value: aiCategorySuggestion)
                    }
                }
            } else if let aiCategorySuggestion = candidate.aiCategorySuggestion {
                Section("Source information") {
                    LabeledContent("Apple Intelligence suggestion", value: aiCategorySuggestion)
                }
            }
        }
    }
}

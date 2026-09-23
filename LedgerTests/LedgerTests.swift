import Foundation
import SwiftData
import Testing
@testable import Ledger

struct LedgerTests {
    @Test
    func parserDetectsCommonColumnsAndNormalisesDebitAndCredit() throws {
        let csv = """
        Date,Description,Debit,Credit,Balance
        01/09/2026,Coffee Shop,5.50,,994.50
        2026-09-02,Salary,,1200.00,2194.50
        """

        let parser = CSVTransactionParser()
        let analysis = try parser.analyse(csv)
        let result = try parser.makeCandidates(
            from: analysis,
            mapping: analysis.suggestedMapping
        )

        #expect(analysis.requiresManualMapping == false)
        #expect(result.candidates.count == 2)
        #expect(result.candidates[0].description == "Coffee Shop")
        #expect(result.candidates[0].amount == Decimal(string: "-5.50"))
        #expect(result.candidates[1].amount == Decimal(string: "1200.00"))
        #expect(result.candidates[1].balance == Decimal(string: "2194.50"))
    }

    @Test
    func parserSupportsDayMonthYearAndISODateFormats() throws {
        let csv = """
        Transaction Date,Narration,Amount
        2/09/2026,Groceries,-42.10
        2026-09-03,Transfer,100.00
        """

        let parser = CSVTransactionParser()
        let analysis = try parser.analyse(csv)
        let result = try parser.makeCandidates(
            from: analysis,
            mapping: analysis.suggestedMapping
        )

        #expect(result.candidates.count == 2)
        #expect(result.candidates[0].amount == Decimal(string: "-42.10"))
        #expect(result.candidates[1].amount == Decimal(string: "100.00"))
    }

    @Test
    func csvDateParserSupportsNABAndExistingDateFormats() throws {
        let calendar = Calendar(identifier: .gregorian)
        let dates = [
            ("15 Sep 26", 9, 15),
            ("07 Sep 26", 9, 7),
            ("24 Aug 26", 8, 24),
            ("15/09/2026", 9, 15),
            ("7/09/2026", 9, 7),
            ("2026-09-15", 9, 15)
        ]

        for (value, month, day) in dates {
            let parsedDate = try #require(CSVDateParser.parse(value))
            #expect(calendar.component(.year, from: parsedDate) == 2026)
            #expect(calendar.component(.month, from: parsedDate) == month)
            #expect(calendar.component(.day, from: parsedDate) == day)
        }
    }

    @Test
    func nabCSVImportPreservesMerchantIdentityAndCategorySuggestions() throws {
        // NAB exports use CRLF line endings and include an empty column after Account Number.
        let csv = [
            "Date,Amount,Account Number,,Transaction Type,Transaction Details,Balance,Category,Merchant Name,Processed On",
            "15 Sep 26,-80.00,XXXX1234,,Purchase,MYLACO PTY LTD BOONDALL,920.00,Pets,Brisbane Pet Motel,16 Sep 26",
            "07 Sep 26,-25.00,XXXX1234,,Purchase,Afterpay afterpay.com,895.00,Other shopping,,08 Sep 26",
            "24 Aug 26,100.00,XXXX1234,,Payment,CARD PAYMENT THANK YOU,995.00,Internal transfers,Credit Card Payment,25 Aug 26"
        ].joined(separator: "\r\n")

        let parser = CSVTransactionParser()
        let analysis = try parser.analyse(csv)
        let result = try parser.makeCandidates(from: analysis, mapping: analysis.suggestedMapping)

        #expect(analysis.requiresManualMapping == false)
        #expect(result.candidates.count == 3)
        #expect(result.candidates[0].description == "Brisbane Pet Motel")
        #expect(result.candidates[0].originalBankDescription == "MYLACO PTY LTD BOONDALL")
        #expect(result.candidates[0].sourceCategorySuggestion == "Pets")
        #expect(result.candidates[1].description == "Afterpay afterpay.com")
        #expect(result.candidates[1].originalBankDescription == "Afterpay afterpay.com")
        #expect(result.candidates[1].sourceCategorySuggestion == "Other shopping")
        #expect(result.candidates[0].amount < 0)
        #expect(TransactionImportClassifier.transactionType(for: result.candidates[0]) == .expense)
        #expect(TransactionImportClassifier.transactionType(for: result.candidates[2]) != .expense)

        let pets = Category(name: "Pets")
        let travel = Category(name: "Travel")
        var categoryCandidates = result.candidates
        ImportCategorySuggestionService.applySuggestions(
            to: &categoryCandidates,
            merchantRuleSuggestions: [:],
            categories: [pets, travel]
        )
        #expect(categoryCandidates[0].proposedCategoryID == pets.id)
        #expect(categoryCandidates[1].proposedCategoryID == nil)

        ImportCategorySuggestionService.applySuggestions(
            to: &categoryCandidates,
            merchantRuleSuggestions: [
                MerchantCategoryRuleService.normalizedMerchantKey(for: "Brisbane Pet Motel"): travel.id
            ],
            categories: [pets, travel]
        )
        #expect(categoryCandidates[0].proposedCategoryID == travel.id)

        let repeatedImport = try parser.makeCandidates(from: analysis, mapping: analysis.suggestedMapping)
        #expect(repeatedImport.candidates[0].importIdentifier == result.candidates[0].importIdentifier)

        let account = Account(name: "NAB Card", accountType: .creditCard, institutionName: "NAB")
        var duplicateCandidate = result.candidates[0]
        duplicateCandidate.selectedAccountID = account.id
        let existingTransaction = Transaction(
            transactionDate: duplicateCandidate.date,
            merchantDescription: duplicateCandidate.description,
            originalBankDescription: duplicateCandidate.originalBankDescription,
            amount: duplicateCandidate.amount,
            transactionType: .expense,
            account: account,
            source: .csvImport,
            importIdentifier: duplicateCandidate.importIdentifier
        )
        #expect(
            TransactionDuplicateDetector.isPotentialDuplicate(
                duplicateCandidate,
                among: [existingTransaction]
            )
        )
    }

    @Test
    func nabCSVProvidesOnlySafeDestinationAccountPrefill() throws {
        let csv = """
        Date,Amount,Account Number,Transaction Type,Transaction Details,Merchant Name
        15 Sep 26,-80.00,Card ending 6981,CREDIT CARD PURCHASE,RAW DESCRIPTION,Example Merchant
        """

        let analysis = try CSVTransactionParser().analyse(csv)
        #expect(analysis.accountSuggestion?.institutionName == "NAB")
        #expect(analysis.accountSuggestion?.suggestedName == "NAB Credit Card")
        #expect(analysis.accountSuggestion?.accountType == .creditCard)
        #expect(analysis.accountSuggestion?.lastFourDigits == "6981")
        #expect(analysis.accountSuggestion?.currency == nil)
    }

    @Test
    func destinationAccountMatchingIsExactAndDoesNotGuess() {
        let matching = Account(
            name: "NAB Credit Card",
            accountType: .creditCard,
            institutionName: "NAB",
            lastFourDigits: "6981"
        )
        let differentDigits = Account(
            name: "NAB Credit Card",
            accountType: .creditCard,
            institutionName: "NAB",
            lastFourDigits: "1234"
        )
        let differentInstitution = Account(
            name: "Other Card",
            accountType: .creditCard,
            institutionName: "Other Bank",
            lastFourDigits: "6981"
        )
        let suggestion = ImportedAccountSuggestion(
            institutionName: "nab",
            suggestedName: "NAB Credit Card",
            accountType: .creditCard,
            lastFourDigits: "6981",
            currency: nil
        )

        #expect(
            ImportedAccountSuggestionService.exactMatches(
                for: suggestion,
                among: [matching, differentDigits, differentInstitution]
            ).map(\.id) == [matching.id]
        )
        #expect(
            ImportedAccountSuggestionService.exactMatches(
                for: nil,
                among: [matching]
            ).isEmpty
        )
        #expect(
            ImportedAccountSuggestionService.exactMatches(
                for: suggestion,
                among: [matching, Account(name: "Duplicate", accountType: .creditCard, institutionName: "NAB", lastFourDigits: "6981")]
            ).count == 2
        )
    }

    @Test
    func selectingDestinationAccountPreservesImportCandidatesAndRefreshesDuplicates() {
        let account = Account(name: "NAB Card", accountType: .creditCard, institutionName: "NAB")
        var candidates = [
            reviewCandidate(selectedAccountID: nil),
            reviewCandidate(selectedAccountID: nil)
        ]
        candidates[1].description = "Second merchant"
        let originalDate = candidates[0].date
        let originalAmount = candidates[0].amount
        let originalDescription = candidates[0].description
        let originalCategory = candidates[0].proposedCategoryID
        let originalAIState = candidates[0].aiEnrichmentState
        let originalBankDescription = candidates[0].originalBankDescription

        ImportDestinationAccountService.assign(accountID: account.id, to: &candidates)
        #expect(candidates.allSatisfy { $0.selectedAccountID == account.id })
        #expect(candidates[0].date == originalDate)
        #expect(candidates[0].amount == originalAmount)
        #expect(candidates[0].description == originalDescription)
        #expect(candidates[0].proposedCategoryID == originalCategory)
        #expect(candidates[0].aiEnrichmentState == originalAIState)
        #expect(candidates[0].originalBankDescription == originalBankDescription)

        let existing = Transaction(
            transactionDate: candidates[0].date,
            merchantDescription: candidates[0].description,
            amount: candidates[0].amount,
            transactionType: .expense,
            account: account,
            source: .csvImport,
            importIdentifier: candidates[0].importIdentifier
        )
        ImportReviewService.applyDuplicateRecommendations(
            to: &candidates,
            isPotentialDuplicate: {
                TransactionDuplicateDetector.isPotentialDuplicate($0, among: [existing])
            }
        )
        #expect(candidates[0].status == .potentialDuplicate)
        #expect(candidates[0].isIncluded == false)

        // Cancelling account creation calls neither service; the in-memory candidates remain intact.
        let beforeCancel = candidates
        #expect(candidates.map(\.id) == beforeCancel.map(\.id))
        #expect(candidates.map(\.selectedAccountID) == beforeCancel.map(\.selectedAccountID))
    }

    @Test
    func importReviewStateKeepsNormalAndUncategorisedCandidatesReady() {
        let accountID = UUID()
        let candidate = reviewCandidate(selectedAccountID: accountID)

        #expect(ImportReviewService.state(for: candidate) == .ready)
        #expect(ImportReviewService.canConfirmImport([candidate]))

        let summary = ImportReviewService.summary(for: [candidate])
        #expect(summary.readyCount == 1)
        #expect(summary.needsAttentionCount == 0)
        #expect(summary.uncategorisedCount == 1)
    }

    @Test
    func importReviewStateFlagsDuplicatesAndReviewCandidates() {
        var duplicateCandidates = [reviewCandidate(selectedAccountID: UUID())]
        ImportReviewService.applyDuplicateRecommendations(
            to: &duplicateCandidates,
            isPotentialDuplicate: { _ in true }
        )

        var duplicate = duplicateCandidates[0]

        #expect(ImportReviewService.state(for: duplicate) == .needsAttention(.potentialDuplicate))
        #expect(ImportReviewService.summary(for: [duplicate]).includedCount == 0)

        duplicate.isIncluded = true
        #expect(ImportReviewService.summary(for: [duplicate]).includedCount == 1)

        var explicitlyIncludedDuplicate = [duplicate]
        ImportReviewService.applyDuplicateRecommendations(
            to: &explicitlyIncludedDuplicate,
            isPotentialDuplicate: { _ in true }
        )
        #expect(explicitlyIncludedDuplicate[0].isIncluded)

        var needsReview = reviewCandidate(selectedAccountID: UUID())
        needsReview.status = .needsReview
        #expect(ImportReviewService.state(for: needsReview) == .needsAttention(.parserNeedsReview))
    }

    @Test
    func importReviewStateRequiresAnAccountBeforeImporting() {
        let candidate = reviewCandidate(selectedAccountID: nil)

        #expect(ImportReviewService.state(for: candidate) == .needsAttention(.missingAccount))
        #expect(ImportReviewService.canConfirmImport([candidate]) == false)
    }

    @Test
    func aiEnrichmentDoesNotOverrideUserRulesOrBankCategoryMatches() {
        let accountID = UUID()
        let userCategory = Category(name: "Pets")
        let alternateCategory = Category(name: "Shopping")
        let enrichment = TransactionAIEnrichment(
            merchantNameSuggestion: "Different Merchant",
            categorySuggestion: "Shopping"
        )

        var userRuleCandidate = reviewCandidate(selectedAccountID: accountID)
        userRuleCandidate.proposedCategoryID = userCategory.id
        #expect(TransactionAIEnrichmentPolicy.shouldRequest(for: userRuleCandidate) == false)
        #expect(TransactionAIEnrichmentPolicy.apply(enrichment, to: &userRuleCandidate, categories: [userCategory, alternateCategory]) == false)
        #expect(userRuleCandidate.proposedCategoryID == userCategory.id)
        #expect(userRuleCandidate.status == .ready)

        var sourceMatchedCandidate = reviewCandidate(selectedAccountID: accountID)
        sourceMatchedCandidate.sourceCategorySuggestion = "Pets"
        sourceMatchedCandidate.proposedCategoryID = userCategory.id
        #expect(TransactionAIEnrichmentPolicy.shouldRequest(for: sourceMatchedCandidate) == false)
        #expect(TransactionAIEnrichmentPolicy.apply(enrichment, to: &sourceMatchedCandidate, categories: [userCategory, alternateCategory]) == false)
        #expect(sourceMatchedCandidate.proposedCategoryID == userCategory.id)
    }

    @Test
    func sourceCategoryAliasesResolveOnlyClearLocalCategories() {
        let pets = Category(name: "Pets")
        let travel = Category(name: "Travel")
        let shopping = Category(name: "Shopping")
        let transfers = Category(name: "Transfers")
        let categories = [pets, travel, shopping, transfers]

        #expect(
            ImportCategorySuggestionService.deterministicCategoryID(
                for: "Flights",
                categories: categories
            ) == travel.id
        )
        #expect(
            ImportCategorySuggestionService.deterministicCategoryID(
                for: "  OTHER SHOPPING ",
                categories: categories
            ) == shopping.id
        )
        #expect(
            ImportCategorySuggestionService.deterministicCategoryID(
                for: "Internal transfers",
                categories: categories
            ) == transfers.id
        )
        #expect(
            ImportCategorySuggestionService.deterministicCategoryID(
                for: "pets",
                categories: categories
            ) == pets.id
        )
        #expect(
            ImportCategorySuggestionService.deterministicCategoryID(
                for: "Services",
                categories: categories
            ) == nil
        )
    }

    @Test
    func unresolvedBankCategoryRemainsEligibleForAIWhileResolvedCategoriesSkipIt() {
        let accountID = UUID()
        let shopping = Category(name: "Shopping")
        let categories = [shopping]

        var unresolved = reviewCandidate(selectedAccountID: accountID)
        unresolved.sourceCategorySuggestion = "Services"
        var unresolvedCandidates = [unresolved]
        ImportCategorySuggestionService.applySuggestions(
            to: &unresolvedCandidates,
            merchantRuleSuggestions: [:],
            categories: categories
        )
        #expect(unresolvedCandidates[0].proposedCategoryID == nil)
        #expect(TransactionAIEnrichmentPolicy.shouldRequest(for: unresolvedCandidates[0]))
        #expect(ImportReviewService.state(for: unresolvedCandidates[0]) == .ready)

        var resolved = reviewCandidate(selectedAccountID: accountID)
        resolved.sourceCategorySuggestion = "Other shopping"
        var resolvedCandidates = [resolved]
        ImportCategorySuggestionService.applySuggestions(
            to: &resolvedCandidates,
            merchantRuleSuggestions: [:],
            categories: categories
        )
        #expect(resolvedCandidates[0].proposedCategoryID == shopping.id)
        #expect(TransactionAIEnrichmentPolicy.shouldRequest(for: resolvedCandidates[0]) == false)
    }

    @Test
    func aiEnrichmentAcceptsOnlyExistingCategoriesAndPreservesFinancialData() {
        let accountID = UUID()
        let pets = Category(name: "Pets")
        var candidate = reviewCandidate(selectedAccountID: accountID)
        candidate.originalBankDescription = "RAW PET STORE PAYMENT"
        let originalDate = candidate.date
        let originalAmount = candidate.amount
        let originalDescription = candidate.description
        let originalBankDescription = candidate.originalBankDescription
        let originalStatus = candidate.status

        let valid = TransactionAIEnrichment(
            merchantNameSuggestion: "Unsupported Merchant",
            categorySuggestion: "pets"
        )
        #expect(TransactionAIEnrichmentPolicy.apply(valid, to: &candidate, categories: [pets]))
        #expect(candidate.proposedCategoryID == pets.id)
        #expect(candidate.aiCategorySuggestion == "Pets")
        #expect(candidate.description == originalDescription)
        #expect(candidate.date == originalDate)
        #expect(candidate.amount == originalAmount)
        #expect(candidate.originalBankDescription == originalBankDescription)
        #expect(candidate.status == originalStatus)

        var invalidCategoryCandidate = reviewCandidate(selectedAccountID: accountID)
        let invalid = TransactionAIEnrichment(
            merchantNameSuggestion: nil,
            categorySuggestion: "Invented category"
        )
        #expect(TransactionAIEnrichmentPolicy.apply(invalid, to: &invalidCategoryCandidate, categories: [pets]) == false)
        #expect(invalidCategoryCandidate.proposedCategoryID == nil)

        var duplicate = reviewCandidate(selectedAccountID: accountID)
        duplicate.status = .potentialDuplicate
        duplicate.isIncluded = false
        #expect(TransactionAIEnrichmentPolicy.apply(valid, to: &duplicate, categories: [pets]) == false)
        #expect(duplicate.status == .potentialDuplicate)
        #expect(duplicate.isIncluded == false)
    }

    @Test
    func aiMerchantCleanupIsConservativeAndCannotReplaceBankMerchantName() {
        let accountID = UUID()
        var nabCandidate = reviewCandidate(selectedAccountID: accountID)
        nabCandidate.description = "Brisbane Pet Motel"
        nabCandidate.originalBankDescription = "MYLACO PTY LTD BOONDALL"
        let hallucinatedMerchant = TransactionAIEnrichment(
            merchantNameSuggestion: "Brisbane Pet Motel Store",
            categorySuggestion: nil
        )
        #expect(TransactionAIEnrichmentPolicy.apply(hallucinatedMerchant, to: &nabCandidate, categories: []) == false)
        #expect(nabCandidate.description == "Brisbane Pet Motel")
        #expect(nabCandidate.originalBankDescription == "MYLACO PTY LTD BOONDALL")

        var rawCandidate = reviewCandidate(selectedAccountID: accountID)
        rawCandidate.description = "WOOLWORTHS 1234 CHERMSIDE"
        rawCandidate.originalBankDescription = "WOOLWORTHS 1234 CHERMSIDE"
        let conservativeCleanup = TransactionAIEnrichment(
            merchantNameSuggestion: "Woolworths",
            categorySuggestion: nil
        )
        #expect(TransactionAIEnrichmentPolicy.apply(conservativeCleanup, to: &rawCandidate, categories: []))
        #expect(rawCandidate.description == "Woolworths")
        #expect(rawCandidate.originalBankDescription == "WOOLWORTHS 1234 CHERMSIDE")
    }

    @Test
    func delayedAIResultsDoNotOverwriteManualEditsAndFallbackStaysImportable() {
        let accountID = UUID()
        var candidate = reviewCandidate(selectedAccountID: accountID)
        let snapshot = TransactionAIEnrichmentSnapshot(candidate: candidate)
        candidate.description = "User edited merchant"
        #expect(snapshot.matches(candidate) == false)

        // If Apple Intelligence is unavailable or one request fails, no policy is applied;
        // the deterministic candidate stays valid for normal import.
        #expect(ImportReviewService.canConfirmImport([candidate]))
        #expect(ImportReviewService.state(for: candidate) == .ready)
        #expect(TransactionAIAvailability.appleIntelligenceNotEnabled.isAvailable == false)
    }

    @Test
    func aiNoOpOutcomesKeepReadyTransactionsReadyAndUncategorised() {
        let accountID = UUID()
        let pets = Category(name: "Pets")

        var unavailable = reviewCandidate(selectedAccountID: accountID)
        unavailable.aiEnrichmentState = .unavailable
        #expect(ImportReviewService.state(for: unavailable) == .ready)
        #expect(unavailable.proposedCategoryID == nil)

        var failed = reviewCandidate(selectedAccountID: accountID)
        failed.aiEnrichmentState = .failed
        #expect(ImportReviewService.state(for: failed) == .ready)

        var noSuggestion = reviewCandidate(selectedAccountID: accountID)
        let emptyEnrichment = TransactionAIEnrichment(
            merchantNameSuggestion: nil,
            categorySuggestion: nil
        )
        #expect(TransactionAIEnrichmentPolicy.apply(emptyEnrichment, to: &noSuggestion, categories: [pets]) == false)
        #expect(noSuggestion.aiEnrichmentState == .noSuggestion)
        #expect(ImportReviewService.state(for: noSuggestion) == .ready)
        #expect(ImportReviewService.summary(for: [noSuggestion]).uncategorisedCount == 1)

        var invalidCategory = reviewCandidate(selectedAccountID: accountID)
        let unsupportedCategory = TransactionAIEnrichment(
            merchantNameSuggestion: nil,
            categorySuggestion: "Not a local category"
        )
        #expect(TransactionAIEnrichmentPolicy.apply(unsupportedCategory, to: &invalidCategory, categories: [pets]) == false)
        #expect(invalidCategory.proposedCategoryID == nil)
        #expect(ImportReviewService.state(for: invalidCategory) == .ready)
    }

    @Test
    func aiEnrichmentStateNeverChangesDeterministicAttentionCases() {
        var duplicate = reviewCandidate(selectedAccountID: UUID())
        duplicate.status = .potentialDuplicate
        duplicate.isIncluded = false
        duplicate.aiEnrichmentState = .failed
        #expect(ImportReviewService.state(for: duplicate) == .needsAttention(.potentialDuplicate))
        #expect(duplicate.isIncluded == false)

        var parserNeedsReview = reviewCandidate(selectedAccountID: UUID())
        parserNeedsReview.status = .needsReview
        parserNeedsReview.aiEnrichmentState = .noSuggestion
        #expect(ImportReviewService.state(for: parserNeedsReview) == .needsAttention(.parserNeedsReview))
    }

    @Test
    func parserHandlesQuotedCommasInDescriptions() throws {
        let csv = """
        Date,Description,Amount
        03/09/2026,"Market, Central",-18.25
        """

        let parser = CSVTransactionParser()
        let analysis = try parser.analyse(csv)
        let result = try parser.makeCandidates(
            from: analysis,
            mapping: analysis.suggestedMapping
        )

        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].description == "Market, Central")
    }

    @Test
    func americanExpressParserReadsWrappedChargesAndCredits() throws {
        let statement = """
        American Express Australia
        Statement of Account
        Card Number xxxx-xxxxxx-12345
        Statement Period From February 26 to March 25, 2026

        Payments Section
        March 1 Payment received
        125.00
        CR
        Total of Payments 125.00 CR

        New Transactions for: CARDHOLDER
        February 28 EXAMPLE MARKET
        CENTRAL CITY
        42.50
        March 2 SAMPLE CAFE NORTHSIDE 19.95
        Total of new transactions for CARDHOLDER 62.45

        OTHER ACCOUNT TRANSACTIONS
        March 4 Sample offer credit
        15.00
        CR
        Membership Rewards Period 20/02/2026 to 19/03/2026
        """

        let parser = AmericanExpressStatementParser()
        let analysis = parser.analyse(documentText: statement)

        #expect(parser.canParse(documentText: statement))
        #expect(analysis.accountIdentifier == "xxxx-xxxxxx-12345")
        #expect(analysis.statementStartDate != nil)
        #expect(analysis.statementEndDate != nil)
        #expect(analysis.candidates.count == 4)
        #expect(analysis.candidates[0].amount == Decimal(string: "125.00"))
        #expect(analysis.candidates[1].description == "EXAMPLE MARKET CENTRAL CITY")
        #expect(analysis.candidates[1].amount == Decimal(string: "-42.50"))
        #expect(analysis.candidates[2].amount == Decimal(string: "-19.95"))
        #expect(analysis.candidates[3].amount == Decimal(string: "15.00"))
    }

    @Test
    func americanExpressParserRejectsOtherStatements() {
        let parser = AmericanExpressStatementParser()
        let unrelatedText = """
        Example Bank
        Statement of Account
        New Transactions for: Customer
        March 2 Grocery Store 10.00
        """

        #expect(parser.canParse(documentText: unrelatedText) == false)
        #expect(parser.parse(documentText: unrelatedText).isEmpty)
    }

    @Test
    func pdfTextExtractorIdentifiesMeaningfulPageText() {
        #expect(PDFTextExtractor.isMeaningfulText("Statement account ending 1234") == true)
        #expect(PDFTextExtractor.isMeaningfulText("Page 1") == false)
        #expect(PDFTextExtractor.isMeaningfulText("   \n  ") == false)
    }

    @Test
    func accountDetailsExtractorReadsOnlySupportedCreditCardFields() {
        let statement = """
        American Express Australia
        American Express Platinum Card
        Statement of Account
        Account Holder: SAMPLE CUSTOMER
        Card Number: XXXX-XXXXXX-12345
        Currency: AUD
        Statement Period From February 26, 2026 to March 25, 2026
        Statement Balance: $8,538.80
        Minimum Payment Due $125.00
        Payment Due Date: April 8, 2026
        Purchase APR: 20.99%
        Cash Advance APR: 23.99%
        Up to 55 days interest-free
        """

        let details = StatementAccountDetailsExtractor().extract(documentText: statement)

        #expect(details?.financialInstitution?.value == "American Express Australia")
        #expect(details?.productName?.value == "Platinum Card")
        #expect(details?.accountType?.value == .creditCard)
        #expect(details?.accountHolderName?.value == "SAMPLE CUSTOMER")
        #expect(details?.lastFourDigits?.value == "2345")
        #expect(details?.currency?.value == "AUD")
        #expect(details?.statementBalance?.value == Decimal(string: "8538.80"))
        #expect(details?.minimumPayment?.value == Decimal(string: "125.00"))
        #expect(details?.paymentDueDate != nil)
        #expect(details?.purchaseInterestRate?.value == Decimal(string: "20.99"))
        #expect(details?.cashAdvanceInterestRate?.value == Decimal(string: "23.99"))
        #expect(details?.interestFreeDays?.value == 55)
        #expect(details?.creditLimit == nil)
        #expect(details?.minimumPayment?.sourceText?.contains("Minimum Payment Due") == true)
    }

    @Test
    func accountDetailsExtractorReadsExplicitBankDetailsWithoutInventingCreditFields() {
        let statement = """
        Financial Institution: Example Bank
        Account Name: Everyday Account
        Account Holder: SAMPLE CUSTOMER
        Account Number: XXXX-1234
        BSB: 123-456
        Currency: AUD
        Opening Balance: $1,000.00
        Closing Balance: $1,234.56
        """

        let details = StatementAccountDetailsExtractor().extract(documentText: statement)

        #expect(details?.financialInstitution?.value == "Example Bank")
        #expect(details?.productName?.value == "Everyday Account")
        #expect(details?.routingIdentifier?.value == "123-456")
        #expect(details?.openingBalance?.value == Decimal(string: "1000.00"))
        #expect(details?.statementClosingBalance?.value == Decimal(string: "1234.56"))
        #expect(details?.creditLimit == nil)
        #expect(details?.minimumPayment == nil)
    }

    @Test
    func statementParserSelectionPrefersInstitutionParserAndFallsBackConservatively() {
        let service = StatementImportService()
        let amexStatement = """
        American Express Australia
        Statement of Account
        """
        let genericStatement = """
        This is an unrelated document with a number 123456.78.
        """

        #expect(service.parserIdentifier(for: amexStatement) == "american-express-australia")
        #expect(service.parserIdentifier(for: genericStatement) == "generic-conservative")
        #expect(GenericStatementParser().extractTransactions(documentText: genericStatement).isEmpty)
        #expect(GenericStatementParser().extractAccountDetails(documentText: genericStatement) == nil)
    }

    @Test
    func americanExpressAccountDetailsNormalStatement() {
        let details = AmericanExpressStatementParser().extractAccountDetails(
            documentText: AmericanExpressStatementFixtures.normal
        )

        #expect(details?.financialInstitution?.value == "American Express")
        #expect(details?.productName?.value == "Platinum Card")
        #expect(details?.accountType?.value == .creditCard)
        #expect(details?.accountHolderName?.value == "SAMPLE MEMBER")
        #expect(details?.lastFourDigits?.value == "6789")
        #expect(details?.statementStartDate != nil)
        #expect(details?.statementEndDate != nil)
        #expect(details?.statementBalance?.value == Decimal(string: "1450.25"))
        #expect(details?.minimumPayment?.value == Decimal(string: "75.00"))
        #expect(details?.paymentDueDate != nil)
        #expect(details?.creditLimit?.value == Decimal(string: "12000.00"))
        #expect(details?.currency?.value == "AUD")
        #expect(details?.statementBalance?.confidence == .high)
    }

    @Test
    func americanExpressAccountDetailsSupportsPaidInFullAndCarriedBalances() {
        let parser = AmericanExpressStatementParser()
        let paidInFull = parser.extractAccountDetails(documentText: AmericanExpressStatementFixtures.paidInFull)
        let carryingBalance = parser.extractAccountDetails(documentText: AmericanExpressStatementFixtures.carryingBalance)

        #expect(paidInFull?.statementBalance?.value == 0)
        #expect(paidInFull?.minimumPayment?.value == 0)
        #expect(carryingBalance?.statementBalance?.value == Decimal(string: "980.40"))
        #expect(carryingBalance?.minimumPayment?.value == Decimal(string: "45.00"))
    }

    @Test
    func americanExpressAccountDetailsLeavesMissingOptionalFieldsNil() {
        let details = AmericanExpressStatementParser().extractAccountDetails(
            documentText: AmericanExpressStatementFixtures.missingOptionalFields
        )

        #expect(details?.creditLimit == nil)
        #expect(details?.cashAdvanceInterestRate == nil)
        #expect(details?.interestFreeDays == nil)
    }

    @Test
    func americanExpressAccountDetailsKeepsPurchaseAndCashRatesSeparate() {
        let details = AmericanExpressStatementParser().extractAccountDetails(
            documentText: AmericanExpressStatementFixtures.multipleInterestRates
        )

        #expect(details?.purchaseInterestRate?.value == Decimal(string: "19.99"))
        #expect(details?.cashAdvanceInterestRate?.value == Decimal(string: "23.99"))
        #expect(details?.purchaseInterestRate?.sourceText?.contains("Purchase Interest Rate") == true)
        #expect(details?.cashAdvanceInterestRate?.sourceText?.contains("Cash Advance Interest Rate") == true)
    }

    @Test
    func interestEstimateHandlesZeroPayment() {
        let estimate = makeInterestEstimate(payment: 0)
        #expect(estimate.unpaidBalance == 1000)
        #expect(estimate.estimatedInterest == Decimal(string: "16.44"))
    }

    @Test
    func interestEstimateHandlesMinimumPayment() {
        let estimate = makeInterestEstimate(payment: 50)
        #expect(estimate.unpaidBalance == 950)
        #expect(estimate.estimatedInterest == Decimal(string: "15.62"))
    }

    @Test
    func interestEstimateHandlesPartialPayment() {
        let estimate = makeInterestEstimate(payment: 500)
        #expect(estimate.unpaidBalance == 500)
        #expect(estimate.estimatedInterest == Decimal(string: "8.22"))
    }

    @Test
    func interestEstimateHandlesFullAndExcessPayment() {
        let fullPayment = makeInterestEstimate(payment: 1000)
        let excessPayment = makeInterestEstimate(payment: 1200)
        #expect(fullPayment.unpaidBalance == 0)
        #expect(fullPayment.estimatedInterest == 0)
        #expect(excessPayment.unpaidBalance == 0)
        #expect(excessPayment.estimatedInterest == 0)
    }

    @Test
    func interestEstimateHandlesZeroAndVeryHighAPR() {
        let zeroAPR = CreditCardInterestCalculator.estimate(
            statementBalance: 1000,
            paymentAmount: 0,
            annualPercentageRate: 0,
            interestAccruingDays: 30,
            conditions: interestFreeConditions
        )
        let highAPR = CreditCardInterestCalculator.estimate(
            statementBalance: 1000,
            paymentAmount: 0,
            annualPercentageRate: 100,
            interestAccruingDays: 30,
            conditions: interestFreeConditions
        )
        #expect(zeroAPR.estimatedInterest == 0)
        #expect(highAPR.estimatedInterest == Decimal(string: "82.19"))
    }

    @Test
    func interestEstimateRoundsToCents() {
        let estimate = CreditCardInterestCalculator.estimate(
            statementBalance: 101,
            paymentAmount: 0,
            annualPercentageRate: Decimal(string: "19.99")!,
            interestAccruingDays: 1,
            conditions: interestFreeConditions
        )
        #expect(estimate.estimatedInterest == Decimal(string: "0.06"))
    }

    @Test
    func transactionDetailEditUpdatesCategoryAndLearnsUsingDisplayMerchant() throws {
        let container = try inMemoryModelContainer()
        let modelContext = ModelContext(container)
        let account = Account(name: "NAB Card", accountType: .creditCard, institutionName: "NAB")
        let shopping = Category(name: "Shopping")
        let pets = Category(name: "Pets")
        let transaction = Transaction(
            transactionDate: .now,
            merchantDescription: "Brisbane Pet Motel",
            originalBankDescription: "MYLACO PTY LTD BOONDALL",
            amount: -190,
            transactionType: .expense,
            category: shopping,
            account: account,
            source: .csvImport,
            importIdentifier: "stable-import-id"
        )
        modelContext.insert(account)
        modelContext.insert(shopping)
        modelContext.insert(pets)
        modelContext.insert(transaction)
        try modelContext.save()

        var draft = TransactionEditDraft(transaction: transaction)
        draft.categoryID = pets.id
        try TransactionEditService.save(draft, to: transaction, categories: [shopping, pets], in: modelContext)

        #expect(transaction.category?.id == pets.id)
        let rules = try modelContext.fetch(FetchDescriptor<MerchantCategoryRule>())
        #expect(rules.count == 1)
        #expect(rules[0].merchantKey == MerchantCategoryRuleService.normalizedMerchantKey(for: "Brisbane Pet Motel"))
        #expect(rules[0].merchantKey != MerchantCategoryRuleService.normalizedMerchantKey(for: "MYLACO PTY LTD BOONDALL"))
        #expect(rules[0].category?.id == pets.id)
        #expect(transaction.originalBankDescription == "MYLACO PTY LTD BOONDALL")
        #expect(transaction.importIdentifier == "stable-import-id")
        #expect(transaction.source == .csvImport)
    }

    @Test
    func transactionDetailMerchantEditPreservesSourceDataAndSupportsNilOriginalDescription() throws {
        let container = try inMemoryModelContainer()
        let modelContext = ModelContext(container)
        let account = Account(name: "Everyday", accountType: .transactionAccount, institutionName: "Example")
        let transaction = Transaction(
            transactionDate: .now,
            merchantDescription: "BRISBANE PET MOTEL",
            originalBankDescription: nil,
            amount: -25,
            transactionType: .expense,
            account: account,
            source: .manual,
            importIdentifier: "manual-record-id"
        )
        modelContext.insert(account)
        modelContext.insert(transaction)
        try modelContext.save()

        var draft = TransactionEditDraft(transaction: transaction)
        draft.merchantDescription = "  Brisbane Pet Motel  "
        try TransactionEditService.save(draft, to: transaction, categories: [], in: modelContext)

        #expect(transaction.merchantDescription == "Brisbane Pet Motel")
        #expect(transaction.originalBankDescription == nil)
        #expect(transaction.importIdentifier == "manual-record-id")
        #expect(transaction.source == .manual)
    }

    @Test
    func transactionDetailDraftCancelLeavesStoredTransactionUnchanged() {
        let account = Account(name: "Everyday", accountType: .transactionAccount, institutionName: "Example")
        let category = Category(name: "Shopping")
        let transaction = Transaction(
            transactionDate: .now,
            merchantDescription: "Original merchant",
            originalBankDescription: "RAW BANK DESCRIPTION",
            amount: -12,
            transactionType: .expense,
            category: category,
            account: account,
            notes: "Original note",
            source: .csvImport,
            importIdentifier: "unchanged-import-id"
        )

        var draft = TransactionEditDraft(transaction: transaction)
        draft.merchantDescription = "Unsaved merchant"
        draft.categoryID = nil
        draft.notes = "Unsaved note"

        #expect(transaction.merchantDescription == "Original merchant")
        #expect(transaction.category?.id == category.id)
        #expect(transaction.notes == "Original note")
        #expect(transaction.originalBankDescription == "RAW BANK DESCRIPTION")
        #expect(transaction.importIdentifier == "unchanged-import-id")
        #expect(transaction.amount == -12)
        #expect(transaction.transactionDate != .distantPast)
    }

    @Test
    func transactionDetailNotesSaveWithoutChangingImportMetadata() throws {
        let container = try inMemoryModelContainer()
        let modelContext = ModelContext(container)
        let account = Account(name: "Everyday", accountType: .transactionAccount, institutionName: "Example")
        let transaction = Transaction(
            transactionDate: .now,
            merchantDescription: "Example merchant",
            originalBankDescription: "EXAMPLE RAW DESCRIPTION",
            amount: -15,
            transactionType: .expense,
            account: account,
            source: .pdfImport,
            importIdentifier: "pdf-import-id"
        )
        modelContext.insert(account)
        modelContext.insert(transaction)
        try modelContext.save()

        var draft = TransactionEditDraft(transaction: transaction)
        draft.notes = "Remember to check this charge."
        try TransactionEditService.save(draft, to: transaction, categories: [], in: modelContext)

        #expect(transaction.notes == "Remember to check this charge.")
        #expect(transaction.originalBankDescription == "EXAMPLE RAW DESCRIPTION")
        #expect(transaction.importIdentifier == "pdf-import-id")
        #expect(transaction.source == .pdfImport)
    }

    private var interestFreeConditions: CreditCardInterestConditions {
        CreditCardInterestConditions(
            isEligibleForInterestFreePeriod: true,
            mayHaveAdditionalInterestSources: false
        )
    }

    private func makeInterestEstimate(payment: Decimal) -> CreditCardInterestEstimate {
        CreditCardInterestCalculator.estimate(
            statementBalance: 1000,
            paymentAmount: payment,
            annualPercentageRate: 20,
            interestAccruingDays: 30,
            conditions: interestFreeConditions
        )
    }

    private func inMemoryModelContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Account.self,
            Transaction.self,
            Category.self,
            MerchantCategoryRule.self,
            configurations: configuration
        )
    }

    private func reviewCandidate(selectedAccountID: UUID?) -> ImportedTransactionCandidate {
        ImportedTransactionCandidate(
            date: Date(timeIntervalSince1970: 0),
            description: "Example Merchant",
            amount: -12.50,
            sourceText: "synthetic source row",
            confidence: .high,
            status: .ready,
            selectedAccountID: selectedAccountID,
            importIdentifier: "synthetic-review-candidate"
        )
    }
}

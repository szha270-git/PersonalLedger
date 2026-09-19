import Foundation
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
}

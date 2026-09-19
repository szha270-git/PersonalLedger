import Foundation

enum AmericanExpressStatementFixtures {
    static let normal = """
    American Express Australia
    American Express Platinum Card
    Statement of Account
    Card Member: SAMPLE MEMBER
    Card Number: XXXX-XXXXXX-6789
    Currency: AUD
    Statement Period From February 24 to March 25, 2026
    Statement Balance: $1,450.25
    Minimum Payment Due: $75.00
    Payment Due: April 8, 2026
    Credit Limit: $12,000.00
    Up to 55 days interest-free
    New Transactions for: SAMPLE MEMBER
    """

    static let paidInFull = """
    American Express Australia
    Gold Card
    Card Number: XXXX-XXXXXX-1234
    Statement Period From March 1 to March 31, 2026
    Statement Balance: $0.00
    Minimum Payment Due: $0.00
    Due Date: April 15, 2026
    """

    static let carryingBalance = """
    American Express Australia
    Credit Card
    Card Number: XXXX-XXXXXX-4321
    Statement Period From April 2 to May 1, 2026
    Closing Balance: $980.40
    Minimum Payment: $45.00
    """

    static let missingOptionalFields = """
    American Express Australia
    Platinum Card
    Card Number: XXXX-XXXXXX-2468
    Statement Balance: $250.00
    Minimum Payment Due: $25.00
    """

    static let multipleInterestRates = """
    American Express Australia
    Platinum Card
    Card Number: XXXX-XXXXXX-1357
    Statement Balance: $100.00
    Purchase Interest Rate: 19.99%
    Cash Advance Interest Rate: 23.99%
    """
}

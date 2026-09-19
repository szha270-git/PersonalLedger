import Foundation

struct CreditCardInterestConditions: Equatable {
    /// True only when the cardholder is eligible for the statement's interest-free period.
    let isEligibleForInterestFreePeriod: Bool

    /// Cash advances, carried balances, balance transfers, and special arrangements can mean
    /// bank-calculated interest differs from this statement-balance estimate.
    let mayHaveAdditionalInterestSources: Bool
}

struct CreditCardInterestEstimate: Equatable {
    let unpaidBalance: Decimal
    let estimatedInterest: Decimal
    let effectiveDailyInterestRate: Decimal
    let fullPaymentMayStillAccrueInterest: Bool
}

enum CreditCardInterestCalculator {
    /// Estimates simple daily interest on the unpaid statement balance.
    /// It does not model a bank's exact daily-balance method, compounding, fees, cash advances,
    /// balance transfers, or promotional rates. All results are rounded to cents.
    static func estimate(
        statementBalance: Decimal,
        paymentAmount: Decimal,
        annualPercentageRate: Decimal,
        interestAccruingDays: Int,
        conditions: CreditCardInterestConditions
    ) -> CreditCardInterestEstimate {
        let balance = maximum(statementBalance, 0)
        let payment = minimum(maximum(paymentAmount, 0), balance)
        let unpaidBalance = roundToCents(balance - payment)
        let dailyRate = maximum(annualPercentageRate, 0) / 100 / 365
        let days = Decimal(Swift.max(interestAccruingDays, 0))
        let isPaidInFull = unpaidBalance == 0
        let estimatedInterest: Decimal

        if isPaidInFull, conditions.isEligibleForInterestFreePeriod {
            estimatedInterest = 0
        } else {
            estimatedInterest = roundToCents(unpaidBalance * dailyRate * days)
        }

        return CreditCardInterestEstimate(
            unpaidBalance: unpaidBalance,
            estimatedInterest: estimatedInterest,
            effectiveDailyInterestRate: dailyRate,
            fullPaymentMayStillAccrueInterest: isPaidInFull &&
                (!conditions.isEligibleForInterestFreePeriod || conditions.mayHaveAdditionalInterestSources)
        )
    }

    static func roundToCents(_ value: Decimal) -> Decimal {
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }

    private static func maximum(_ lhs: Decimal, _ rhs: Decimal) -> Decimal {
        lhs > rhs ? lhs : rhs
    }

    private static func minimum(_ lhs: Decimal, _ rhs: Decimal) -> Decimal {
        lhs < rhs ? lhs : rhs
    }
}

import SwiftUI
import UIKit

struct CreditCardPaymentSimulatorConfiguration {
    let currentBalance: Decimal
    let statementBalance: Decimal
    let minimumPayment: Decimal
    let annualPercentageRate: Decimal
    let statementClosingDate: Date?
    let paymentDueDate: Date?
    let interestFreeDays: Int?
    let currencyCode: String
    let interestConditions: CreditCardInterestConditions

    var suggestedPayment: Decimal {
        let halfStatementBalance = CreditCardInterestCalculator.roundToCents(statementBalance / 2)
        return min(max(halfStatementBalance, minimumPayment), statementBalance)
    }

    var interestAccruingDays: Int {
        if let interestFreeDays, interestFreeDays > 0 {
            return interestFreeDays
        }
        guard let statementClosingDate, let paymentDueDate else {
            return 30
        }
        let days = Calendar.current.dateComponents([.day], from: statementClosingDate, to: paymentDueDate).day ?? 30
        return max(days, 1)
    }
}

struct CreditCardPaymentSimulator: View {
    let configuration: CreditCardPaymentSimulatorConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPayment: Decimal
    @State private var lastHapticThreshold: PaymentThreshold?

    init(configuration: CreditCardPaymentSimulatorConfiguration, selectedPayment: Decimal? = nil) {
        self.configuration = configuration
        _selectedPayment = State(initialValue: selectedPayment ?? configuration.minimumPayment)
    }

    private var estimate: CreditCardInterestEstimate {
        CreditCardInterestCalculator.estimate(
            statementBalance: configuration.statementBalance,
            paymentAmount: selectedPayment,
            annualPercentageRate: configuration.annualPercentageRate,
            interestAccruingDays: configuration.interestAccruingDays,
            conditions: configuration.interestConditions
        )
    }

    private var selectedThreshold: PaymentThreshold? {
        PaymentThreshold.allCases.first { threshold in
            threshold.amount(for: configuration) == selectedPayment
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PaymentAmountHeader(amount: selectedPayment, currencyCode: configuration.currencyCode)

            PaymentContextGrid(configuration: configuration)

            PaymentSelectorSection(
                selectedPayment: $selectedPayment,
                configuration: configuration,
                reduceMotion: reduceMotion
            )

            PaymentQuickActions(
                configuration: configuration,
                reduceMotion: reduceMotion,
                setPayment: setPayment
            )

            PaymentConsequenceView(
                estimate: estimate,
                configuration: configuration
            )

            Text("Estimate only. Banks may calculate interest differently using daily balances, fees, cash advances, carried balances, balance transfers, or special rates.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .onChange(of: selectedPayment) { _, newPayment in
            let clampedPayment = clamp(newPayment)
            if clampedPayment != newPayment {
                selectedPayment = clampedPayment
                return
            }
            triggerHapticIfNeeded()
        }
    }

    private func setPayment(_ amount: Decimal) {
        let update = {
            selectedPayment = clamp(amount)
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.smooth(duration: 0.25), update)
        }
    }

    private func clamp(_ amount: Decimal) -> Decimal {
        min(max(amount, configuration.minimumPayment), configuration.statementBalance)
    }

    private func triggerHapticIfNeeded() {
        guard let threshold = selectedThreshold, threshold != lastHapticThreshold else {
            if selectedThreshold == nil {
                lastHapticThreshold = nil
            }
            return
        }

        UIImpactFeedbackGenerator(style: threshold == .statementBalance ? .medium : .light).impactOccurred()
        lastHapticThreshold = threshold
    }
}

private struct PaymentAmountHeader: View {
    let amount: Decimal
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Selected payment")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(amount, format: .currency(code: currencyCode))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PaymentContextGrid: View {
    let configuration: CreditCardPaymentSimulatorConfiguration

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                PaymentContextValue(title: "Statement balance", value: configuration.statementBalance, currencyCode: configuration.currencyCode)
                PaymentContextValue(title: "Minimum payment", value: configuration.minimumPayment, currencyCode: configuration.currencyCode)
            }
            GridRow {
                Text("APR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Due date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Text(configuration.annualPercentageRate, format: .number.precision(.fractionLength(2))) + Text("%")
                Text(configuration.paymentDueDate?.formatted(.dateTime.day().month().year()) ?? "Not set")
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if configuration.currentBalance != configuration.statementBalance {
                Text("This simulator applies payment to the statement balance. Current balance may include newer transactions.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .padding(.bottom, configuration.currentBalance != configuration.statementBalance ? 24 : 0)
    }
}

private struct PaymentContextValue: View {
    let title: String
    let value: Decimal
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .currency(code: currencyCode))
                .monospacedDigit()
        }
    }
}

private struct PaymentSelectorSection: View {
    @Binding var selectedPayment: Decimal
    let configuration: CreditCardPaymentSimulatorConfiguration
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaymentTrack(
                selectedPayment: $selectedPayment,
                minimumPayment: configuration.minimumPayment,
                suggestedPayment: configuration.suggestedPayment,
                statementBalance: configuration.statementBalance,
                currencyCode: configuration.currencyCode,
                reduceMotion: reduceMotion
            )

            HStack {
                Text("Minimum")
                Spacer()
                Text("Suggested")
                Spacer()
                Text("Statement balance")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline) {
                Text("Payment amount")
                    .font(.subheadline)
                Spacer()
                TextField(
                    "Payment amount",
                    value: $selectedPayment,
                    format: .number.precision(.fractionLength(2))
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                Text(configuration.currencyCode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PaymentTrack: View {
    @Binding var selectedPayment: Decimal
    let minimumPayment: Decimal
    let suggestedPayment: Decimal
    let statementBalance: Decimal
    let currencyCode: String
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = max(Int(geometry.size.width.rounded()), 1)
            let progress = progress(for: selectedPayment)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 12)
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: geometry.size.width * progress, height: 12)

                ForEach(PaymentThreshold.allCases) { threshold in
                    PaymentTrackMarker(
                        xPosition: markerPosition(for: threshold, trackWidth: geometry.size.width),
                        isStatementBalance: threshold == .statementBalance
                    )
                }

                Circle()
                    .fill(.background)
                    .overlay(Circle().stroke(.tint, lineWidth: 3))
                    .frame(width: 28, height: 28)
                    .position(x: geometry.size.width * progress, y: 6)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updatePayment(xPosition: value.location.x, width: width)
                    }
                    .onEnded { _ in
                        snapToThresholdIfNearby()
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Payment amount")
        .accessibilityValue(selectedPayment.formatted(.currency(code: currencyCode)))
        .accessibilityHint("Adjust from minimum payment to statement balance. You can also enter an amount manually.")
        .accessibilityAdjustableAction { direction in
            let step = max((maximumCents - minimumCents) / 20, 1)
            let cents = selectedCents + (direction == .increment ? step : -step)
            setPayment(cents: cents)
        }
    }

    private var minimumCents: Int { cents(for: minimumPayment) }
    private var maximumCents: Int { cents(for: statementBalance) }
    private var selectedCents: Int { cents(for: selectedPayment) }

    private func progress(for amount: Decimal) -> CGFloat {
        let range = maximumCents - minimumCents
        guard range > 0 else { return 1 }
        return CGFloat(cents(for: amount) - minimumCents) / CGFloat(range)
    }

    private func markerPosition(for threshold: PaymentThreshold, trackWidth: CGFloat) -> CGFloat {
        let amount = threshold.amount(
            minimum: minimumPayment,
            suggested: suggestedPayment,
            maximum: statementBalance
        )
        return trackWidth * progress(for: amount)
    }

    private func updatePayment(xPosition: CGFloat, width: Int) {
        let clampedX = min(max(Int(xPosition.rounded()), 0), width)
        let range = maximumCents - minimumCents
        let cents = minimumCents + (range * clampedX / width)
        setPayment(cents: cents)
    }

    private func snapToThresholdIfNearby() {
        let snapDistance = max((maximumCents - minimumCents) / 25, 1)
        if let nearest = PaymentThreshold.allCases
            .map({ $0.amount(minimum: minimumPayment, suggested: suggestedPayment, maximum: statementBalance) })
            .min(by: { abs(cents(for: $0) - selectedCents) < abs(cents(for: $1) - selectedCents) }),
           abs(cents(for: nearest) - selectedCents) <= snapDistance {
            selectedPayment = nearest
        }
    }

    private func setPayment(cents: Int) {
        let clampedCents = min(max(cents, minimumCents), maximumCents)
        let update = {
            selectedPayment = Decimal(clampedCents) / 100
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.smooth(duration: 0.15), update)
        }
    }

    private func cents(for amount: Decimal) -> Int {
        NSDecimalNumber(decimal: CreditCardInterestCalculator.roundToCents(amount) * 100).intValue
    }
}

private struct PaymentTrackMarker: View {
    let xPosition: CGFloat
    let isStatementBalance: Bool

    var body: some View {
        Circle()
            .fill(isStatementBalance ? Color.accentColor : Color.secondary)
            .frame(width: 10, height: 10)
            .position(x: xPosition, y: 6)
    }
}

private enum PaymentThreshold: CaseIterable, Identifiable {
    case minimum
    case suggested
    case statementBalance

    var id: Self { self }

    func amount(for configuration: CreditCardPaymentSimulatorConfiguration) -> Decimal {
        amount(
            minimum: configuration.minimumPayment,
            suggested: configuration.suggestedPayment,
            maximum: configuration.statementBalance
        )
    }

    func amount(minimum: Decimal, suggested: Decimal, maximum: Decimal) -> Decimal {
        switch self {
        case .minimum: minimum
        case .suggested: suggested
        case .statementBalance: maximum
        }
    }
}

private struct PaymentQuickActions: View {
    let configuration: CreditCardPaymentSimulatorConfiguration
    let reduceMotion: Bool
    let setPayment: (Decimal) -> Void

    var body: some View {
        HStack(spacing: 10) {
            PaymentQuickActionButton(title: "Minimum") {
                setPayment(configuration.minimumPayment)
            }
            PaymentQuickActionButton(title: "50%") {
                setPayment(configuration.suggestedPayment)
            }
            PaymentQuickActionButton(title: "Statement Balance") {
                setPayment(configuration.statementBalance)
            }
        }
    }
}

private struct PaymentQuickActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }
}

private struct PaymentConsequenceView: View {
    let estimate: CreditCardInterestEstimate
    let configuration: CreditCardPaymentSimulatorConfiguration

    private var maximumEstimatedInterest: Decimal {
        CreditCardInterestCalculator.estimate(
            statementBalance: configuration.statementBalance,
            paymentAmount: configuration.minimumPayment,
            annualPercentageRate: configuration.annualPercentageRate,
            interestAccruingDays: configuration.interestAccruingDays,
            conditions: configuration.interestConditions
        ).estimatedInterest
    }

    private var interestProgress: CGFloat {
        guard maximumEstimatedInterest > 0 else { return 0 }
        return CGFloat(truncating: NSDecimalNumber(decimal: estimate.estimatedInterest / maximumEstimatedInterest))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Estimated interest")
                    .font(.headline)
                Spacer()
                Text(estimate.estimatedInterest, format: .currency(code: configuration.currencyCode))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(estimate.estimatedInterest == 0 ? .green : .primary)
            }

            InterestIndicator(progress: interestProgress, hasInterest: estimate.estimatedInterest > 0)

            LabeledContent("Remaining statement balance", value: estimate.unpaidBalance, format: .currency(code: configuration.currencyCode))

            if estimate.unpaidBalance == 0, !estimate.fullPaymentMayStillAccrueInterest {
                Text("Paying the statement balance by the due date is estimated to avoid statement interest when the interest-free period applies.")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else if estimate.fullPaymentMayStillAccrueInterest {
                Text("A full statement payment may not remove interest from cash advances, carried balances, balance transfers, or special arrangements.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct InterestIndicator: View {
    let progress: CGFloat
    let hasInterest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(hasInterest ? Color.orange.gradient : Color.green.gradient)
                            .frame(width: geometry.size.width * min(max(progress, 0), 1))
                    }
            }
            .frame(height: 8)
            HStack {
                Text("Pay more")
                Spacer()
                Text(hasInterest ? "More projected interest" : "Statement interest estimated at $0")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("$500 at 19.99%") {
    CreditCardPaymentSimulator(configuration: .preview(statementBalance: 500, minimumPayment: 25, apr: 19.99))
        .padding()
}

#Preview("$5,000 at 20.99%") {
    CreditCardPaymentSimulator(configuration: .preview(statementBalance: 5_000, minimumPayment: 150, apr: 20.99))
        .padding()
}

#Preview("$15,000 at 13.99%") {
    CreditCardPaymentSimulator(configuration: .preview(statementBalance: 15_000, minimumPayment: 450, apr: 13.99))
        .padding()
}

#Preview("Full payment") {
    let configuration = CreditCardPaymentSimulatorConfiguration.preview(statementBalance: 500, minimumPayment: 25, apr: 19.99)
    CreditCardPaymentSimulator(configuration: configuration, selectedPayment: configuration.statementBalance)
        .padding()
}

#Preview("Minimum payment") {
    let configuration = CreditCardPaymentSimulatorConfiguration.preview(statementBalance: 500, minimumPayment: 25, apr: 19.99)
    CreditCardPaymentSimulator(configuration: configuration, selectedPayment: configuration.minimumPayment)
        .padding()
}

private extension CreditCardPaymentSimulatorConfiguration {
    static func preview(statementBalance: Decimal, minimumPayment: Decimal, apr: Decimal) -> Self {
        CreditCardPaymentSimulatorConfiguration(
            currentBalance: statementBalance + 85,
            statementBalance: statementBalance,
            minimumPayment: minimumPayment,
            annualPercentageRate: apr,
            statementClosingDate: .now,
            paymentDueDate: Calendar.current.date(byAdding: .day, value: 21, to: .now),
            interestFreeDays: 21,
            currencyCode: "AUD",
            interestConditions: CreditCardInterestConditions(
                isEligibleForInterestFreePeriod: true,
                mayHaveAdditionalInterestSources: false
            )
        )
    }
}

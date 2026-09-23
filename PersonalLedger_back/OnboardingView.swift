import SwiftUI

enum OnboardingSettings {
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
}

enum FirstUseAction: Identifiable {
    case importStatement
    case addAccount

    var id: String {
        switch self {
        case .importStatement:
            "importStatement"
        case .addAccount:
            "addAccount"
        }
    }
}

/// A presentation-only introduction. It never changes financial data or preferences.
struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinish: () -> Void

    @State private var currentStep: OnboardingStep = .welcome
    @State private var presentedAction: FirstUseAction?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingNavigationBar(
                    showsSkip: currentStep != .getStarted,
                    onSkip: finish
                )

                TabView(selection: $currentStep) {
                    OnboardingWelcomePage()
                        .tag(OnboardingStep.welcome)
                    OnboardingTransactionsPage()
                        .tag(OnboardingStep.transactions)
                    OnboardingPrivacyPage()
                        .tag(OnboardingStep.privacy)
                    OnboardingFirstUsePage(
                        onImport: { presentedAction = .importStatement },
                        onAddAccount: { presentedAction = .addAccount },
                        onMaybeLater: finish
                    )
                    .tag(OnboardingStep.getStarted)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: 16) {
                    OnboardingProgress(step: currentStep)

                    if currentStep != .getStarted {
                        Button("Continue", action: advance)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.roundedRectangle)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 620)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: currentStep)
        .sheet(item: $presentedAction) { action in
            switch action {
            case .importStatement:
                CSVImportFlowView { _ in
                    finish()
                }
            case .addAccount:
                AccountEditorView(account: nil) { _ in
                    finish()
                }
            }
        }
    }

    private func advance() {
        guard let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) else {
            return
        }
        if reduceMotion {
            currentStep = nextStep
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                currentStep = nextStep
            }
        }
    }

    private func finish() {
        presentedAction = nil
        onFinish()
    }
}

private enum OnboardingStep: Int, CaseIterable, Hashable, Identifiable {
    case welcome
    case transactions
    case privacy
    case getStarted

    var id: Int { rawValue }
}

private struct OnboardingNavigationBar: View {
    let showsSkip: Bool
    let onSkip: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if showsSkip {
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

private struct OnboardingWelcomePage: View {
    var body: some View {
        OnboardingPageContainer(style: .welcome) {
            VStack(alignment: .leading, spacing: 24) {
                NettBrandMark()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Nett")
                        .font(.largeTitle.weight(.bold))
                    Text("Your money, made clear.")
                        .font(.title2.weight(.semibold))
                    Text("Turn bank statements into a clear picture of your spending.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct OnboardingTransactionsPage: View {
    var body: some View {
        OnboardingPageContainer(style: .standard) {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingPageHeading(
                    title: "Understand every transaction",
                    message: "Bring statement activity into one clear, reviewable place.",
                    systemImage: "list.bullet.rectangle"
                )

                VStack(alignment: .leading, spacing: 18) {
                    OnboardingFeatureRow(
                        title: "Recognisable merchants",
                        message: "Make confusing bank descriptions easier to understand.",
                        systemImage: "storefront",
                        isEmphasized: true
                    )
                    Divider()
                    OnboardingFeatureRow(
                        title: "Smart organisation",
                        message: "Organise spending into categories and learn from your choices.",
                        systemImage: "tag"
                    )
                    Divider()
                    OnboardingFeatureRow(
                        title: "Cleaner imports",
                        message: "Review potential duplicates before they are added.",
                        systemImage: "checkmark.circle"
                    )
                }
            }
        }
    }
}

private struct OnboardingPrivacyPage: View {
    var body: some View {
        OnboardingPageContainer(style: .standard) {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingPageHeading(
                    title: "Private by design",
                    message: "Nett is designed to process supported financial data locally, with optional on-device Apple Intelligence assistance when available.",
                    systemImage: "lock.shield.fill"
                )

                VStack(alignment: .leading, spacing: 14) {
                    OnboardingPrivacyPoint("You review and confirm imported transactions before they are added.")
                    OnboardingPrivacyPoint("Apple Intelligence suggestions are optional and never required to use Nett.")
                }
            }
        }
    }
}

private struct OnboardingFirstUsePage: View {
    let onImport: () -> Void
    let onAddAccount: () -> Void
    let onMaybeLater: () -> Void

    var body: some View {
        OnboardingPageContainer(style: .standard) {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingPageHeading(
                    title: "Let’s get started",
                    message: "Choose a first step. You can always add more accounts or import another statement later.",
                    systemImage: nil
                )

                VStack(spacing: 12) {
                    Button(action: onImport) {
                        Label("Import a statement", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle)
                    .controlSize(.large)

                    Button(action: onAddAccount) {
                        Label("Add an account manually", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle)
                    .controlSize(.large)

                    Button("Maybe later", action: onMaybeLater)
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                }
            }
        }
    }
}

private enum OnboardingPageContainerStyle: Equatable {
    case welcome
    case standard

    var minimumHeight: CGFloat? {
        switch self {
        case .welcome:
            500
        case .standard:
            nil
        }
    }
}

private struct OnboardingPageContainer<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let style: OnboardingPageContainerStyle
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay {
                            if style == .welcome {
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.accentColor.opacity(0.12), .clear],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                        }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(
                    maxWidth: .infinity,
                    minHeight: dynamicTypeSize.isAccessibilitySize ? nil : style.minimumHeight,
                    alignment: .center
                )
        }
    }
}

private struct OnboardingPageHeading: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingFeatureRow: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let systemImage: String
    var isEmphasized = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(isEmphasized ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(isEmphasized ? Color.accentColor : .secondary)
                .frame(width: isEmphasized ? 28 : 20, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(isEmphasized ? .title3.weight(.semibold) : .headline)
                Text(message)
                    .font(isEmphasized ? .body : .subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NettBrandMark: View {
    @ScaledMetric(relativeTo: .largeTitle) private var markSize = 78.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("N")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: markSize, height: markSize)
        .accessibilityHidden(true)
    }
}

private struct OnboardingPrivacyPoint: View {
    let message: LocalizedStringResource

    init(_ message: LocalizedStringResource) {
        self.message = message
    }

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        }
    }
}

private struct OnboardingProgress: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases) { item in
                Capsule()
                    .fill(item == step ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary.opacity(0.22)))
                    .frame(width: item == step ? 28 : 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding page \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

#Preview {
    OnboardingView(onFinish: {})
}

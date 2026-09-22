import SwiftData
import SwiftUI

@main
struct LedgerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Account.self, Transaction.self, Category.self, MerchantCategoryRule.self])
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query private var transactions: [Transaction]

    @AppStorage(OnboardingSettings.hasCompletedOnboardingKey)
    private var hasCompletedOnboarding = false
    @State private var firstUseAction: FirstUseAction?

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                PersonalLedgerTabView(firstUseAction: $firstUseAction)
            } else {
                OnboardingView(
                    onDismiss: completeOnboarding,
                    onAction: completeOnboarding(using:)
                )
            }
        }
        .task {
            try? CategoryDefaults.seedIfNeeded(in: modelContext)

            // Existing local ledgers predate this lightweight preference. They
            // continue directly to the app without changing any ledger data.
            if !hasCompletedOnboarding, (!accounts.isEmpty || !transactions.isEmpty) {
                hasCompletedOnboarding = true
            }
        }
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    private func completeOnboarding(using action: FirstUseAction) {
        hasCompletedOnboarding = true
        firstUseAction = action
    }
}

private struct PersonalLedgerTabView: View {
    @Binding var firstUseAction: FirstUseAction?
    @State private var selectedTab = PersonalLedgerTab.home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(PersonalLedgerTab.home)

            TransactionsView()
                .tabItem {
                    Label("Transactions", systemImage: "list.bullet.rectangle")
                }
                .tag(PersonalLedgerTab.transactions)

            AccountsView()
                .tabItem {
                    Label("Accounts", systemImage: "building.columns")
                }
                .tag(PersonalLedgerTab.accounts)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(PersonalLedgerTab.settings)
        }
        .onChange(of: firstUseAction, initial: true) { _, action in
            switch action {
            case .importStatement:
                selectedTab = .transactions
            case .addAccount:
                selectedTab = .accounts
            case nil:
                break
            }
        }
        .sheet(item: $firstUseAction) { action in
            switch action {
            case .importStatement:
                CSVImportFlowView { _ in }
            case .addAccount:
                AccountEditorView(account: nil)
            }
        }
    }
}

private enum PersonalLedgerTab: Hashable {
    case home
    case transactions
    case accounts
    case settings
}

private struct PlaceholderScreen: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text(message)
            )
            .navigationTitle(title)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Account.self, Transaction.self, Category.self, MerchantCategoryRule.self], inMemory: true)
}

enum OnboardingSettings {
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
}

enum FirstUseAction: Identifiable, Equatable {
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

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onDismiss: () -> Void
    let onAction: (FirstUseAction) -> Void

    @State private var currentPage = OnboardingPage.welcome

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Spacer()
                        Button("Skip", action: onDismiss)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }

                    Spacer(minLength: 12)

                    OnboardingPageContent(page: currentPage)
                        .id(currentPage)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .trailing)))

                    Spacer(minLength: 8)

                    OnboardingProgress(page: currentPage)

                    if currentPage == .privacy {
                        FirstUseActions(onAction: onAction)
                    } else {
                        Button("Continue", action: advance)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.roundedRectangle)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, minHeight: 600, alignment: .top)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: currentPage)
    }

    private func advance() {
        guard let nextPage = OnboardingPage(rawValue: currentPage.rawValue + 1) else {
            return
        }
        currentPage = nextPage
    }
}

private enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case statementImport
    case privacy

    var id: Int { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .welcome:
            "PersonalLedger"
        case .statementImport:
            "Import and understand"
        case .privacy:
            "Private by design"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .welcome:
            "Understand your money without giving up your financial data."
        case .statementImport:
            "Import a bank statement, review the transactions, and organise your spending in one local ledger."
        case .privacy:
            "Financial records and statement processing are local to the current app. Apple Intelligence suggestions are optional and use the on-device model when available."
        }
    }

    var systemImage: String {
        switch self {
        case .welcome:
            "chart.pie.fill"
        case .statementImport:
            "doc.text.magnifyingglass"
        case .privacy:
            "lock.shield.fill"
        }
    }
}

private struct OnboardingPageContent: View {
    let page: OnboardingPage

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: page.systemImage)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 88, height: 88)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text(page.title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(page.message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingProgress: View {
    let page: OnboardingPage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases) { item in
                Capsule()
                    .fill(item == page ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary.opacity(0.22)))
                    .frame(width: item == page ? 28 : 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Introduction page \(page.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }
}

private struct FirstUseActions: View {
    let onAction: (FirstUseAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start your ledger")
                .font(.headline)

            Button {
                onAction(.importStatement)
            } label: {
                Label("Import a statement", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(.large)

            Text("Start with a CSV statement. You can review every transaction before it is saved.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                onAction(.addAccount)
            } label: {
                Label("Add an account manually", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(.large)
        }
        .accessibilityElement(children: .contain)
    }
}

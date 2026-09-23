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

    @AppStorage(OnboardingSettings.hasCompletedOnboardingKey)
    private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                PersonalLedgerTabView()
            } else {
                OnboardingView(onFinish: completeOnboarding)
            }
        }
        .task {
            try? CategoryDefaults.seedIfNeeded(in: modelContext)
        }
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
    }

}

private struct PersonalLedgerTabView: View {
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

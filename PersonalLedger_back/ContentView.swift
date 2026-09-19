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

    var body: some View {
        TabView {
            HomeView()
            .tabItem {
                Label("Home", systemImage: "house")
            }

            TransactionsView()
            .tabItem {
                Label("Transactions", systemImage: "list.bullet.rectangle")
            }

            AccountsView()
                .tabItem {
                    Label("Accounts", systemImage: "building.columns")
                }

            SettingsView()
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .task {
            try? CategoryDefaults.seedIfNeeded(in: modelContext)
        }
    }
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

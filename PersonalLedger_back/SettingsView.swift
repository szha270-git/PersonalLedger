import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Organisation") {
                    NavigationLink("Categories") {
                        CategoriesView()
                    }
                }

                Section("Privacy") {
                    Label("Financial data stays on this device", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct CategoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.name) private var categories: [Category]

    @State private var categoryToEdit: Category?
    @State private var isAddingCategory = false
    @State private var deleteErrorMessage: String?

    var body: some View {
        List {
            ForEach(categories) { category in
                Button {
                    categoryToEdit = category
                } label: {
                    HStack {
                        if let iconName = category.iconName {
                            Image(systemName: iconName)
                                .frame(width: 24)
                        }
                        Text(category.name)
                        Spacer()
                        if category.isSystemCategory {
                            Text("Suggested")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button(role: .destructive) {
                        delete(category)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingCategory = true
                } label: {
                    Label("Add category", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingCategory) {
            CategoryEditorView(category: nil)
        }
        .sheet(item: $categoryToEdit) { category in
            CategoryEditorView(category: category)
        }
        .alert("Category is in use", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private func delete(_ category: Category) {
        guard category.transactions.isEmpty else {
            deleteErrorMessage = "Remove or change the category on its transactions before deleting it."
            return
        }
        modelContext.delete(category)
    }
}

private struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let category: Category?
    @State private var name: String
    @State private var iconName: String

    init(category: Category?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _iconName = State(initialValue: category?.iconName ?? "tag")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("SF Symbol name", text: $iconName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(category == nil ? "Add category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIconName = iconName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let category {
            category.name = trimmedName
            category.iconName = trimmedIconName.isEmpty ? nil : trimmedIconName
        } else {
            modelContext.insert(Category(name: trimmedName, iconName: trimmedIconName.isEmpty ? nil : trimmedIconName))
        }
        dismiss()
    }
}

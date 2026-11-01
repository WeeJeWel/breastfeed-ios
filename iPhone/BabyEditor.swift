import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BabyEditor: View {
    @EnvironmentObject private var store: FeedingStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var journal: FeedingJournal
    @State private var name: String
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    @State private var contentHeight: CGFloat = 230
    @FocusState private var nameFocused: Bool

    init(journal: FeedingJournal) {
        self.journal = journal
        _name = State(initialValue: journal.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Baby name").font(.subheadline).foregroundStyle(Palette.muted)
                TextField("Baby name", text: $name)
                    .font(.headline)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    .onChange(of: name) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !journal.isDeleted, !trimmed.isEmpty, trimmed != journal.name else { return }
                        do {
                            try store.renameBaby(journal, name: trimmed)
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
            }
            .padding(18)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Enter a baby name. The previous name is still saved.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Palette.accent)
            }
            Button("Delete Baby", role: .destructive) {
                nameFocused = false
                confirmingDelete = true
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
        .foregroundStyle(Palette.cream)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = ceil($0) }
        .presentationDetents([.height(contentHeight)])
        .presentationBackground(Palette.background)
        .presentationDragIndicator(.visible)
        .alert("Delete Baby?", isPresented: $confirmingDelete) {
            Button("Delete Baby", role: .destructive) {
                do {
                    try store.deleteBaby(journal)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                } catch { errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? journal.name : name) and all their feedings, including for anyone sharing this baby’s journal.")
        }
        .onChange(of: journal.isDeleted) { _, deleted in if deleted { dismiss() } }
    }
}

struct NewBabyEditor: View {
    @EnvironmentObject private var store: FeedingStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var showingImport = false
    @State private var importedCount: Int?
    @State private var errorMessage: String?
    @State private var contentHeight: CGFloat = 250
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Baby").font(.headline)
            TextField("Baby name", text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit { nameFocused = false }
                .padding(18)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            Button("Add") {
                do {
                    try store.createBaby(name: name)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                } catch { errorMessage = error.localizedDescription }
            }
            .buttonStyle(.borderedProminent).tint(Palette.accent)
            .frame(maxWidth: .infinity)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Import JSON") {
                nameFocused = false
                showingImport = true
            }
            .font(.footnote).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
        .foregroundStyle(Palette.cream)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = ceil($0) }
        .presentationDetents([.height(contentHeight)])
        .presentationBackground(Palette.background)
        .presentationDragIndicator(.visible)
        .fileImporter(isPresented: $showingImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 25_000_000 else { throw FeedingError.invalidBackup }
                importedCount = try store.importJSON(Data(contentsOf: url))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("Import Complete", isPresented: Binding(get: { importedCount != nil }, set: { if !$0 { importedCount = nil } })) {
            Button("Done") { dismiss() }
        } message: {
            Text("Added \(importedCount ?? 0) feedings. Existing babies and feedings were kept.")
        }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .preferredColorScheme(.dark)
    }
}

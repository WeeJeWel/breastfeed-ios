import CloudKit
import CoreData
import SwiftUI
import UIKit

extension FeedingStore {
    func prepareShare(for journalID: NSManagedObjectID) async throws -> CKShare {
        // Keep the request alive if its sheet closes or times out. Retrying must
        // join the same operation, not move the journal into another share zone.
        if let request = shareRequests[journalID] { return try await request.value }
        guard !localOnly else {
            throw NSError(domain: "Sharing", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "Sharing needs a signed build with iCloud enabled. Demo data stays on this device.")])
        }
        let container = container
        let context = container.newBackgroundContext()
        let request = Task<CKShare, Error> {
            defer { shareRequests[journalID] = nil }
            return try await withCheckedThrowingContinuation { continuation in
                // fetchShares and share can block. Use objects owned by this
                // background context so neither operation waits on the UI queue.
                context.perform {
                    do {
                        guard let journal = try context.existingObject(with: journalID) as? FeedingJournal,
                              !journal.isDeleted, let persistentStore = journalID.persistentStore else {
                            throw FeedingError.storageUnavailable
                        }
                        if let existing = try container.fetchShares(matching: [journalID])[journalID] {
                            continuation.resume(returning: existing)
                            return
                        }
                        guard persistentStore.url?.lastPathComponent == "Private.sqlite" else {
                            throw NSError(domain: "Sharing", code: 2, userInfo: [NSLocalizedDescriptionKey:
                                String(localized: "Sharing details are still syncing. Please try again.")])
                        }
                        let title = String(localized: "\(journal.name)’s feeding journal")
                        container.share([journal], to: nil) { _, share, _, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let share {
                                share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                                // Persist our title change and share metadata before
                                // presenting Apple's participant controller.
                                container.persistUpdatedShare(share, in: persistentStore) { saved, error in
                                    if let error { continuation.resume(throwing: error) }
                                    else { continuation.resume(returning: saved ?? share) }
                                }
                            } else { continuation.resume(throwing: FeedingError.storageUnavailable) }
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        shareRequests[journalID] = request
        return try await request.value
    }

    func acceptShare(_ metadata: CKShare.Metadata) {
        guard let sharedStore else {
            errorMessage = String(localized: "Shared iCloud storage isn’t available yet. Please try the invitation again.")
            return
        }
        container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            Task { @MainActor in
                if let error { self.errorMessage = error.localizedDescription }
                else {
                    self.selectedJournalID = ""
                    self.cloudStatus = String(localized: "Invitation accepted. Syncing your shared journal…")
                    self.refresh()
                }
            }
        }
    }
}

struct SharingView: View {
    @EnvironmentObject private var store: FeedingStore
    @Environment(\.dismiss) private var dismiss
    @State private var share: CKShare?
    @State private var preparing = false
    @State private var showingShare = false
    @State private var message: String?
    @State private var requestID: UUID?
    let journalID: NSManagedObjectID?
    let babyName: String
    let isSharedJournal: Bool

    var body: some View {
        Group {
            if isSharedJournal {
                if let share {
                    CloudSharingSheet(share: share, babyName: babyName)
                        .environmentObject(store)
                } else {
                    NavigationStack {
                        VStack(spacing: 16) {
                            if let message {
                                Text(message).multilineTextAlignment(.center)
                                    .foregroundStyle(Palette.muted)
                                Button("Try Again") { self.message = nil; preparing = true; requestID = UUID() }
                                    .tint(Palette.accent)
                            } else {
                                ProgressView("Loading participants…")
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.background)
                        .navigationTitle("Participants")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                    }
                }
            } else {
                invitationView
            }
        }
        .onAppear {
            if isSharedJournal, share == nil, requestID == nil {
                preparing = true
                requestID = UUID()
            }
        }
        .task(id: requestID) {
            guard requestID != nil, let journalID else { return }
            do {
                let preparedShare = try await store.prepareShare(for: journalID)
                try Task.checkCancellation()
                share = preparedShare
                preparing = false
                requestID = nil
                if !isSharedJournal { showingShare = true }
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                preparing = false
                requestID = nil
            }
        }
        .task(id: requestID) {
            guard requestID != nil else { return }
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            preparing = false
            requestID = nil
            message = String(localized: "iCloud is taking longer than expected. You can close this screen and try again shortly.")
        }
        .onDisappear { requestID = nil; preparing = false }
        .preferredColorScheme(.dark)
    }

    private var invitationView: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "person.2.fill").font(.title).foregroundStyle(Palette.accent)
                        Text(babyName).font(.system(.title2, design: .serif))
                        Text("Invite your partner to this baby’s journal. Everyone invited can rename the baby and add, edit, or delete feedings.")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                    }.padding(.vertical, 12)
                    Button {
                        message = nil
                        preparing = true
                        requestID = UUID()
                    } label: {
                        HStack {
                            Label("Invite Partner", systemImage: "person.badge.plus")
                            Spacer()
                            if preparing { ProgressView() }
                        }
                    }
                    .disabled(preparing || journalID == nil)
                }
                .listRowBackground(Palette.surface)

                Section("Storage") {
                    Label(store.cloudStatus, systemImage: "icloud")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                    Text("Feedings are saved on your device immediately and sync through iCloud when connected. Accept your partner’s invitation on your iPhone; the shared journal also syncs to your Watch.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Invite Partner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingShare) {
                if let share { CloudSharingSheet(share: share, babyName: babyName).environmentObject(store) }
            }
            .alert("iCloud sharing", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
        .preferredColorScheme(.dark)
    }
}

struct CloudSharingSheet: UIViewControllerRepresentable {
    @EnvironmentObject private var store: FeedingStore
    let share: CKShare
    let babyName: String

    func makeCoordinator() -> Coordinator { Coordinator(store: store, babyName: babyName) }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: CKContainer(identifier: FeedingStore.containerID))
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let store: FeedingStore
        let babyName: String
        init(store: FeedingStore, babyName: String) { self.store = store; self.babyName = babyName }
        func itemTitle(for csc: UICloudSharingController) -> String? { String(localized: "\(babyName)’s feeding journal") }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            Task { @MainActor in store.errorMessage = error.localizedDescription }
        }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in store.refresh() }
        }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            Task { @MainActor in store.refresh() }
        }
    }
}

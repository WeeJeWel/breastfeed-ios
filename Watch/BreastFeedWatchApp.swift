import SwiftUI
import WatchKit

@main
struct BreastFeedWatchApp: App {
    @StateObject private var store = FeedingStore.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(store)
                .tint(Palette.accent)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in if phase == .active { store.refresh() } }
                .alert("Couldn’t save feeding", isPresented: Binding(
                    get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
                )) { Button("OK") { store.errorMessage = nil } }
                message: { Text(store.errorMessage ?? "") }
        }
    }
}

struct WatchHomeView: View {
    @EnvironmentObject private var store: FeedingStore
    @State private var saved = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let running = store.running, let event = store.runningEvent {
                        if event.journal?.uuid != store.activeJournal?.uuid {
                            Text(event.journal?.name ?? String(localized: "Our baby")).font(.caption)
                        }
                        Label { Text((event.side ?? .left).breastTitle) } icon: {
                            FeedingEventSymbol(kind: .breast, side: event.side, size: 22)
                        }
                            .font(.headline).foregroundStyle(Palette.accent)
                        Text(running.startedAt, style: .timer)
                            .font(.system(.largeTitle, design: .rounded)).monospacedDigit()
                        Button("Done") {
                            do {
                                try store.finish(eventID: event.uuid)
                                WKInterfaceDevice.current().play(.stop)
                            } catch { store.errorMessage = error.localizedDescription }
                        }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.background)
                        Button((event.side ?? .left).opposite.switchTitle) {
                            do {
                                try store.finish(eventID: event.uuid, switchSide: true)
                                WKInterfaceDevice.current().play(.start)
                            } catch { store.errorMessage = error.localizedDescription }
                        }
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .tint(Palette.accent)
                    } else {
                        HStack(spacing: 8) {
                            ForEach([FeedingSide.left, .right]) { side in
                                Button {
                                    do {
                                        try store.add(kind: .breast, side: side)
                                        WKInterfaceDevice.current().play(.start)
                                    } catch { store.errorMessage = error.localizedDescription }
                                } label: {
                                    VStack(spacing: 6) {
                                        FeedingEventSymbol(kind: .breast, side: side, size: 28, selectedColor: Palette.background)
                                        Text(side.title).font(.headline)
                                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.accent)
                                .foregroundStyle(Palette.background)
                                .accessibilityLabel("Start breastfeeding, \(side.title)")
                            }
                        }
                    }
                    Button {
                        do {
                            try store.add(kind: .bottle)
                            WKInterfaceDevice.current().play(.success)
                            saved = true
                        } catch { store.errorMessage = error.localizedDescription }
                    } label: { Label("Bottle", systemImage: "waterbottle.fill").frame(maxWidth: .infinity) }
                    NavigationLink { WatchPumpView() } label: {
                        Label { Text("Pump") } icon: {
                            Image("Pump").resizable().scaledToFit().frame(width: 22, height: 22)
                        }.frame(maxWidth: .infinity)
                    }
                    if let last = store.events.last {
                        VStack(spacing: 3) {
                            Text("LAST FEEDING").font(.system(size: 9, weight: .semibold)).tracking(1)
                            Text(last.title).font(.caption)
                            Text(last.startedAt, format: .dateTime.hour().minute()).font(.caption2)
                        }
                        .foregroundStyle(Palette.muted).padding(.top, 6)
                    }
                }
                .padding(.horizontal, 4)
            }
            .background(Palette.background)
            .navigationTitle {
                NavigationLink {
                    List {
                        ForEach(store.journals) { journal in
                            Button {
                                store.selectedJournalID = journal.uuid.uuidString
                                WKInterfaceDevice.current().play(.click)
                            } label: {
                                HStack {
                                    Text(journal.name)
                                    Spacer()
                                    if journal.uuid == store.activeJournal?.uuid { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    .navigationTitle("Babies")
                } label: {
                    HStack {
                        Text(store.activeJournal?.name ?? String(localized: "Our baby")).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }
            .alert("Bottle saved", isPresented: $saved) { Button("Done", role: .cancel) {} }
        }
    }
}

struct WatchPumpView: View {
    @EnvironmentObject private var store: FeedingStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 8) {
            ForEach(FeedingSide.allCases) { side in
                Button("Pump · \(side.title)") {
                    do {
                        try store.add(kind: .pump, side: side)
                        WKInterfaceDevice.current().play(.success)
                        dismiss()
                    } catch { store.errorMessage = error.localizedDescription }
                }
                .tint(Palette.accent)
            }
        }
        .navigationTitle("Pump")
    }
}

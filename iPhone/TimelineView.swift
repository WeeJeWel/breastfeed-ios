import SwiftUI
import UIKit

private struct TimelineSlot: Hashable {
    let day: Date
    let index: Int
}

struct TimelineView: View {
    @EnvironmentObject private var store: FeedingStore
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var dayAnchor = Calendar.current.startOfDay(for: Date())
    @State private var firstLoadedDay = Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: Date()))!
    @State private var lastLoadedDay = Calendar.current.startOfDay(for: Date())
    @State private var visibleSlot: TimelineSlot?
    @State private var restoringSlot: TimelineSlot?
    @State private var restoreAnchor = UnitPoint.top
    @State private var scrollMeasurements = TimelineScrollMeasurements()
    @State private var requestedDay: Date?
    @State private var calendarDay = Date()
    @State private var scrollReady = false
    @State private var userIsScrolling = false
    @State private var now = Date()
    @State private var calendarHeight: CGFloat = 420
    @State private var showingNew = false
    @State private var newFeedingStart: Date?
    @State private var showingSettings = false
    @State private var showingCalendar = false
    @State private var editingEvent: FeedingEvent?
    @State private var deletingEvent: FeedingEvent?
    @State private var confirmingDelete = false
    @State private var exportURL: URL?
    @State private var showingExport = false
    @State private var showingBabyName = false
    @State private var managingBaby: FeedingJournal?
    @State private var babyName = ""

    private var days: [Date] {
        (-30...0).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: dayAnchor) }
            .filter { $0 < Calendar.current.startOfDay(for: now) }
    }
    private var slots: [TimelineSlot] {
        let today = Calendar.current.startOfDay(for: now)
        let count = Calendar.current.dateComponents([.day], from: firstLoadedDay, to: min(lastLoadedDay, today)).day ?? 0
        return (0...max(0, count)).flatMap { offset -> [TimelineSlot] in
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: firstLoadedDay) else { return [] }
            let lastSlot = day == today
                ? Calendar.current.component(.hour, from: now) * 2 + Calendar.current.component(.minute, from: now) / 30
                : 47
            return (0...lastSlot).map { TimelineSlot(day: day, index: $0) }
        }
    }

    var body: some View {
        let eventsBySlot = Dictionary(grouping: store.events) { event in
            TimelineSlot(day: Calendar.current.startOfDay(for: event.startedAt), index: Calendar.current.component(.hour, from: event.startedAt) * 2 + Calendar.current.component(.minute, from: event.startedAt) / 30)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Menu {
                    ForEach(store.journals) { journal in
                        Button {
                            store.selectedJournalID = journal.uuid.uuidString
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            Label {
                                Text(journal.name + (journal.objectID.persistentStore == store.sharedStore ? String(localized: " · Shared") : ""))
                            } icon: {
                                if journal.uuid == store.activeJournal?.uuid {
                                    Image(systemName: "checkmark")
                                } else {
                                    // Native menus extract the image and ignore SwiftUI opacity.
                                    Image(uiImage: UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in })
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        babyName = ""
                        showingBabyName = true
                    } label: { Label("New Baby", systemImage: "plus") }
                    .accessibilityLabel("New Baby")
                } label: {
                    HStack(spacing: 6) {
                        Text(store.activeJournal?.name ?? String(localized: "Our baby"))
                            .font(.system(.headline, design: .rounded)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("babyPicker")
                .accessibilityLabel("Baby, \(store.activeJournal?.name ?? String(localized: "Our baby"))")
                Spacer()
                Button {
                    calendarDay = selectedDay
                    showingCalendar = true
                } label: {
                    Image(systemName: "calendar").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Choose a date")
                Menu {
                    Button {
                        managingBaby = store.activeJournal
                    } label: { Label("Manage Baby", systemImage: "person.crop.circle") }
                    .disabled(store.activeJournal == nil)
                    Button { showingSettings = true } label: {
                        Label(store.sharedStore != nil && store.activeJournal?.objectID.persistentStore == store.sharedStore ? String(localized: "Participants") : String(localized: "Invite Partner"), systemImage: "person.2")
                    }
                    .disabled(store.activeJournal == nil)
                    Button {
                        do { exportURL = try store.exportCSV(); showingExport = true }
                        catch { store.errorMessage = error.localizedDescription }
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("More options")
            }
            .foregroundStyle(Palette.cream)
            .padding(.leading, 20).padding(.trailing, 8)

            ScrollViewReader { proxy in
                HStack(spacing: 4) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(days, id: \.self) { day in
                                let selected = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                                Button { requestedDay = day } label: {
                                    Text(day.formatted(.dateTime.month(.abbreviated).day()))
                                        .font(.subheadline.weight(selected ? .semibold : .regular))
                                        .padding(.horizontal, 14).frame(height: 40)
                                        .background(selected ? Palette.accent : .clear, in: Capsule())
                                        .foregroundStyle(selected ? Palette.background : Palette.muted)
                                }
                                .id(day)
                                .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                                .accessibilityAddTraits(selected ? [.isSelected] : [])
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { if let day = days.last { proxy.scrollTo(day, anchor: .trailing) } }
                    .onChange(of: selectedDay) { _, day in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Calendar.current.isDateInToday(day) ? days.last ?? day : day, anchor: Calendar.current.isDateInToday(day) ? .trailing : .center)
                        }
                    }
                    .onChange(of: dayAnchor) { _, _ in
                        proxy.scrollTo(Calendar.current.isDateInToday(selectedDay) ? days.last ?? selectedDay : selectedDay, anchor: Calendar.current.isDateInToday(selectedDay) ? .trailing : .center)
                    }
                    Button {
                        now = Date()
                        dayAnchor = Calendar.current.startOfDay(for: now)
                        requestedDay = dayAnchor
                        Task { @MainActor in
                            await Task.yield()
                            if let day = days.last { proxy.scrollTo(day, anchor: .trailing) }
                        }
                    } label: {
                        Text("Today")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 40)
                            .background(Calendar.current.isDate(selectedDay, inSameDayAs: now) ? Palette.accent : Palette.surface, in: Capsule())
                            .foregroundStyle(Calendar.current.isDate(selectedDay, inSameDayAs: now) ? Palette.background : Palette.accent)
                    }
                    .accessibilityIdentifier("today")
                    .padding(.trailing, 16)
                }
            }
            .padding(.vertical, 6)

            ScrollViewReader { timelineProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(slots, id: \.self) { slot in
                            slotRow(slot, events: eventsBySlot[slot] ?? [])
                                .padding(.horizontal, 16)
                                .background {
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 10) {
                                            guard let start = Calendar.current.date(bySettingHour: slot.index / 2,
                                                                                   minute: slot.index % 2 * 30,
                                                                                   second: 0, of: slot.day) else { return }
                                            newFeedingStart = start
                                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                            showingNew = true
                                        }
                                }
                                .id(slot)
                                .onGeometryChange(for: CGRect.self) { geometry in
                                    geometry.frame(in: .named("timeline"))
                                } action: { frame in
                                    scrollMeasurements.frames[slot] = frame
                                    if restoringSlot == nil, frame.minY <= 1, frame.maxY > 1, visibleSlot != slot {
                                        visibleSlot = slot
                                    }
                                }
                        }
                    }
                    .onChange(of: slots) { _, _ in
                        guard let slot = restoringSlot else { return }
                        Task { @MainActor in
                            await Task.yield()
                            timelineProxy.scrollTo(slot, anchor: restoreAnchor)
                            await Task.yield()
                            restoringSlot = nil
                        }
                    }
                }
                .coordinateSpace(name: "timeline")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    scrollMeasurements.viewportHeight = $0
                }
                .scrollIndicators(.hidden)
                .modifier(TimelineSwipeActionsContainer())
                .modifier(TimelineScrollPhaseObserver(onInteraction: {
                    userIsScrolling = true
                }, onIdle: {
                    guard userIsScrolling, restoringSlot == nil, let slot = visibleSlot,
                          let frame = scrollMeasurements.frames[slot] else { return }
                    if selectedDay != slot.day {
                        selectedDay = slot.day
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    if !Calendar.current.isDateInToday(slot.day) && !days.contains(slot.day) {
                        dayAnchor = min(Calendar.current.startOfDay(for: now), Calendar.current.date(byAdding: .day, value: 7, to: slot.day)!)
                    }
                    let earlierThreshold = Calendar.current.date(byAdding: .day, value: 1, to: firstLoadedDay)!
                    let laterThreshold = Calendar.current.date(byAdding: .day, value: -1, to: lastLoadedDay)!
                    let today = Calendar.current.startOfDay(for: now)
                    guard slot.day <= earlierThreshold || (slot.day >= laterThreshold && lastLoadedDay < today) else { return }
                    // Change the loaded window only at rest; preserve the row's exact screen position.
                    let availableHeight = scrollMeasurements.viewportHeight - frame.height
                    restoreAnchor = UnitPoint(x: 0, y: availableHeight > 0 ? frame.minY / availableHeight : 0)
                    restoringSlot = slot
                    if slot.day <= earlierThreshold {
                        firstLoadedDay = Calendar.current.date(byAdding: .day, value: -7, to: firstLoadedDay)!
                        lastLoadedDay = min(lastLoadedDay, Calendar.current.date(byAdding: .day, value: 7, to: slot.day)!)
                    } else {
                        lastLoadedDay = min(today, Calendar.current.date(byAdding: .day, value: 7, to: lastLoadedDay)!)
                        firstLoadedDay = max(firstLoadedDay, Calendar.current.date(byAdding: .day, value: -7, to: slot.day)!)
                    }
                    scrollMeasurements.frames = scrollMeasurements.frames.filter { $0.key.day >= firstLoadedDay && $0.key.day <= lastLoadedDay }
                }))
                .task {
                    timelineProxy.scrollTo(TimelineSlot(day: selectedDay, index: max(0, Calendar.current.component(.hour, from: now) * 2 + Calendar.current.component(.minute, from: now) / 30 - 2)), anchor: .top)
                    await Task.yield()
                    scrollReady = true
                }
                .onChange(of: visibleSlot) { _, slot in
                    guard scrollReady, restoringSlot == nil, let slot else { return }
                    if userIsScrolling && selectedDay != slot.day {
                        selectedDay = slot.day
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    if !Calendar.current.isDateInToday(slot.day) && !days.contains(slot.day) {
                        dayAnchor = min(Calendar.current.startOfDay(for: Date()), Calendar.current.date(byAdding: .day, value: 7, to: slot.day)!)
                    }
                }
                .onChange(of: requestedDay) { _, day in
                    guard let day else { return }
                    now = Date()
                    let target = min(Calendar.current.startOfDay(for: day), Calendar.current.startOfDay(for: now))
                    userIsScrolling = false
                    if selectedDay != target {
                        selectedDay = target
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    if target <= firstLoadedDay || target > lastLoadedDay {
                        firstLoadedDay = Calendar.current.date(byAdding: .day, value: -3, to: target)!
                        lastLoadedDay = min(Calendar.current.startOfDay(for: now), Calendar.current.date(byAdding: .day, value: 3, to: target)!)
                        scrollMeasurements.frames.removeAll()
                    }
                    if !Calendar.current.isDateInToday(target) && !days.contains(target) {
                        dayAnchor = min(Calendar.current.startOfDay(for: Date()), Calendar.current.date(byAdding: .day, value: 7, to: target)!)
                    }
                    let slot = Calendar.current.isDateInToday(target)
                        ? max(0, Calendar.current.component(.hour, from: now) * 2 + Calendar.current.component(.minute, from: now) / 30 - 2)
                        : store.events.first(where: { Calendar.current.isDate($0.startedAt, inSameDayAs: target) })
                            .map { Calendar.current.component(.hour, from: $0.startedAt) * 2 + Calendar.current.component(.minute, from: $0.startedAt) / 30 } ?? 0
                    Task { @MainActor in
                        await Task.yield()
                        timelineProxy.scrollTo(TimelineSlot(day: target, index: slot), anchor: .top)
                        requestedDay = nil
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .background(Palette.background)
        .foregroundStyle(Palette.cream)
        .safeAreaInset(edge: .bottom, spacing: 0) { feedingBar }
        .alert("New Baby", isPresented: $showingBabyName) {
            TextField("Baby name", text: $babyName)
                .textInputAutocapitalization(.words)
            Button("Add") {
                do {
                    try store.createBaby(name: babyName)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch { store.errorMessage = error.localizedDescription }
            }
            .disabled(babyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Feeding?", isPresented: $confirmingDelete, presenting: deletingEvent) { event in
            Button("Delete Feeding", role: .destructive) {
                guard !event.isDeleted else { deletingEvent = nil; return }
                do {
                    try store.delete(event)
                    deletingEvent = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch { store.errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { deletingEvent = nil }
        }
        .onChange(of: store.events) { _, events in
            if let editingEvent, !events.contains(where: { $0.objectID == editingEvent.objectID }) {
                self.editingEvent = nil
            }
        }
        .onChange(of: store.newFeedingRequested, initial: true) { _, requested in
            guard requested else { return }
            newFeedingStart = nil
            showingBabyName = false
            confirmingDelete = false
            if editingEvent != nil || managingBaby != nil || showingSettings || showingExport || showingCalendar {
                editingEvent = nil
                managingBaby = nil
                showingSettings = false
                showingExport = false
                showingCalendar = false
            } else {
                showingNew = true
                store.newFeedingRequested = false
            }
        }
        .sheet(isPresented: $showingNew, onDismiss: { newFeedingStart = nil }) {
            FeedingEditor(event: nil,
                          suggestedSide: store.events.last(where: { $0.kind == .breast })?.side?.opposite ?? .left,
                          suggestedStart: newFeedingStart)
                .environmentObject(store)
        }
        .sheet(item: $managingBaby, onDismiss: {
            if store.newFeedingRequested { showingNew = true; store.newFeedingRequested = false }
        }) { baby in BabyEditor(journal: baby).environmentObject(store) }
        .sheet(item: $editingEvent, onDismiss: {
            if store.newFeedingRequested { showingNew = true; store.newFeedingRequested = false }
        }) { event in
            if event.managedObjectContext != nil && !event.isDeleted {
                FeedingEditor(event: event).environmentObject(store)
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            if store.newFeedingRequested { showingNew = true; store.newFeedingRequested = false }
        }) {
            SharingView(journalID: store.activeJournal?.objectID,
                        babyName: store.activeJournal?.name ?? String(localized: "Our baby"),
                        isSharedJournal: store.sharedStore != nil && store.activeJournal?.objectID.persistentStore == store.sharedStore)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingExport, onDismiss: {
            if store.newFeedingRequested { showingNew = true; store.newFeedingRequested = false }
        }) { if let exportURL { ExportSheet(url: exportURL) } }
        .sheet(isPresented: $showingCalendar, onDismiss: {
            if store.newFeedingRequested { showingNew = true; store.newFeedingRequested = false }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                FeedingCalendar(selectedDay: calendarDay,
                                eventDays: Set(store.events.map { Calendar.current.startOfDay(for: $0.startedAt) })) { day in
                    requestedDay = day
                    showingCalendar = false
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { calendarHeight = ceil($0) }
            .presentationDetents([.height(calendarHeight)])
            .presentationBackground(Palette.background)
            .presentationDragIndicator(.visible)
        }
    }

    private var feedingBar: some View {
        VStack(spacing: 10) {
            if let event = store.runningEvent, let running = store.running {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if event.journal?.uuid != store.activeJournal?.uuid {
                            Text(event.journal?.name ?? String(localized: "Our baby"))
                                .font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        Text((event.side ?? .left).breastTitle).font(.caption).foregroundStyle(Palette.muted)
                        Text(running.startedAt, style: .timer)
                            .font(.system(.body, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Palette.accent)
                            .frame(width: 76, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    Button {
                        do {
                            try store.finish(eventID: event.uuid)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } catch { store.errorMessage = error.localizedDescription }
                    } label: {
                        Text("Done").lineLimit(1).padding(.vertical, 4)
                    }
                    Button {
                        do {
                            try store.finish(eventID: event.uuid, switchSide: true)
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        } catch { store.errorMessage = error.localizedDescription }
                    } label: {
                        Text((event.side ?? .left).opposite.switchTitle)
                            .lineLimit(1).minimumScaleFactor(0.65).padding(.vertical, 4)
                    }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Palette.accent)
            }
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                newFeedingStart = nil
                showingNew = true
            } label: {
                Label("New Feeding", systemImage: "plus")
                    .font(.system(.headline, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(Palette.background)
                    .background(Palette.accent, in: Capsule())
            }
            .accessibilityIdentifier("newFeeding")
            if let last = store.lastFeeding {
                SwiftUI.TimelineView(.periodic(from: last.startedAt, by: 60)) { context in
                    let elapsed = Duration.seconds(max(0, context.date.timeIntervalSince(last.startedAt)))
                        .formatted(.units(allowed: [.hours, .minutes], width: .wide, fractionalPart: .hide(rounded: .towardZero)))
                    Text("\(elapsed) since last feeding")
                        .font(.caption).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                }
                .accessibilityIdentifier("timeSinceLastFeeding")
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(Palette.background)
    }

    private func slotRow(_ slot: TimelineSlot, events: [FeedingEvent]) -> some View {
        let current = Calendar.current.isDateInToday(slot.day) && (Calendar.current.component(.hour, from: now) * 2 + Calendar.current.component(.minute, from: now) / 30) == slot.index
        return VStack(alignment: .leading, spacing: 0) {
            if slot.index == 0 {
                Text(slot.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption.weight(.medium)).foregroundStyle(Palette.muted)
                    .padding(.top, 20).padding(.bottom, 12)
            }
            HStack(alignment: .top, spacing: 10) {
                Text(String(format: "%02d:%02d", slot.index / 2, slot.index % 2 * 30))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(current ? Palette.accent : Palette.muted)
                    .frame(width: 38, alignment: .leading).padding(.top, 12)
                VStack(spacing: 6) {
                    if events.isEmpty {
                        Rectangle().fill(Palette.elevated.opacity(0.55)).frame(height: 1).padding(.top, 18)
                    } else {
                        ForEach(events) { event in
                            Button { editingEvent = event } label: {
                                HStack(spacing: 10) {
                                    FeedingEventSymbol(kind: event.kind, side: event.side, size: 30)
                                        .foregroundStyle(Palette.accent)
                                        .frame(width: 34).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.cream)
                                        HStack(spacing: 4) {
                                            Text(event.startedAt, format: .dateTime.hour().minute())
                                            if let volume = event.volume { Text("· \(volume.doubleValue.formatted()) ml") }
                                            if let minutes = event.wholeMinutes { Text("· \(minutes) min") }
                                            if store.running?.eventID == event.uuid {
                                                Circle().fill(Palette.accent).frame(width: 5, height: 5).accessibilityLabel("Running")
                                            }
                                        }
                                        .font(.caption).foregroundStyle(Palette.muted)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Edit feeding. Changes save automatically.")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Deletion happens only after confirmation; keep the card
                                // in place if the alert is cancelled.
                                Button {
                                    deletingEvent = event
                                    confirmingDelete = true
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .accessibilityAction(named: "Delete Feeding") {
                                deletingEvent = event
                                confirmingDelete = true
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.bottom, 8)
            }
            .frame(minHeight: 54, alignment: .top)
        }
    }
}

struct ExportSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct TimelineSwipeActionsContainer: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.swipeActionsContainer()
        } else {
            content
        }
    }
}

private final class TimelineScrollMeasurements {
    var frames: [TimelineSlot: CGRect] = [:]
    var viewportHeight: CGFloat = 0
}

private struct TimelineScrollPhaseObserver: ViewModifier {
    let onInteraction: () -> Void
    let onIdle: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting { onInteraction() }
                if phase == .idle { onIdle() }
            }
        } else {
            content.simultaneousGesture(DragGesture()
                .onChanged { _ in onInteraction() }
                .onEnded { _ in onIdle() })
        }
    }
}

private struct FeedingCalendar: UIViewRepresentable {
    let selectedDay: Date
    let eventDays: Set<Date>
    let onSelect: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(eventDays: eventDays, onSelect: onSelect) }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = .current
        view.locale = .current
        view.timeZone = .current
        view.tintColor = UIColor(Palette.accent)
        view.availableDateRange = DateInterval(start: .distantPast, end: Date())
        view.delegate = context.coordinator
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.selectionBehavior = selection
        let components = Calendar.current.dateComponents([.calendar, .year, .month, .day], from: min(selectedDay, Date()))
        selection.setSelected(components, animated: false)
        view.setVisibleDateComponents(components, animated: false)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let size = uiView.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                                                withHorizontalFittingPriority: .required,
                                                verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: size.height)
    }

    func updateUIView(_ uiView: UICalendarView, context: Context) {
        context.coordinator.onSelect = onSelect
        let changedDays = context.coordinator.eventDays.symmetricDifference(eventDays)
        context.coordinator.eventDays = eventDays
        if !changedDays.isEmpty {
            uiView.reloadDecorations(forDateComponents: changedDays.map {
                Calendar.current.dateComponents([.calendar, .year, .month, .day], from: $0)
            }, animated: true)
        }
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var eventDays: Set<Date>
        var onSelect: (Date) -> Void

        init(eventDays: Set<Date>, onSelect: @escaping (Date) -> Void) {
            self.eventDays = eventDays
            self.onSelect = onSelect
        }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = calendarView.calendar.date(from: dateComponents),
                  eventDays.contains(calendarView.calendar.startOfDay(for: date)) else { return nil }
            return .default(color: UIColor(Palette.accent), size: .small)
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dateComponents, let date = Calendar.current.date(from: dateComponents) else { return }
            onSelect(date)
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
            guard let dateComponents, let date = Calendar.current.date(from: dateComponents) else { return false }
            return date <= Date()
        }
    }
}

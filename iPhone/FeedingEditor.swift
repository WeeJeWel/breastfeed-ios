import SwiftUI
import UIKit

struct FeedingEditor: View {
    @EnvironmentObject private var store: FeedingStore
    @Environment(\.dismiss) private var dismiss
    let event: FeedingEvent?
    @State private var kind: FeedingKind
    @State private var side: FeedingSide
    @State private var start: Date
    @State private var amount: String
    @State private var minutes: String
    @AppStorage("startFeedingTimer") private var startTimer = true
    @State private var contentHeight: CGFloat = 320
    @State private var timeWasEdited = false
    @State private var durationWasEdited = false
    @State private var confirmingDelete = false
    @State private var validationMessage: String?
    @FocusState private var numberFocused: Bool

    init(event: FeedingEvent?, suggestedSide: FeedingSide = .left, suggestedStart: Date? = nil) {
        self.event = event
        _kind = State(initialValue: event?.kind ?? .breast)
        _side = State(initialValue: event?.side ?? suggestedSide)
        _start = State(initialValue: event?.startedAt ?? suggestedStart ?? Date())
        _timeWasEdited = State(initialValue: suggestedStart != nil)
        _amount = State(initialValue: event?.volume.map { $0.doubleValue.formatted(.number.grouping(.never)) } ?? "")
        _minutes = State(initialValue: event?.wholeMinutes.map { $0.formatted(.number.grouping(.never)) } ?? "")
    }

    private var isRunning: Bool {
        // A saved deletion detaches the object and clears its nonoptional UUID
        // before SwiftUI has finished dismissing this sheet.
        guard let event, event.managedObjectContext != nil, !event.isDeleted else { return false }
        return store.running?.eventID == event.uuid
    }
    private var parsedAmount: Double? { try? Double(amount, format: .number.locale(.current)) }
    private var parsedMinutes: Double? { try? Double(minutes, format: .number.locale(.current)) }
    private var fieldsValid: Bool {
        (kind == .breast || amount.isEmpty || (parsedAmount.map { $0.isFinite && $0 >= 0 && $0 <= 10_000 } ?? false))
        && (minutes.isEmpty || (parsedMinutes.map { $0.isFinite && $0.rounded(.towardZero) == $0 && $0 >= 0 && $0 <= 1_440 } ?? false))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        FeedingTypePicker(selection: $kind)
                            .frame(height: 56)
                            .accessibilityIdentifier("feedingType")
                        if kind != .bottle {
                            FeedingSidePicker(selection: $side, sides: kind.sides)
                                .frame(height: 56)
                                .accessibilityIdentifier("feedingSide")
                        } else {
                            Color.clear.frame(height: 56)
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                    }
                    VStack(spacing: 18) {
                        DatePicker("Started", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                        if kind != .breast {
                            Divider().overlay(Palette.elevated)
                            HStack {
                                Label("Milk", systemImage: "drop")
                                Spacer()
                                TextField("Optional", text: $amount)
                                    .multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                                    .frame(maxWidth: 120).focused($numberFocused)
                                    .accessibilityLabel("Milk amount in milliliters")
                                Text("ml").foregroundStyle(Palette.muted)
                            }
                            .frame(minHeight: 32)
                        }
                        if event == nil && kind == .breast {
                            Divider().overlay(Palette.elevated)
                            Toggle("Start Timer", isOn: $startTimer)
                                .frame(minHeight: 32)
                        }
                        if event != nil && !isRunning {
                            Divider().overlay(Palette.elevated)
                            HStack {
                                Label("Duration", systemImage: "timer")
                                Spacer()
                                TextField("Optional", text: Binding(get: { minutes }, set: {
                                    minutes = $0
                                    durationWasEdited = true
                                    persist()
                                }))
                                    .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                                    .frame(maxWidth: 120).focused($numberFocused)
                                    .accessibilityLabel("Duration in minutes")
                                Text("min").foregroundStyle(Palette.muted)
                            }
                        }
                    }
                    .font(.subheadline).padding(18)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))

                    if !fieldsValid {
                        Text("Enter a valid amount (0–10,000 ml) or duration (0–1,440 min). Your last valid value is still saved.")
                            .font(.caption).foregroundStyle(Palette.accent)
                    }
                    if let validationMessage {
                        Text(validationMessage).font(.caption).foregroundStyle(Palette.accent)
                    }
                    if isRunning, let event {
                        Button {
                            do {
                                try store.finish(eventID: event.uuid)
                                minutes = event.wholeMinutes.map { $0.formatted(.number.grouping(.never)) } ?? ""
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            } catch { validationMessage = error.localizedDescription }
                        } label: {
                            Label("Done", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Palette.accent)
                    }
                    if event == nil {
                        Button {
                            do {
                                try store.add(kind: kind, side: side, start: timeWasEdited ? start : Date(),
                                              ml: kind == .breast ? nil : parsedAmount,
                                              startTimer: startTimer)
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            } catch { validationMessage = error.localizedDescription }
                        } label: {
                            Text(kind == .breast && startTimer ? String(localized: "Start Feeding") : String(localized: "Add Feeding"))
                                .font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                                .foregroundStyle(Palette.background)
                                .background(Palette.accent, in: Capsule())
                        }
                        .disabled(!fieldsValid).opacity(fieldsValid ? 1 : 0.5)
                        .accessibilityIdentifier("createFeeding")
                    } else {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete Feeding", systemImage: "trash")
                                .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .tint(Palette.accent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    contentHeight = ceil(height)
                }
            }
            .background(Palette.background)
            .foregroundStyle(Palette.cream)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { numberFocused = false }
                }
            }
            .onChange(of: kind) { _, value in
                if value == .breast && side == .both { side = .left }
                UISelectionFeedbackGenerator().selectionChanged()
                persist()
            }
            .onChange(of: side) { _, _ in UISelectionFeedbackGenerator().selectionChanged(); persist() }
            .onChange(of: start) { _, _ in timeWasEdited = true; persist() }
            .onChange(of: amount) { _, _ in persist() }
            .alert("Delete Feeding?", isPresented: $confirmingDelete) {
                Button("Delete Feeding", role: .destructive) {
                    guard let event, event.managedObjectContext != nil, !event.isDeleted else { dismiss(); return }
                    do {
                        try store.delete(event)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    } catch { validationMessage = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.height(contentHeight)])
        .presentationBackground(Palette.background)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func persist() {
        guard let event, fieldsValid, event.managedObjectContext != nil, !event.isDeleted else { return }
        do {
            try store.update(event, kind: kind, side: side, start: start,
                             ml: kind == .breast ? nil : parsedAmount,
                             duration: isRunning ? nil : (durationWasEdited ? parsedMinutes.map { $0 * 60 } : event.duration?.doubleValue))
            validationMessage = nil
        } catch { validationMessage = error.localizedDescription }
    }
}

// UIKit's segmented control displays either a title or an image. Render both into
// each segment image so the control stays native while showing an icon and text.
private struct FeedingTypePicker: UIViewRepresentable {
    @Binding var selection: FeedingKind

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: FeedingKind.allCases.map(\.title))
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.accessibilityLabel = String(localized: "Feeding type")
        control.accessibilityIdentifier = "feedingType"
        control.apportionsSegmentWidthsByContent = false
        return control
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 56)
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let font = UIFont.systemFont(ofSize: 16, weight: .medium)
        for (index, kind) in FeedingKind.allCases.enumerated() {
            let title = kind.title as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let textSize = title.size(withAttributes: attributes)
            let symbol = (kind != .bottle ? UIImage(named: kind.symbol) : UIImage(systemName: kind.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(textSize.width) + 26, height: 24)).image { _ in
                symbol?.draw(in: CGRect(x: 0, y: 3, width: 18, height: 18))
                title.draw(at: CGPoint(x: 24, y: (24 - textSize.height) / 2), withAttributes: attributes)
            }
            let segmentImage = image.withRenderingMode(.alwaysOriginal)
            segmentImage.accessibilityLabel = kind.title
            control.setImage(segmentImage, forSegmentAt: index)
        }
        control.selectedSegmentIndex = FeedingKind.allCases.firstIndex(of: selection) ?? 0
        control.accessibilityValue = selection.title
    }

    final class Coordinator: NSObject {
        var selection: Binding<FeedingKind>
        init(selection: Binding<FeedingKind>) { self.selection = selection }
        @objc func changed(_ sender: UISegmentedControl) {
            guard FeedingKind.allCases.indices.contains(sender.selectedSegmentIndex) else { return }
            selection.wrappedValue = FeedingKind.allCases[sender.selectedSegmentIndex]
        }
    }
}

private struct FeedingSidePicker: UIViewRepresentable {
    @Binding var selection: FeedingSide
    let sides: [FeedingSide]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, sides: sides) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: sides.map(\.title))
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 16, weight: .medium)], for: .normal)
        control.accessibilityLabel = String(localized: "Side")
        control.accessibilityIdentifier = "feedingSide"
        return control
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 56)
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.sides = sides
        if control.numberOfSegments != sides.count {
            control.removeAllSegments()
            for (index, side) in sides.enumerated() {
                control.insertSegment(withTitle: side.title, at: index, animated: false)
            }
        }
        let font = UIFont.systemFont(ofSize: 16, weight: .medium)
        for (index, side) in sides.enumerated() {
            let title = side.title as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let textSize = title.size(withAttributes: attributes)
            let left = UIImage(named: side == .right ? "BreastLeftInactive" : "BreastLeft")?.withTintColor(UIColor(Palette.accent), renderingMode: .alwaysOriginal)
            let right = UIImage(named: side == .left ? "BreastRightInactive" : "BreastRight")?.withTintColor(UIColor(Palette.accent), renderingMode: .alwaysOriginal)
            let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(textSize.width) + 34, height: 24)).image { _ in
                let iconRect = CGRect(x: 0, y: 0, width: 28, height: 24)
                left?.draw(in: iconRect)
                right?.draw(in: iconRect)
                title.draw(at: CGPoint(x: 34, y: (24 - textSize.height) / 2), withAttributes: attributes)
            }.withRenderingMode(.alwaysOriginal)
            image.accessibilityLabel = side.title
            control.setImage(image, forSegmentAt: index)
        }
        control.selectedSegmentIndex = sides.firstIndex(of: selection) ?? 0
        control.accessibilityValue = selection.title
    }

    final class Coordinator: NSObject {
        var selection: Binding<FeedingSide>
        var sides: [FeedingSide]
        init(selection: Binding<FeedingSide>, sides: [FeedingSide]) {
            self.selection = selection
            self.sides = sides
        }
        @objc func changed(_ sender: UISegmentedControl) {
            guard sides.indices.contains(sender.selectedSegmentIndex) else { return }
            selection.wrappedValue = sides[sender.selectedSegmentIndex]
        }
    }
}

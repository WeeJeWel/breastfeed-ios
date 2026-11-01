import CloudKit
import CoreData
import XCTest
import SwiftUI
@testable import BreastFeed

@MainActor
final class FeedingStoreTests: XCTestCase {
    var store: FeedingStore!
    var suite: String!

    override func setUp() async throws {
        suite = "BreastFeedTests.\(UUID().uuidString)"
        store = FeedingStore(inMemory: true, defaults: UserDefaults(suiteName: suite)!)
    }
    override func tearDown() async throws {
        store = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func testSharingUnavailableNeverCreatesBabyOrChangesSelection() async throws {
        let first = try store.createBaby(name: "Alex")
        let event = try store.add(kind: .bottle, ml: 60)
        let second = try store.createBaby(name: "Sam")
        do {
            _ = try await store.prepareShare(for: first.objectID)
            XCTFail("A local-only store must not start CloudKit sharing")
        } catch {
            XCTAssertTrue(store.shareRequests.isEmpty)
        }
        store.refresh()
        XCTAssertEqual(store.journals.count, 2)
        XCTAssertEqual(store.activeJournal, second)
        XCTAssertEqual(event.journal, first)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testReopeningSharingJoinsPendingRequestEvenAfterWaiterIsCancelled() async throws {
        let baby = try store.createBaby(name: "Alex")
        var completion: CheckedContinuation<CKShare, Error>?
        let pending = Task<CKShare, Error> {
            try await withCheckedThrowingContinuation { completion = $0 }
        }
        store.shareRequests[baby.objectID] = pending
        let first = Task { try await store.prepareShare(for: baby.objectID) }
        await Task.yield()
        first.cancel()
        let second = Task { try await store.prepareShare(for: baby.objectID) }
        // Resolve only after the background operation has started.
        while completion == nil { await Task.yield() }
        XCTAssertFalse(pending.isCancelled)
        completion?.resume(throwing: NSError(domain: "SharingTest", code: 42))
        for waiter in [first, second] {
            do { _ = try await waiter.value; XCTFail("Expected the shared operation's result") }
            catch { XCTAssertEqual((error as NSError).domain, "SharingTest") }
        }
        XCTAssertEqual(store.journals.count, 1)
        XCTAssertEqual(store.activeJournal, baby)
        XCTAssertTrue(store.events.isEmpty)
        store.shareRequests[baby.objectID] = nil
    }

    func testJSONExportsSelectedBabyAndRoundTripsWithoutStartingTimer() throws {
        let first = try store.createBaby(name: "Alex")
        let start = Date(timeIntervalSince1970: 1_700_000_000.123)
        let breast = try store.add(kind: .breast, side: .right, start: start)
        try store.update(breast, kind: .breast, side: .right, start: start, ml: nil, duration: 93.5)
        let second = try store.createBaby(name: "Sam")
        let pump = try store.add(kind: .pump, side: .both, start: start.addingTimeInterval(60), ml: 75.5)
        let bottle = try store.add(kind: .bottle, start: start.addingTimeInterval(120), ml: 90)
        try store.update(bottle, kind: .bottle, side: .left, start: bottle.startedAt, ml: 90, duration: 120)
        let secondData = try Data(contentsOf: store.exportJSON())
        store.selectedJournalID = first.uuid.uuidString
        let firstData = try Data(contentsOf: store.exportJSON())
        let target = FeedingStore(inMemory: true, defaults: store.defaults)
        XCTAssertEqual(try target.importJSON(firstData), 1)
        XCTAssertEqual(target.journals.map(\.uuid), [first.uuid])
        XCTAssertNil(target.running)
        XCTAssertEqual(target.events.first?.startedAt.timeIntervalSince1970 ?? 0, start.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(target.events.first?.duration?.doubleValue, 93.5)
        XCTAssertEqual(target.events.first?.side, .right)
        XCTAssertEqual(try target.importJSON(secondData), 2)
        XCTAssertEqual(target.journals.map(\.uuid), [first.uuid, second.uuid])
        XCTAssertEqual(target.activeJournal?.uuid, second.uuid)
        XCTAssertEqual(target.events.map(\.uuid), [pump.uuid, bottle.uuid])
        XCTAssertEqual(target.events[0].volume?.doubleValue, 75.5)
        XCTAssertEqual(target.events[0].side, .both)
        XCTAssertNil(target.events[1].side)
        XCTAssertEqual(target.events[1].duration?.doubleValue, 120)
    }

    func testJSONRepeatedImportKeepsExistingEditsAndDoesNotDuplicate() throws {
        let baby = try store.createBaby(name: "Alex")
        let event = try store.add(kind: .bottle, ml: 60)
        let data = try Data(contentsOf: store.exportJSON())
        try store.renameBaby(baby, name: "New name")
        try store.update(event, kind: .bottle, side: .left, start: event.startedAt, ml: 90, duration: nil)
        XCTAssertEqual(try store.importJSON(data), 0)
        XCTAssertEqual(try store.importJSON(data), 0)
        XCTAssertEqual(store.journals.count, 1)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(baby.name, "New name")
        XCTAssertEqual(event.volume?.doubleValue, 90)
    }

    func testJSONRejectsInvalidOrConflictingBackupWithoutPartialImport() throws {
        let baby = try store.createBaby(name: "Alex")
        let event = try store.add(kind: .bottle, ml: 60)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let original = try decoder.decode(FeedingBackup.self, from: Data(contentsOf: store.exportJSON()))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var badVersion = original
        badVersion.schemaVersion = 999
        var badAmount = original
        badAmount.babies[0].id = UUID()
        badAmount.babies[0].feedings[0].id = UUID()
        badAmount.babies[0].feedings[0].ml = -1
        var conflict = original
        conflict.babies[0].id = UUID()
        var repeatedID = original
        repeatedID.babies.append(original.babies[0])
        for backup in [badVersion, badAmount, conflict, repeatedID] {
            XCTAssertThrowsError(try store.importJSON(encoder.encode(backup)))
            XCTAssertFalse(store.container.viewContext.hasChanges)
            XCTAssertEqual(store.journals.map(\.uuid), [baby.uuid])
            XCTAssertEqual(store.events.map(\.uuid), [event.uuid])
        }
        XCTAssertThrowsError(try store.importJSON(Data("not a backup".utf8)))
        XCTAssertFalse(store.container.viewContext.hasChanges)
    }

    func testJSONImportDoesNotMergeDifferentBabiesWithSameName() throws {
        let baby = try store.createBaby(name: "Alex")
        try store.add(kind: .breast, startTimer: false)
        let data = try Data(contentsOf: store.exportJSON())
        let target = FeedingStore(inMemory: true, defaults: store.defaults)
        let other = try target.createBaby(name: "Alex")
        XCTAssertEqual(try target.importJSON(data), 1)
        XCTAssertEqual(target.journals.count, 2)
        XCTAssertEqual(target.activeJournal?.uuid, baby.uuid)
        target.selectedJournalID = other.uuid.uuidString
        XCTAssertTrue(target.events.isEmpty)
    }

    func testNewBreastfeedingStartsTimerWithoutDuration() throws {
        let event = try store.add(kind: .breast, side: .left)
        XCTAssertEqual(store.running?.eventID, event.uuid)
        XCTAssertNil(event.duration)
        XCTAssertEqual(store.events.count, 1)
    }

    func testSwitchSavesPreviousDurationAndStartsOppositeSide() throws {
        let start = Date().addingTimeInterval(-120)
        let left = try store.add(kind: .breast, side: .left, start: start)
        try store.finish(eventID: left.uuid, switchSide: true, now: start.addingTimeInterval(90))
        XCTAssertEqual(left.duration?.doubleValue, 90)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.runningEvent?.side, .right)
        XCTAssertNil(store.runningEvent?.duration)
        XCTAssertEqual(store.runningEvent?.journal, left.journal)
    }

    func testStopCommitsDurationAndClearsTimer() throws {
        let start = Date().addingTimeInterval(-600)
        let event = try store.add(kind: .breast, start: start)
        try store.finish(eventID: event.uuid, now: start.addingTimeInterval(600))
        XCTAssertEqual(event.duration?.doubleValue, 600)
        XCTAssertNil(store.running)
    }

    func testStartingAnotherFeedingDiscardsUnfinishedDuration() throws {
        let previous = try store.add(kind: .breast, start: Date().addingTimeInterval(-60))
        let next = try store.add(kind: .breast, side: .right)
        XCTAssertNil(previous.duration)
        XCTAssertEqual(store.running?.eventID, next.uuid)
        XCTAssertEqual(store.events.count, 2)
    }

    func testBottleAndPumpNeverStartTimers() throws {
        let previous = try store.add(kind: .breast)
        let bottle = try store.add(kind: .bottle, ml: 90)
        XCTAssertNil(store.running)
        XCTAssertNil(previous.duration)
        XCTAssertNil(bottle.side)
        XCTAssertEqual(bottle.volume?.doubleValue, 90)
        let pump = try store.add(kind: .pump, side: .both, ml: 120)
        XCTAssertNil(store.running)
        XCTAssertEqual(pump.side, .both)
    }

    func testDiscardRetainsEventAndNoDuration() throws {
        let event = try store.add(kind: .breast)
        store.setRunning(nil)
        XCTAssertNil(event.duration)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertNil(store.defaults.data(forKey: "runningFeed"))
    }

    func testStaleLockScreenActionCannotStopAnotherFeeding() throws {
        let previous = try store.add(kind: .breast)
        let next = try store.add(kind: .breast, side: .right)
        XCTAssertThrowsError(try store.finish(eventID: previous.uuid, switchSide: true))
        XCTAssertEqual(store.running?.eventID, next.uuid)
        XCTAssertNil(previous.duration)
        XCTAssertEqual(store.events.count, 2)
    }

    func testDuplicateStopCannotOverwriteDuration() throws {
        let event = try store.add(kind: .breast, start: Date().addingTimeInterval(-60))
        try store.finish(eventID: event.uuid)
        let saved = event.duration
        XCTAssertThrowsError(try store.finish(eventID: event.uuid))
        XCTAssertEqual(event.duration, saved)
    }

    func testEditingStartUpdatesTimerAndPreservesMissingDuration() throws {
        let event = try store.add(kind: .breast)
        let earlier = Date().addingTimeInterval(-300)
        try store.update(event, kind: .breast, side: .right, start: earlier, ml: nil, duration: nil)
        XCTAssertEqual(store.running?.startedAt, earlier)
        XCTAssertEqual(event.side, .right)
        XCTAssertNil(event.duration)
    }

    func testChangingTypeDiscardsTimerAndClearsSide() throws {
        let event = try store.add(kind: .breast)
        try store.update(event, kind: .bottle, side: .left, start: event.startedAt, ml: 85, duration: nil)
        XCTAssertNil(store.running)
        XCTAssertNil(event.side)
        XCTAssertEqual(event.volume?.doubleValue, 85)
    }

    func testDeletingActiveFeedingClearsTimer() throws {
        let event = try store.add(kind: .breast)
        try store.delete(event)
        XCTAssertNil(store.running)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testInvalidInputDoesNotMutateStoredEvent() throws {
        let event = try store.add(kind: .bottle, ml: 80)
        XCTAssertThrowsError(try store.update(event, kind: .bottle, side: .left, start: event.startedAt, ml: -1, duration: nil))
        XCTAssertEqual(event.volume?.doubleValue, 80)
        XCTAssertThrowsError(try store.add(kind: .breast, side: .both))
        XCTAssertThrowsError(try store.add(kind: .bottle, ml: .nan))
        XCTAssertThrowsError(try store.add(kind: .bottle, start: Date().addingTimeInterval(3600)))
        XCTAssertEqual(store.events.count, 1)
    }

    func testHistoricalFeedingCanBeAddedWithoutTimer() throws {
        let event = try store.add(kind: .breast, start: Date().addingTimeInterval(-86_400), startTimer: false)
        XCTAssertNil(store.running)
        XCTAssertNil(event.duration)
    }

    func testCSVPreservesBlankValuesAndSortsChronologically() throws {
        let start = Date(timeIntervalSince1970: 0)
        let csv = FeedingCSV.string(rows: [
            (UUID(), start.addingTimeInterval(60), .bottle, nil, 90.5, nil),
            (UUID(), start, .breast, .left, nil, 120)
        ])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "id,start_time_utc,type,side,volume_ml,duration_seconds")
        XCTAssertTrue(lines[1].contains("1970-01-01T00:00:00.000Z"))
        XCTAssertTrue(lines[1].hasSuffix("\"Breast\",\"Left\",\"\",\"120\""))
        XCTAssertTrue(lines[2].hasSuffix("\"Bottle\",\"\",\"90.5\",\"\""))
    }

    func testExportUsesWholeJournalAndIncludesPump() throws {
        try store.add(kind: .breast, start: Date().addingTimeInterval(-86_400), startTimer: false)
        try store.add(kind: .pump, side: .both, ml: 100)
        let url = try store.exportCSV()
        let csv = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(csv.contains("\"Pump\",\"Both\",\"100.0\",\"\""))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 4)
    }

    func testRefreshUsesEditedStartAndStopsExternallyCompletedTimer() throws {
        let event = try store.add(kind: .breast)
        event.startedAt = Date().addingTimeInterval(-90)
        try store.container.viewContext.save()
        store.refresh()
        XCTAssertEqual(store.running?.startedAt, event.startedAt)
        event.duration = 90
        try store.container.viewContext.save()
        store.refresh()
        XCTAssertNil(store.running)
    }

    func testBabiesKeepSeparateHistoriesAndRememberSelection() throws {
        let first = try store.createBaby(name: "  Alex  ")
        let firstEvent = try store.add(kind: .breast, side: .right, startTimer: false)
        let second = try store.createBaby(name: "Sam")
        XCTAssertTrue(store.events.isEmpty)
        let secondEvent = try store.add(kind: .bottle, ml: 75)
        XCTAssertEqual(store.events.map(\.uuid), [secondEvent.uuid])
        XCTAssertEqual(secondEvent.journal, second)
        store.selectedJournalID = first.uuid.uuidString
        XCTAssertEqual(store.events.map(\.uuid), [firstEvent.uuid])
        XCTAssertEqual(store.defaults.string(forKey: "selectedJournal"), first.uuid.uuidString)
        XCTAssertEqual(first.name, "Alex")
        XCTAssertEqual(store.journals.count, 2)
    }

    func testRenamingExistingBabyPreservesJournalAndFeedings() throws {
        let event = try store.add(kind: .breast, startTimer: false)
        let journal = try XCTUnwrap(event.journal)
        let id = journal.objectID
        try store.renameBaby(journal, name: "  Robin  ")
        XCTAssertEqual(store.activeJournal?.name, "Robin")
        XCTAssertEqual(store.activeJournal?.objectID, id)
        XCTAssertEqual(store.events.map(\.uuid), [event.uuid])
        XCTAssertThrowsError(try store.renameBaby(journal, name: " \n "))
        XCTAssertEqual(journal.name, "Robin")
        XCTAssertThrowsError(try store.createBaby(name: " "))
        XCTAssertEqual(store.journals.count, 1)
    }

    func testSwitchingBabiesKeepsTimerAndSwitchActionInOriginalJournal() throws {
        let first = try store.createBaby(name: "Alex")
        let started = Date().addingTimeInterval(-90)
        let event = try store.add(kind: .breast, side: .left, start: started)
        let second = try store.createBaby(name: "Sam")
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.runningEvent?.uuid, event.uuid)
        try store.finish(eventID: event.uuid, switchSide: true)
        XCTAssertEqual(store.activeJournal, second)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.runningEvent?.journal, first)
        XCTAssertEqual(store.runningEvent?.side, .right)
        XCTAssertNotNil(event.duration)
        let next = try XCTUnwrap(store.runningEvent)
        try store.finish(eventID: next.uuid)
        XCTAssertNil(store.running)
        store.selectedJournalID = first.uuid.uuidString
        XCTAssertEqual(store.events.count, 2)
    }

    func testExportIncludesOnlySelectedBaby() throws {
        let first = try store.createBaby(name: "Alex")
        let firstEvent = try store.add(kind: .breast, startTimer: false)
        try store.createBaby(name: "Sam")
        let secondEvent = try store.add(kind: .bottle, ml: 80)
        store.selectedJournalID = first.uuid.uuidString
        let csv = try String(contentsOf: store.exportCSV(), encoding: .utf8)
        XCTAssertTrue(csv.contains(firstEvent.uuid.uuidString))
        XCTAssertFalse(csv.contains(secondEvent.uuid.uuidString))
    }

    func testInvalidBabySelectionFallsBackWithoutCombiningHistories() throws {
        try store.createBaby(name: "Alex")
        let firstEvent = try store.add(kind: .bottle, ml: 90)
        try store.createBaby(name: "Sam")
        try store.add(kind: .pump, side: .both)
        store.selectedJournalID = UUID().uuidString
        XCTAssertEqual(store.events.map(\.uuid), [firstEvent.uuid])
    }

    func testDeletingBabyRemovesOnlyTheirFeedingsAndTimer() throws {
        let first = try store.createBaby(name: "Alex")
        let kept = try store.add(kind: .bottle, ml: 90)
        let second = try store.createBaby(name: "Sam")
        try store.add(kind: .pump, side: .both)
        try store.add(kind: .breast)
        try store.deleteBaby(second)
        XCTAssertEqual(store.journals.map(\.uuid), [first.uuid])
        XCTAssertEqual(store.activeJournal, first)
        XCTAssertEqual(store.events.map(\.uuid), [kept.uuid])
        XCTAssertNil(store.running)
        XCTAssertEqual(try store.container.viewContext.count(for: NSFetchRequest<FeedingEvent>(entityName: "FeedingEvent")), 1)
    }

    func testDeletingAnotherBabyPreservesRunningTimerAndSelection() throws {
        let first = try store.createBaby(name: "Alex")
        try store.add(kind: .bottle)
        let second = try store.createBaby(name: "Sam")
        let event = try store.add(kind: .breast)
        try store.deleteBaby(first)
        XCTAssertEqual(store.activeJournal, second)
        XCTAssertEqual(store.runningEvent, event)
        XCTAssertEqual(store.running?.eventID, event.uuid)
        XCTAssertEqual(store.selectedJournalID, second.uuid.uuidString)
    }

    func testDeletingLastBabyLeavesNoOrphanFeedingsAndAllowsNewBaby() throws {
        let baby = try store.createBaby(name: "Alex")
        let oldID = baby.uuid
        try store.add(kind: .breast)
        try store.deleteBaby(baby)
        XCTAssertTrue(store.journals.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertNil(store.activeJournal)
        XCTAssertNil(store.running)
        XCTAssertEqual(store.selectedJournalID, "")
        XCTAssertEqual(try store.container.viewContext.count(for: NSFetchRequest<FeedingEvent>(entityName: "FeedingEvent")), 0)
        let next = try store.createBaby(name: "Sam")
        XCTAssertNotEqual(next.uuid, oldID)
        XCTAssertEqual(store.activeJournal, next)
        XCTAssertTrue(store.events.isEmpty)
    }
    func testLastFeedingUsesStartIgnoresPumpAndTracksEditsAndDeletion() throws {
        XCTAssertNil(store.lastFeeding)
        let start = Date().addingTimeInterval(-4_800)
        let breast = try store.add(kind: .breast, start: start, startTimer: false)
        try store.update(breast, kind: .breast, side: .left, start: start, ml: nil, duration: 3_600)
        try store.add(kind: .pump, side: .both, start: start.addingTimeInterval(600))
        XCTAssertEqual(store.lastFeeding?.startedAt, start)
        let bottle = try store.add(kind: .bottle, start: start.addingTimeInterval(1_200))
        XCTAssertEqual(store.lastFeeding, bottle)
        try store.update(breast, kind: .breast, side: .left, start: start.addingTimeInterval(1_800), ml: nil, duration: nil)
        XCTAssertEqual(store.lastFeeding, breast)
        try store.delete(breast)
        XCTAssertEqual(store.lastFeeding, bottle)
        try store.createBaby(name: "Another baby")
        try store.add(kind: .pump, side: .left)
        XCTAssertNil(store.lastFeeding)
    }

    func testWholeMinuteDisplayPreservesRecordedSeconds() throws {
        let event = try store.add(kind: .breast, startTimer: false)
        XCTAssertNil(event.wholeMinutes)
        for (seconds, minutes) in [(0, 0), (59, 0), (60, 1), (119, 1), (4_859, 80)] {
            try store.update(event, kind: .breast, side: .left, start: event.startedAt, ml: nil, duration: Double(seconds))
            XCTAssertEqual(event.wholeMinutes, minutes)
            XCTAssertEqual(event.duration?.intValue, seconds)
        }
    }

    func testAllTranslationsAreBundledIncludingDynamicLabels() throws {
        for language in ["nl", "de", "fr", "es", "it", "pt-BR", "zh-Hans", "ja"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["New Feeding", "%@ since last feeding", "Switch to Right", "Delete Baby?"] {
                let translated = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                XCTAssertNotEqual(translated, key, "\(language): \(key)")
            }
        }
    }

    func testDeletedFeedingEditorCanRenderWhileDismissing() async throws {
        for startTimer in [false, true] {
            let event = try store.add(kind: .breast, startTimer: startTimer)
            let editor = FeedingEditor(event: event).environmentObject(store)
            let controller = UIHostingController(rootView: editor)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
            controller.view.layoutIfNeeded()
            try store.delete(event)
            // The outgoing sheet can redraw before its dismissal completes.
            controller.rootView = editor
            await Task.yield()
            controller.view.layoutIfNeeded()
            XCTAssertNil(event.managedObjectContext)
            XCTAssertNil(store.running)
        }
    }

    func testControlSymbolRendersVisiblePixelsInAppAndExtension() throws {
        let extensionURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL).appendingPathComponent("FeedingActivity.appex")
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        for bundle in [Bundle.main, extensionBundle] {
            for scale in [UIImage.SymbolScale.small, .medium, .large] {
                let configuration = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular, scale: scale)
                let image = try XCTUnwrap(UIImage(named: "BreastControl", in: bundle, with: configuration), "Missing symbol in \(bundle.bundleURL.lastPathComponent), scale \(scale.rawValue)")
                XCTAssertTrue(image.isSymbolImage)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let rendered = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { _ in
                    image.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 8, y: 8, width: 48, height: 48))
                }
                let cgImage = try XCTUnwrap(rendered.cgImage)
                var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
                let context = try XCTUnwrap(CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8,
                    bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 64, height: 64))
                let visiblePixels = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 32 }.count
                XCTAssertGreaterThan(visiblePixels, 100, "Empty symbol in \(bundle.bundleURL.lastPathComponent), scale \(scale.rawValue)")
            }
        }
    }

}

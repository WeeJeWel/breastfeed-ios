import CloudKit
import Combine
import CoreData
import Foundation

@objc(FeedingEvent)
final class FeedingEvent: NSManagedObject, Identifiable {
    @NSManaged var uuid: UUID
    @NSManaged var startedAt: Date
    @NSManaged var createdAt: Date
    @NSManaged var kindRaw: String
    @NSManaged var sideRaw: String?
    @NSManaged var volume: NSNumber?
    @NSManaged var duration: NSNumber?
    @NSManaged var journal: FeedingJournal?

    var wholeMinutes: Int? { duration.map { Int($0.doubleValue / 60) } }

    var kind: FeedingKind { FeedingKind(rawValue: kindRaw) ?? .breast }
    var side: FeedingSide? { sideRaw.flatMap(FeedingSide.init(rawValue:)) }
    var title: String { kind.title + (kind == .bottle ? "" : " · \((side ?? .left).title)") }
}

@objc(FeedingJournal)
final class FeedingJournal: NSManagedObject, Identifiable {
    @NSManaged var uuid: UUID
    @NSManaged var name: String
    @NSManaged var createdAt: Date
    @NSManaged var events: NSSet?
}

enum FeedingError: LocalizedError {
    case storageUnavailable, invalidAmount, invalidDuration, invalidSide, missingTimer, invalidTime, invalidBabyName
    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return String(localized: "The feeding journal couldn’t be opened. Please restart the app and try again.")
        case .invalidAmount: return String(localized: "Enter a volume between 0 and 10,000 ml.")
        case .invalidDuration: return String(localized: "Enter a duration between 0 and 1,440 minutes.")
        case .invalidSide: return String(localized: "Choose Left or Right for breastfeeding.")
        case .missingTimer: return String(localized: "This timer is no longer running. Its feeding is still in your timeline.")
        case .invalidTime: return String(localized: "A feeding can’t start in the future.")
        case .invalidBabyName: return String(localized: "Enter a name for your baby.")
        }
    }
}

@MainActor
final class FeedingStore: ObservableObject {
    static let shared = FeedingStore()
    static let containerID = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String
        ?? "iCloud.nl.weejewel.BoobieTrackr3000"

    let container: NSPersistentCloudKitContainer
    let defaults: UserDefaults
    let localOnly: Bool
    @Published private(set) var events: [FeedingEvent] = []
    @Published private(set) var journals: [FeedingJournal] = []
    @Published private(set) var running: RunningFeed?
    @Published var selectedJournalID: String {
        didSet {
            defaults.set(selectedJournalID, forKey: "selectedJournal")
            refresh()
        }
    }
    @Published var errorMessage: String?
    @Published var cloudStatus = String(localized: "Connecting to iCloud…")
    private(set) var loaded = false
    private var observers: [NSObjectProtocol] = []
    #if os(iOS)
    var shareRequests: [NSManagedObjectID: Task<CKShare, Error>] = [:]
    @Published var newFeedingRequested = false
    var liveActivitySyncing = false
    var liveActivitySyncAgain = false
    #endif

    var privateStore: NSPersistentStore? {
        container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "Private.sqlite" }
            ?? (localOnly ? container.persistentStoreCoordinator.persistentStores.first : nil)
    }
    var sharedStore: NSPersistentStore? {
        container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "Shared.sqlite" }
    }
    var activeJournal: FeedingJournal? {
        journals.first { $0.uuid.uuidString == selectedJournalID }
            ?? journals.first { $0.objectID.persistentStore == sharedStore }
            ?? journals.first
    }
    // Pumping records milk expressed, not a feeding for the selected baby.
    var lastFeeding: FeedingEvent? { events.last { $0.kind != .pump } }

    var runningEvent: FeedingEvent? {
        guard let running else { return nil }
        let request = NSFetchRequest<FeedingEvent>(entityName: "FeedingEvent")
        request.predicate = NSPredicate(format: "uuid == %@", running.eventID as CVarArg)
        request.fetchLimit = 1
        return try? container.viewContext.fetch(request).first
    }

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let demo = ProcessInfo.processInfo.arguments.contains("--demo")
        #if targetEnvironment(simulator)
        // Unsigned simulator launches (including background Live Activity launches)
        // cannot open CKContainer safely without the iCloud entitlement.
        localOnly = true
        #else
        localOnly = inMemory || demo || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #endif
        selectedJournalID = defaults.string(forKey: "selectedJournal") ?? ""
        running = defaults.data(forKey: demo ? "demoRunningFeed" : "runningFeed")
            .flatMap { try? JSONDecoder().decode(RunningFeed.self, from: $0) }

        let model = NSManagedObjectModel()
        let event = NSEntityDescription()
        event.name = "FeedingEvent"
        event.managedObjectClassName = NSStringFromClass(FeedingEvent.self)
        let journal = NSEntityDescription()
        journal.name = "FeedingJournal"
        journal.managedObjectClassName = NSStringFromClass(FeedingJournal.self)
        // CloudKit requires optional properties and inverse, optional relationships.
        for (entity, specifications) in [
            (event, [("uuid", NSAttributeType.UUIDAttributeType), ("startedAt", .dateAttributeType),
                     ("createdAt", .dateAttributeType), ("kindRaw", .stringAttributeType),
                     ("sideRaw", .stringAttributeType), ("volume", .doubleAttributeType), ("duration", .doubleAttributeType)]),
            (journal, [("uuid", .UUIDAttributeType), ("name", .stringAttributeType), ("createdAt", .dateAttributeType)])
        ] {
            for (name, type) in specifications {
                let attribute = NSAttributeDescription()
                attribute.name = name
                attribute.attributeType = type
                attribute.isOptional = true
                entity.properties.append(attribute)
            }
        }
        let toJournal = NSRelationshipDescription()
        toJournal.name = "journal"
        toJournal.destinationEntity = journal
        toJournal.maxCount = 1
        toJournal.isOptional = true
        toJournal.deleteRule = .nullifyDeleteRule
        let toEvents = NSRelationshipDescription()
        toEvents.name = "events"
        toEvents.destinationEntity = event
        toEvents.maxCount = 0
        toEvents.isOptional = true
        toEvents.deleteRule = .cascadeDeleteRule
        toEvents.inverseRelationship = toJournal
        toJournal.inverseRelationship = toEvents
        event.properties.append(toJournal)
        journal.properties.append(toEvents)
        model.entities = [event, journal]
        container = NSPersistentCloudKitContainer(name: "BoobieTrackr3000", managedObjectModel: model)
        let directory = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent(demo ? (ProcessInfo.processInfo.arguments.contains("--screenshots") ? "Screenshots" : "Demo") : "Journal")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { errorMessage = error.localizedDescription }

        container.persistentStoreDescriptions = (localOnly ? ["Private"] : ["Private", "Shared"]).map { name in
            let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("\(name).sqlite"))
            description.shouldAddStoreAsynchronously = false
            if inMemory { description.type = NSInMemoryStoreType }
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            if !localOnly {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerID)
                options.databaseScope = name == "Private" ? .private : .shared
                description.cloudKitContainerOptions = options
            }
            return description
        }
        var failure: Error?
        container.loadPersistentStores { _, error in if let error { failure = error } }
        loaded = failure == nil
        if let failure { errorMessage = failure.localizedDescription }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.transactionAuthor = "BoobieTrackr3000"
        cloudStatus = localOnly ? String(localized: "Stored on this device") : String(localized: "iCloud sync enabled")
        refresh()

        observers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.container.viewContext.refreshAllObjects()
                self.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                               object: container, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in
                if let error = event.error {
                    self?.cloudStatus = String(localized: "Saved locally. iCloud: \(error.localizedDescription)")
                } else {
                    self?.cloudStatus = event.endDate == nil ? String(localized: "Syncing with iCloud…") : String(localized: "Synced with iCloud")
                }
                self?.refresh()
            }
        })
        if demo && events.isEmpty { seedDemo() }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func refresh() {
        guard loaded else { return }
        do {
            let journalRequest = NSFetchRequest<FeedingJournal>(entityName: "FeedingJournal")
            journalRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            journals = try container.viewContext.fetch(journalRequest)
            let request = NSFetchRequest<FeedingEvent>(entityName: "FeedingEvent")
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
            if let activeJournal { request.predicate = NSPredicate(format: "journal == %@", activeJournal) }
            events = try container.viewContext.fetch(request)
            if let running {
                let current = NSFetchRequest<FeedingEvent>(entityName: "FeedingEvent")
                current.predicate = NSPredicate(format: "uuid == %@", running.eventID as CVarArg)
                if let event = try container.viewContext.fetch(current).first,
                   event.kind == .breast, event.duration == nil {
                    if event.startedAt != running.startedAt {
                        setRunning(RunningFeed(eventID: event.uuid, startedAt: event.startedAt))
                    }
                } else { setRunning(nil) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func journalForNewEvent() throws -> FeedingJournal {
        guard loaded, let privateStore else { throw FeedingError.storageUnavailable }
        if let activeJournal { return activeJournal }
        let journal = FeedingJournal(entity: container.managedObjectModel.entitiesByName["FeedingJournal"]!, insertInto: container.viewContext)
        journal.uuid = UUID()
        journal.name = String(localized: "Our baby")
        journal.createdAt = Date()
        container.viewContext.assign(journal, to: privateStore)
        return journal
    }

    @discardableResult
    func createBaby(name: String) throws -> FeedingJournal {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FeedingError.invalidBabyName }
        guard loaded, let privateStore else { throw FeedingError.storageUnavailable }
        let journal = FeedingJournal(entity: container.managedObjectModel.entitiesByName["FeedingJournal"]!, insertInto: container.viewContext)
        journal.uuid = UUID()
        journal.name = name
        journal.createdAt = Date()
        container.viewContext.assign(journal, to: privateStore)
        do { try container.viewContext.save() }
        catch { container.viewContext.rollback(); throw error }
        selectedJournalID = journal.uuid.uuidString
        return journal
    }

    func renameBaby(_ journal: FeedingJournal, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FeedingError.invalidBabyName }
        journal.name = name
        do { try container.viewContext.save() }
        catch { container.viewContext.rollback(); throw error }
        refresh()
    }

    func deleteBaby(_ journal: FeedingJournal) throws {
        let wasSelected = activeJournal?.uuid == journal.uuid
        let hadTimer = runningEvent?.journal?.uuid == journal.uuid
        container.viewContext.delete(journal)
        do { try container.viewContext.save() }
        catch { container.viewContext.rollback(); throw error }
        if hadTimer { setRunning(nil) }
        if wasSelected { selectedJournalID = "" }
        else { refresh() }
    }

    @discardableResult
    func add(kind: FeedingKind, side: FeedingSide = .left, start: Date = Date(), ml: Double? = nil,
             startTimer: Bool = true) throws -> FeedingEvent {
        guard start <= Date().addingTimeInterval(1) else { throw FeedingError.invalidTime }
        guard kind != .breast || side != .both else { throw FeedingError.invalidSide }
        if let ml, !ml.isFinite || ml < 0 || ml > 10_000 { throw FeedingError.invalidAmount }
        let journal = try journalForNewEvent()
        let event = FeedingEvent(entity: container.managedObjectModel.entitiesByName["FeedingEvent"]!, insertInto: container.viewContext)
        event.uuid = UUID()
        event.createdAt = Date()
        event.startedAt = start
        event.kindRaw = kind.rawValue
        event.sideRaw = kind == .bottle ? nil : side.rawValue
        event.volume = kind == .breast ? nil : ml.map(NSNumber.init(value:))
        event.journal = journal
        if let store = journal.objectID.persistentStore { container.viewContext.assign(event, to: store) }
        do { try container.viewContext.save() }
        catch { container.viewContext.rollback(); throw error }
        // A new event abandons the old timer. Duration is never inferred or saved here.
        setRunning(kind == .breast && startTimer ? RunningFeed(eventID: event.uuid, startedAt: start) : nil)
        refresh()
        return event
    }

    func finish(eventID: UUID, switchSide: Bool = false, now: Date = Date()) throws {
        guard let running, running.eventID == eventID else { throw FeedingError.missingTimer }
        let request = NSFetchRequest<FeedingEvent>(entityName: "FeedingEvent")
        request.predicate = NSPredicate(format: "uuid == %@", eventID as CVarArg)
        guard let event = try container.viewContext.fetch(request).first, event.kind == .breast else {
            throw FeedingError.missingTimer
        }
        event.duration = NSNumber(value: max(0, now.timeIntervalSince(running.startedAt)))
        var next: RunningFeed?
        if switchSide {
            let newEvent = FeedingEvent(entity: container.managedObjectModel.entitiesByName["FeedingEvent"]!, insertInto: container.viewContext)
            newEvent.uuid = UUID()
            newEvent.createdAt = now
            newEvent.startedAt = now
            newEvent.kindRaw = FeedingKind.breast.rawValue
            newEvent.sideRaw = (event.side ?? .left).opposite.rawValue
            newEvent.journal = event.journal
            if let store = event.objectID.persistentStore { container.viewContext.assign(newEvent, to: store) }
            next = RunningFeed(eventID: newEvent.uuid, startedAt: now)
        }
        do { try container.viewContext.save() }
        catch { container.viewContext.rollback(); throw error }
        setRunning(next)
        refresh()
    }

    func update(_ event: FeedingEvent, kind: FeedingKind, side: FeedingSide, start: Date,
                ml: Double?, duration: Double?) throws {
        guard start <= Date().addingTimeInterval(1) else { throw FeedingError.invalidTime }
        guard kind != .breast || side != .both else { throw FeedingError.invalidSide }
        if let ml, !ml.isFinite || ml < 0 || ml > 10_000 { throw FeedingError.invalidAmount }
        if let duration, !duration.isFinite || duration < 0 || duration > 86_400 { throw FeedingError.invalidDuration }
        event.kindRaw = kind.rawValue
        event.sideRaw = kind == .bottle ? nil : side.rawValue
        event.startedAt = start
        event.volume = kind == .breast ? nil : ml.map(NSNumber.init(value:))
        event.duration = duration.map(NSNumber.init(value:))
        do { try container.viewContext.save() }
        catch { container.viewContext.rollback(); throw error }
        if running?.eventID == event.uuid {
            setRunning(kind == .breast && duration == nil ? RunningFeed(eventID: event.uuid, startedAt: start) : nil)
        }
        refresh()
    }

    func delete(_ event: FeedingEvent) throws {
        let id = event.uuid
        container.viewContext.delete(event)
        do { try container.viewContext.save() }
        catch { container.viewContext.rollback(); throw error }
        if running?.eventID == id { setRunning(nil) }
        refresh()
    }

    func setRunning(_ value: RunningFeed?) {
        running = value
        let key = ProcessInfo.processInfo.arguments.contains("--demo") ? "demoRunningFeed" : "runningFeed"
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    func exportCSV() throws -> URL {
        let text = FeedingCSV.string(rows: events.map {
            ($0.uuid, $0.startedAt, $0.kind, $0.side, $0.volume?.doubleValue, $0.duration?.doubleValue)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("BoobieTrackr.csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func seedDemo() {
        let day = Calendar.current.startOfDay(for: Date())
        let screenshots = ProcessInfo.processInfo.arguments.contains("--screenshots")
        if screenshots {
            do { try createBaby(name: "Cosmo") }
            catch { errorMessage = error.localizedDescription }
        }
        for (hour, minute, kind, side, amount, duration) in [
            (1, 15, FeedingKind.breast, FeedingSide.left, nil as Double?, 840.0 as Double?),
            (4, 30, .breast, .right, nil, 1080), (7, 10, .bottle, .left, 90, nil),
            (9, 45, .pump, .both, 120, nil), (12, 5, .breast, .left, nil, 720)
        ] {
            let sampleHour = screenshots ? max(0, Calendar.current.component(.hour, from: Date()) - 10 + [1: 0, 4: 2, 7: 4, 9: 6, 12: 8][hour]!) : hour
            let start = day.addingTimeInterval(Double(sampleHour * 3600 + minute * 60))
            guard start < Date() else { continue }
            do {
                let event = try add(kind: kind, side: side, start: start, ml: amount, startTimer: false)
                event.duration = duration.map(NSNumber.init(value:))
                try container.viewContext.save()
            } catch { errorMessage = error.localizedDescription }
        }
        refresh()
    }
}

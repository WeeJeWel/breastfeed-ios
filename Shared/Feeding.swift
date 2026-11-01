import Foundation

enum FeedingKind: String, CaseIterable, Codable, Identifiable {
    case breast, pump, bottle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .breast: return String(localized: "Breast")
        case .pump: return String(localized: "Pump")
        case .bottle: return String(localized: "Bottle")
        }
    }
    var symbol: String {
        switch self {
        case .breast: return "Breast"
        case .pump: return "Pump"
        case .bottle: return "waterbottle.fill"
        }
    }
    var sides: [FeedingSide] { self == .pump ? [.left, .right, .both] : [.left, .right] }
}

enum FeedingSide: String, CaseIterable, Codable, Identifiable {
    case left, right, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        case .both: return String(localized: "Both")
        }
    }
    var breastTitle: String {
        self == .right ? String(localized: "Right breast") : String(localized: "Left breast")
    }
    var switchTitle: String {
        self == .right ? String(localized: "Switch to Right") : String(localized: "Switch to Left")
    }
    var opposite: FeedingSide { self == .left ? .right : .left }
}

struct RunningFeed: Codable, Equatable {
    let eventID: UUID
    var startedAt: Date
}

enum FeedingCSV {
    static func string(rows: [(id: UUID, start: Date, kind: FeedingKind, side: FeedingSide?, ml: Double?, duration: Double?)]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["id,start_time_utc,type,side,volume_ml,duration_seconds"]
        for row in rows.sorted(by: { $0.start < $1.start }) {
            let fields = [row.id.uuidString, formatter.string(from: row.start), row.kind.rawValue.capitalized,
                          row.kind == .bottle ? "" : row.side?.rawValue.capitalized ?? "",
                          row.ml.map { String($0) } ?? "", row.duration.map { String(Int($0)) } ?? ""]
            lines.append(fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// Versioned backup format. Dates are milliseconds since the Unix epoch.
struct FeedingBackup: Codable {
    var schemaVersion = 1
    var exportedAt: Date
    var babies: [Baby]

    struct Baby: Codable {
        var id: UUID
        var name: String
        var createdAt: Date
        var feedings: [Feed]
    }

    struct Feed: Codable {
        var id: UUID
        var startedAt: Date
        var createdAt: Date
        var kind: FeedingKind
        var side: FeedingSide?
        var ml: Double?
        var durationSeconds: Double?
    }
}

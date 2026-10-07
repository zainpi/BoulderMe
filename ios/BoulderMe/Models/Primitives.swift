import Foundation

// Wire primitives from docs/api/openapi.yaml. Field names map with
// `.convertFromSnakeCase` / `.convertToSnakeCase` (see APICoding.swift).

/// A UUID that always encodes in lowercase, as the contract requires
/// (`UUID.uuidString` is uppercase).
struct EntityID: Hashable, Codable, Sendable, CustomStringConvertible {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) { self.uuid = uuid }

    init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    var description: String { uuid.uuidString.lowercased() }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid UUID \(raw)")
        }
        self.uuid = uuid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// V-scale grade, `0` = V0. Valid range 0...17.
typealias Grade = Int

enum Grades {
    static let range: ClosedRange<Grade> = 0...17
    static func label(_ grade: Grade) -> String { "V\(grade)" }
    static func label(min: Grade, max: Grade) -> String {
        min == max ? label(min) : "\(label(min))–\(label(max))"
    }
}

/// ISO weekday, `1` = Monday.
enum Weekday: Int, Codable, CaseIterable, Sendable, Identifiable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
    var id: Int { rawValue }

    var shortName: String {
        switch self {
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        case .sunday: "Sun"
        }
    }
}

enum TimeOfDay: String, Codable, CaseIterable, Sendable, Identifiable {
    case morning, afternoon, evening
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        }
    }
}

/// Self-reported. Never verified; always labeled so in the UI.
enum AccessType: String, Codable, CaseIterable, Sendable, Identifiable {
    case membership
    case guestPass = "guest_pass"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .membership: "Membership"
        case .guestPass: "Guest pass"
        }
    }

    var symbol: String {
        switch self {
        case .membership: "person.crop.square.filled.and.at.rectangle"
        case .guestPass: "ticket.fill"
        }
    }
}

enum ClimbingStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case slab, vertical, overhang, roof, crimps, slopers, pinches, dynamic, technical, power
    case compStyle = "comp_style"
    case highball
    var id: String { rawValue }

    static let maxSelected = 6

    var title: String {
        switch self {
        case .compStyle: "Comp style"
        default: rawValue.capitalized
        }
    }
}

/// `{items, next_cursor}` page used by every list route.
struct Page<Item: Codable & Sendable>: Codable, Sendable {
    var items: [Item]
    var nextCursor: String?

    init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

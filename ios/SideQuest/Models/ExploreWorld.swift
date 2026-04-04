import Foundation
import MapKit

nonisolated enum EventTimePriority: String, Sendable {
    case live
    case imminent
    case soon
    case today
    case later
    case none

    var isAnimated: Bool {
        self == .live || self == .imminent
    }

    var forceFullPin: Bool {
        self == .live || self == .imminent || self == .soon
    }
}

nonisolated enum ExploreEncounterKind: String, Identifiable, Sendable {
    case activeQuest = "Active Quest"
    case mainQuest = "Main Quest"
    case limitedEvent = "Timed Event"
    case sideQuest = "Side Quest"
    case daily = "Daily"
    case hotspot = "Hotspot"
    case visitedShrine = "Cleared"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .activeQuest: "TRACKED"
        case .mainQuest: "MAIN"
        case .limitedEvent: "LIVE"
        case .sideQuest: "SIDE"
        case .daily: "DAILY"
        case .hotspot: "NODE"
        case .visitedShrine: "CLEARED"
        }
    }

    var systemImageName: String {
        switch self {
        case .activeQuest: "location.north.line.fill"
        case .mainQuest: "sparkles"
        case .limitedEvent: "hourglass.circle.fill"
        case .sideQuest: "flag.pattern.checkered"
        case .daily: "sun.max.fill"
        case .hotspot: "shield.lefthalf.filled"
        case .visitedShrine: "checkmark.seal.fill"
        }
    }

    var isHighPriority: Bool {
        switch self {
        case .activeQuest, .mainQuest, .limitedEvent: true
        case .sideQuest, .daily, .hotspot, .visitedShrine: false
        }
    }

    var isClusterable: Bool {
        switch self {
        case .activeQuest, .mainQuest: false
        case .limitedEvent, .sideQuest, .daily, .hotspot, .visitedShrine: true
        }
    }
}

nonisolated struct ExploreEncounter: Identifiable, Sendable {
    let id: String
    let poi: MapPOI
    let quest: Quest?
    let title: String
    let subtitle: String
    let flavorText: String
    let kind: ExploreEncounterKind
    let difficulty: QuestDifficulty
    let xp: Int
    let gold: Int
    let estimatedMinutes: Int
    let journeyTitle: String?
    let districtName: String
    let externalEvent: ExternalEvent?
    let groupedEvents: [ExternalEvent]
    let mapPinAssetName: String?
    let countdownText: String?
    let eventTimePriority: EventTimePriority

    init(
        id: String,
        poi: MapPOI,
        quest: Quest?,
        title: String,
        subtitle: String,
        flavorText: String,
        kind: ExploreEncounterKind,
        difficulty: QuestDifficulty,
        xp: Int,
        gold: Int,
        estimatedMinutes: Int,
        journeyTitle: String?,
        districtName: String,
        externalEvent: ExternalEvent? = nil,
        groupedEvents: [ExternalEvent] = [],
        mapPinAssetName: String? = nil,
        countdownText: String? = nil,
        eventTimePriority: EventTimePriority = .none
    ) {
        self.id = id
        self.poi = poi
        self.quest = quest
        self.title = title
        self.subtitle = subtitle
        self.flavorText = flavorText
        self.kind = kind
        self.difficulty = difficulty
        self.xp = xp
        self.gold = gold
        self.estimatedMinutes = estimatedMinutes
        self.journeyTitle = journeyTitle
        self.districtName = districtName
        self.externalEvent = externalEvent
        self.groupedEvents = groupedEvents
        self.mapPinAssetName = mapPinAssetName
        self.countdownText = countdownText
        self.eventTimePriority = eventTimePriority
    }

    var coordinate: CLLocationCoordinate2D { poi.coordinate }
    var zoneRadius: CLLocationDistance {
        switch kind {
        case .mainQuest: max(poi.category.checkInRadiusMeters * 1.7, 220)
        case .limitedEvent: max(poi.category.checkInRadiusMeters * 1.9, 280)
        case .activeQuest: max(poi.category.checkInRadiusMeters * 1.5, 180)
        case .sideQuest: max(poi.category.checkInRadiusMeters * 1.3, 150)
        case .daily: max(poi.category.checkInRadiusMeters * 1.15, 120)
        case .hotspot: max(poi.category.checkInRadiusMeters, 100)
        case .visitedShrine: max(poi.category.checkInRadiusMeters, 90)
        }
    }
}

nonisolated struct ExploreDistrict: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let path: QuestPath
    let labelCoordinate: CLLocationCoordinate2D
    let coordinates: [CLLocationCoordinate2D]
}

nonisolated struct ExploreZone: Identifiable, Sendable {
    let id: String
    let title: String
    let centerCoordinate: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let category: MapQuestCategory
    let kind: ExploreEncounterKind
}

nonisolated struct ExploreRoute: Identifiable, Sendable {
    let id: String
    let title: String
    let coordinates: [CLLocationCoordinate2D]
    let path: QuestPath
}

nonisolated enum MapExploreFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case liveEvents
    case nightlife
    case concerts
    case sports
    case races
    case community
    case fitness
    case outdoors
    case culture

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .liveEvents: "Live"
        case .nightlife: "Nightlife"
        case .concerts: "Concerts"
        case .sports: "Sports"
        case .races: "Races"
        case .community: "Community"
        case .fitness: "Fitness"
        case .outdoors: "Outdoors"
        case .culture: "Culture"
        }
    }

    var symbol: String? {
        switch self {
        case .all: nil
        case .liveEvents: "bolt.fill"
        case .nightlife: "moon.stars.fill"
        case .concerts: "music.mic"
        case .sports: "sportscourt.fill"
        case .races: "figure.run"
        case .community: "person.3.fill"
        case .fitness: "dumbbell.fill"
        case .outdoors: "leaf.fill"
        case .culture: "building.columns.fill"
        }
    }
}

nonisolated enum ExploreMapCommandAction: String, Sendable {
    case recenter
    case zoomIn
    case zoomOut
    case focusObjectives
}

nonisolated struct ExploreMapCommand: Identifiable, Equatable, Sendable {
    let id: UUID
    let action: ExploreMapCommandAction

    init(action: ExploreMapCommandAction) {
        self.id = UUID()
        self.action = action
    }
}

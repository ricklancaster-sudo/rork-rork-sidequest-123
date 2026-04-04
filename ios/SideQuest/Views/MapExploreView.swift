import SwiftUI
import MapKit
import Combine

private struct MapWorldSnapshot {
    let encounters: [ExploreEncounter]
    let normalizedEvents: [ExternalEvent]
    let diagnosticsSignature: String
}

private struct ViewportPOIRequest: Equatable {
    let center: CLLocationCoordinate2D
    let visibleRadius: Double
    let northEast: CLLocationCoordinate2D
    let northWest: CLLocationCoordinate2D
    let southEast: CLLocationCoordinate2D
    let southWest: CLLocationCoordinate2D

    static func == (lhs: ViewportPOIRequest, rhs: ViewportPOIRequest) -> Bool {
        abs(lhs.center.latitude - rhs.center.latitude) < 0.0001
            && abs(lhs.center.longitude - rhs.center.longitude) < 0.0001
            && abs(lhs.visibleRadius - rhs.visibleRadius) < 1
            && abs(lhs.northEast.latitude - rhs.northEast.latitude) < 0.0001
            && abs(lhs.northEast.longitude - rhs.northEast.longitude) < 0.0001
            && abs(lhs.southWest.latitude - rhs.southWest.latitude) < 0.0001
            && abs(lhs.southWest.longitude - rhs.southWest.longitude) < 0.0001
    }
}

private struct ViewportEventRequest: Equatable {
    let bounds: ExternalEventViewportBounds
    let range: ExternalEventViewportTileRange
    let intents: [ExternalDiscoveryIntent]
    let countryCode: String
    let signature: String
}

private struct POITileDescriptor: Hashable {
    let category: MapQuestCategory
    let center: CLLocationCoordinate2D
    let searchRadius: Double
    let bucketLatitude: Int
    let bucketLongitude: Int

    var cacheKey: String {
        "\(category.rawValue)_\(bucketLatitude)_\(bucketLongitude)_\(Int(searchRadius.rounded()))"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(category)
        hasher.combine(bucketLatitude)
        hasher.combine(bucketLongitude)
        hasher.combine(Int(searchRadius.rounded()))
    }

    static func == (lhs: POITileDescriptor, rhs: POITileDescriptor) -> Bool {
        lhs.category == rhs.category
            && lhs.bucketLatitude == rhs.bucketLatitude
            && lhs.bucketLongitude == rhs.bucketLongitude
            && abs(lhs.searchRadius - rhs.searchRadius) < 1
    }
}

struct MapExploreView: View {
    let appState: AppState

    @State private var poiService: MapPOIService = MapPOIService()
    @State private var selectedCategory: MapQuestCategory = .park
    @State private var selectedEncounter: ExploreEncounter?
    @State private var selectedExternalEvent: ExternalEvent?
    @State private var activeMapQuests: [MapQuestInstance] = []
    @State private var mapCommand: ExploreMapCommand?
    @State private var hasCenteredOnUser: Bool = false
    @State private var hasLoadedInitialWorld: Bool = false
    @State private var showCheckedInConfirmation: Bool = false
    @State private var showScannerPulse: Bool = false
    @State private var mixedPOIs: [MapPOI] = []
    @State private var hasCompletedInitialFetch: Bool = false
    @State private var hasExplicitCategoryFocus: Bool = false



    @State private var eventCountdownNow: Date = Date()
    @State private var loggedExternalEventDiagnosticsSignature: String = ""
    @State private var preparedMapWorldSnapshot = MapWorldSnapshot(
        encounters: [],
        normalizedEvents: [],
        diagnosticsSignature: ""
    )
    @State private var mapWorldSignature: String = ""
    @State private var mapWorldGeneration: Int = 0
    @State private var isPreparingMapWorld: Bool = false
    @State private var selectedMapFilter: MapExploreFilter = .all
    @State private var currentVisibleRadius: Double = 2000
    @State private var mapCameraCenter: CLLocationCoordinate2D?
    @State private var currentViewport: ExploreMapViewport?
    @State private var groupedEventsSheet: [ExternalEvent]?
    @State private var cachedPOITiles: [String: [MapPOI]] = [:]
    @State private var pendingViewportPOILoadTask: Task<Void, Never>?
    @State private var lastViewportPOIRequest: ViewportPOIRequest?
    @State private var viewportEventTileCache: [String: [ExternalEventViewportTileSnapshot]] = [:]
    @State private var viewportExternalEvents: [ExternalEvent] = []
    @State private var pendingViewportEventLoadTask: Task<Void, Never>?
    @State private var lastViewportEventRequestSignature: String = ""
    @State private var hasResolvedViewportEventFeed: Bool = false
    @State private var backgroundPOILoadTasks: [String: Task<Void, Never>] = [:]
    @State private var allCachedPOIs: [MapPOI] = []
    @State private var emptyPOITileTimestamps: [String: Date] = [:]
    @State private var poiSearchSemaphoreCount: Int = 0
    @State private var isInitialPOILoadProtected: Bool = false
    private static let maxConcurrentPOISearches: Int = 3
    private static let emptyTileRetryInterval: TimeInterval = 60

    private let fallbackCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 34.0900, longitude: -118.3617)
    private var previewCoordinate: CLLocationCoordinate2D? {
        appState.externalEventSearchLocation?.coordinate
            ?? ExternalEventLocationService.fallbackSearchLocation(for: appState.effectiveExternalEventPostalCode).coordinate
    }
    private var usesPreviewLocation: Bool {
        ExternalEventLocationService.usesSimulatorPreviewLocation
    }

    private var centerCoordinate: CLLocationCoordinate2D {
        if usesPreviewLocation {
            return previewCoordinate ?? poiService.fallbackCoordinate ?? fallbackCoordinate
        }
        return poiService.userLocation?.coordinate ?? poiService.fallbackCoordinate ?? fallbackCoordinate
    }

    private var baseRecommendedCategories: [MapQuestCategory] {
        let sortedCategories: [MapQuestCategory] = MapQuestCategory.allCases.sorted { lhs, rhs in
            let lhsScore = categoryAffinityScore(for: lhs)
            let rhsScore = categoryAffinityScore(for: rhs)

            if lhsScore == rhsScore {
                if lhs.questPath == rhs.questPath {
                    return lhs.questXPReward > rhs.questXPReward
                }
                return lhs.questPath.rawValue < rhs.questPath.rawValue
            }
            return lhsScore > rhsScore
        }

        return Array(sortedCategories.prefix(6))
    }

    private var recommendedCategories: [MapQuestCategory] {
        var ordered: [MapQuestCategory] = []

        if hasExplicitCategoryFocus {
            ordered.append(selectedCategory)
        }

        for category in baseRecommendedCategories where !ordered.contains(category) {
            ordered.append(category)
        }

        if ordered.isEmpty {
            return [.park, .gym, .library, .cafe, .trail]
        }

        return Array(ordered.prefix(6))
    }

    private var preferredQuestPath: QuestPath {
        recommendedCategories.first?.questPath ?? selectedCategory.questPath
    }

    private var themeCategory: MapQuestCategory {
        recommendedCategories.first ?? selectedCategory
    }

    private var tailoredDescriptor: String {
        let interestLabels: [String] = Array(appState.profile.selectedInterests.prefix(2)).map(\.rawValue)
        if !interestLabels.isEmpty {
            return interestLabels.joined(separator: " · ")
        }

        let skillLabels: [String] = Array(appState.profile.selectedSkills.prefix(2)).map(\.rawValue)
        if !skillLabels.isEmpty {
            return skillLabels.joined(separator: " · ")
        }

        let pathLabels: [String] = Array(appState.pathOrder.prefix(2)).map(\.rawValue)
        return pathLabels.joined(separator: " · ")
    }

    private var encounterList: [ExploreEncounter] {
        preparedMapWorldSnapshot.encounters
    }

    private var isViewportEventTileFeedEnabled: Bool {
        SupabaseEventViewportTileService.shared.isConfigured
    }

    private var fallbackMapEvents: [ExternalEvent] {
        appState.externalEventFeed + appState.eventsTabExternalEventFeed + appState.exclusiveExternalEventFeed
    }

    private var activeMapEventFeed: [ExternalEvent] {
        guard isViewportEventTileFeedEnabled else { return fallbackMapEvents }
        return hasResolvedViewportEventFeed ? viewportExternalEvents : fallbackMapEvents
    }

    private var viewportEventTileIntents: [ExternalDiscoveryIntent] {
        ExternalDiscoveryIntent.allCases
    }

    private var viewportEventCountryCode: String {
        let resolved = appState.externalEventSearchLocation?.countryCode
            ?? appState.externalLocationDiscoverySnapshot?.searchLocation.countryCode
            ?? "US"
        return resolved.uppercased()
    }

    private func buildEncounterList(normalizedMapEvents: [ExternalEvent]) -> [ExploreEncounter] {
        let activeIDs: Set<String> = Set(activeMapQuests.map { $0.poi.id })
        let currentPOIs: [MapPOI] = Array(mixedPOIs.prefix(16))
        let verifiedQuests = appState.allQuests.filter { $0.type == .verified && $0.isLocationDependent }

        var encounters: [ExploreEncounter] = []
        var usedQuestIDs: Set<String> = []

        for (index, poi) in currentPOIs.enumerated() {
            let districtName = poi.neighborhood ?? poi.locality ?? districtPalette[index % districtPalette.count].name

            let relatedIDs = poi.category.relatedQuestIds
            let matchingQuests = relatedIDs.compactMap { qid in verifiedQuests.first { $0.id == qid } }
                .filter { !usedQuestIDs.contains($0.id) }

            let fallbackQuests = verifiedQuests
                .filter { $0.path == poi.category.questPath && !usedQuestIDs.contains($0.id) && !relatedIDs.contains($0.id) }

            let questPool = matchingQuests.isEmpty ? Array(fallbackQuests.prefix(2)) : matchingQuests
            let quest = questPool.first ?? Self.makeQuestFromPOI(poi)
            if let matchedQuest = questPool.first {
                usedQuestIDs.insert(matchedQuest.id)
            }

            let kind: ExploreEncounterKind
            if activeIDs.contains(poi.id) {
                kind = .activeQuest
            } else if appState.hasVisitedPOI(poi) {
                kind = .visitedShrine
            } else if quest.isFeatured {
                kind = .mainQuest
            } else if quest.difficulty == .hard || quest.difficulty == .expert {
                kind = .sideQuest
            } else {
                kind = .daily
            }

            encounters.append(ExploreEncounter(
                id: "encounter_\(quest.id)_\(poi.id)",
                poi: poi,
                quest: quest,
                title: quest.title,
                subtitle: "\(quest.path.rawValue) · \(quest.difficulty.rawValue)",
                flavorText: quest.description,
                kind: kind,
                difficulty: quest.difficulty,
                xp: quest.xpReward,
                gold: quest.goldReward,
                estimatedMinutes: quest.minCompletionMinutes > 0 ? quest.minCompletionMinutes : poi.category.presenceTimerMinutes,
                journeyTitle: nil,
                districtName: districtName
            ))
        }

        let currentIDs: Set<String> = Set(currentPOIs.map(\.id))
        let visitedEncounters: [ExploreEncounter] = appState.visitedPOIs
            .filter { !currentIDs.contains($0.id) }
            .prefix(4)
            .enumerated()
            .map { index, visited in
                let category = visited.mapCategory ?? selectedCategory
                let poi = MapPOI(
                    id: visited.id,
                    name: visited.name,
                    coordinate: visited.coordinate,
                    category: category,
                    address: nil,
                    distance: poiService.userLocation.map {
                        CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                            .distance(from: CLLocation(latitude: visited.latitude, longitude: visited.longitude))
                    },
                    placeDescription: nil,
                    websiteURL: nil,
                    phoneNumber: nil,
                    specificType: visited.questTitle,
                    neighborhood: nil,
                    locality: nil,
                    mapItemIdentifier: nil
                )
                return ExploreEncounter(
                    id: "encounter_visited_\(visited.id)",
                    poi: poi,
                    quest: nil,
                    title: "Cleared: \(visited.name)",
                    subtitle: visited.questTitle,
                    flavorText: "You already completed a challenge here.",
                    kind: .visitedShrine,
                    difficulty: .easy,
                    xp: max(category.questXPReward / 2, 40),
                    gold: max(category.questGoldReward / 2, 20),
                    estimatedMinutes: 5,
                    journeyTitle: nil,
                    districtName: districtPalette[(index + 1) % districtPalette.count].name
                )
            }

        encounters.append(contentsOf: buildExternalEventEncounters(normalizedMapEvents: normalizedMapEvents))
        encounters.append(contentsOf: visitedEncounters)
        return encounters.sorted { lhs, rhs in
            if lhs.kind == .limitedEvent, rhs.kind == .limitedEvent {
                return limitedEventSortDate(for: lhs) < limitedEventSortDate(for: rhs)
            }
            return priorityValue(for: lhs.kind) > priorityValue(for: rhs.kind)
        }
    }

    private var normalizedMapEvents: [ExternalEvent] {
        preparedMapWorldSnapshot.normalizedEvents
    }

    private func buildNormalizedMapEvents() -> [ExternalEvent] {
        let merged = activeMapEventFeed
        let ranked = merged.sorted(by: mapDuplicatePreference(lhs:rhs:))
        var seenIDs = Set<String>()
        var deduped: [ExternalEvent] = []
        var bucketed: [String: [ExternalEvent]] = [:]

        for event in ranked {
            guard seenIDs.insert(event.id).inserted else { continue }

            let bucket = ExternalEventSupport.dedupeBucketKey(for: event)
            let existingBucket = bucketed[bucket] ?? []
            if existingBucket.contains(where: { ExternalEventSupport.isLikelyDuplicate($0, event) }) {
                continue
            }

            deduped.append(event)
            bucketed[bucket, default: []].append(event)
        }

        return deduped
    }



    private func buildExternalEventEncounters(normalizedMapEvents: [ExternalEvent]) -> [ExploreEncounter] {
        let filterCenter = mapCameraCenter ?? centerCoordinate
        let centerLocation = CLLocation(latitude: filterCenter.latitude, longitude: filterCenter.longitude)

        let visibleEvents = normalizedMapEvents
            .filter { shouldShowExternalEventOnMap($0, centerLocation: centerLocation) }
            .sorted { lhs, rhs in
                mapEventPriority(lhs: lhs, rhs: rhs)
            }

        let locationGroups = groupEventsByLocation(visibleEvents)

        var encounters: [ExploreEncounter] = []
        for group in locationGroups.prefix(250) {
            let primaryEvent = group[0]
            let coordinate = eventCoordinate(primaryEvent) ?? centerCoordinate

            let rewardPolicy = ExternalEventPolicyService.policy(for: primaryEvent)
            let quest = primaryEvent.sideQuestQuest(rewardPolicy: rewardPolicy)
            let timing = mapTiming(for: primaryEvent)

            let pinTitle: String
            let pinSubtitle: String
            let pinFlavor: String

            if group.count > 1 {
                let venueName = primaryEvent.venueName ?? primaryEvent.title
                pinTitle = venueName
                pinSubtitle = "\(group.count) events · \(timing.primaryLabel)"
                pinFlavor = group.prefix(3).map(\.title).joined(separator: ", ")
            } else {
                pinTitle = primaryEvent.title
                let detailBits = [primaryEvent.venueName, timing.secondaryLabel]
                    .compactMap { value -> String? in
                        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !trimmed.isEmpty else { return nil }
                        return trimmed
                    }
                pinSubtitle = [timing.primaryLabel, primaryEvent.venueName].compactMap { $0 }.joined(separator: " • ")
                pinFlavor = detailBits.isEmpty ? "Live event nearby" : detailBits.joined(separator: " • ")
            }

            let mapPOI = MapPOI(
                id: "external_event_\(primaryEvent.id)",
                name: pinTitle,
                coordinate: coordinate,
                category: primaryEvent.mapFallbackCategory,
                address: eventMapAddress(primaryEvent),
                distance: centerLocation.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)),
                placeDescription: primaryEvent.shortDescription ?? primaryEvent.fullDescription,
                websiteURL: nil,
                phoneNumber: nil,
                specificType: primaryEvent.venueName ?? primaryEvent.sideQuestPlaceType.rawValue,
                neighborhood: primaryEvent.neighborhood,
                locality: primaryEvent.city,
                mapItemIdentifier: nil
            )

            let countdownLabel = group.count > 1 ? "\(group.count)" : timing.primaryLabel

            encounters.append(ExploreEncounter(
                id: "encounter_event_\(primaryEvent.id)",
                poi: mapPOI,
                quest: quest,
                title: pinTitle,
                subtitle: pinSubtitle,
                flavorText: pinFlavor,
                kind: .limitedEvent,
                difficulty: quest.difficulty,
                xp: rewardPolicy.xp,
                gold: rewardPolicy.coins,
                estimatedMinutes: quest.effectivePresenceMinutes,
                journeyTitle: nil,
                districtName: primaryEvent.neighborhood ?? primaryEvent.city ?? "Live Event",
                externalEvent: primaryEvent,
                groupedEvents: group.count > 1 ? group : [],
                mapPinAssetName: primaryEvent.mapPinAssetName,
                countdownText: countdownLabel
            ))
        }
        return encounters
    }

    private func groupEventsByLocation(_ events: [ExternalEvent]) -> [[ExternalEvent]] {
        var groups: [[ExternalEvent]] = []
        var assigned: Set<String> = []

        for event in events {
            guard !assigned.contains(event.id) else { continue }
            guard eventCoordinate(event) != nil else { continue }

            var group: [ExternalEvent] = [event]
            assigned.insert(event.id)

            let eventAddressKey = normalizedAddressKey(for: event)
            if let eventAddressKey {
                for other in events where !assigned.contains(other.id) {
                    guard eventCoordinate(other) != nil else { continue }
                    if let otherKey = normalizedAddressKey(for: other), otherKey == eventAddressKey {
                        group.append(other)
                        assigned.insert(other.id)
                    }
                }
            }

            group.sort { lhs, rhs in
                (lhs.startAtUTC ?? .distantFuture) < (rhs.startAtUTC ?? .distantFuture)
            }
            groups.append(group)
        }
        return groups
    }

    private func normalizedAddressKey(for event: ExternalEvent) -> String? {
        guard let address = event.addressLine1?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else { return nil }
        return address.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private var externalEventDiagnosticsSignature: String {
        preparedMapWorldSnapshot.diagnosticsSignature
    }

    private func buildExternalEventDiagnosticsSignature(from normalizedMapEvents: [ExternalEvent]) -> String {
        let fallbackTimeZone = TimeZone.current.identifier
        let missingCoordinates = normalizedMapEvents
            .filter { !isCancelledExternalEvent($0) && eventCoordinate($0) == nil }
            .map(\.id)
            .sorted()
            .joined(separator: ",")
        let missingTimezone = normalizedMapEvents
            .filter { $0.startAtUTC != nil && ($0.timezone?.isEmpty ?? true) }
            .map(\.id)
            .sorted()
            .joined(separator: ",")
        return "\(fallbackTimeZone)|coords:\(missingCoordinates)|tz:\(missingTimezone)"
    }

    private var highlightedEncounters: [ExploreEncounter] {
        encounterList.filter { $0.kind.isHighPriority }
    }

    private var districtOverlays: [ExploreDistrict] {
        let primaryPath = preferredQuestPath
        return [
            ExploreDistrict(
                id: "district_main",
                name: districtPalette[0].name,
                subtitle: biomeSubtitle(for: primaryPath),
                path: primaryPath,
                labelCoordinate: offsetCoordinate(from: centerCoordinate, northMeters: 640, eastMeters: -460),
                coordinates: districtPolygon(center: centerCoordinate, northMeters: 700, eastMeters: -650, widthMeters: 1100, heightMeters: 900)
            ),
            ExploreDistrict(
                id: "district_warrior",
                name: districtPalette[1].name,
                subtitle: biomeSubtitle(for: .warrior),
                path: .warrior,
                labelCoordinate: offsetCoordinate(from: centerCoordinate, northMeters: 120, eastMeters: 620),
                coordinates: districtPolygon(center: centerCoordinate, northMeters: 120, eastMeters: 720, widthMeters: 1150, heightMeters: 920)
            ),
            ExploreDistrict(
                id: "district_mind",
                name: districtPalette[2].name,
                subtitle: biomeSubtitle(for: .mind),
                path: .mind,
                labelCoordinate: offsetCoordinate(from: centerCoordinate, northMeters: -700, eastMeters: -80),
                coordinates: districtPolygon(center: centerCoordinate, northMeters: -660, eastMeters: -60, widthMeters: 1350, heightMeters: 980)
            )
        ]
    }

    private var zoneOverlays: [ExploreZone] {
        let featured = Array(encounterList.filter { $0.kind.isHighPriority }.prefix(4))
        let supporting = Array(encounterList.filter { !$0.kind.isHighPriority }.prefix(1))
        let combined = featured + supporting
        return combined.map { encounter in
            ExploreZone(
                id: "zone_\(encounter.id)",
                title: encounter.title,
                centerCoordinate: encounter.coordinate,
                radius: encounter.zoneRadius,
                category: encounter.poi.category,
                kind: encounter.kind
            )
        }
    }

    private var routeOverlays: [ExploreRoute] {
        let start = poiService.userLocation?.coordinate ?? centerCoordinate
        let primaryTargets = Array(highlightedEncounters.prefix(2))
        guard !primaryTargets.isEmpty else { return [] }

        var routes: [ExploreRoute] = [
            ExploreRoute(
                id: "route_streak",
                title: "Streak Route",
                coordinates: [start] + primaryTargets.map(\.coordinate),
                path: preferredQuestPath
            )
        ]

        let supportingTargets = Array(encounterList.filter { $0.kind == .daily || $0.kind == .sideQuest }.prefix(2))
        if supportingTargets.count == 2 {
            routes.append(
                ExploreRoute(
                    id: "route_sweep",
                    title: "City Sweep",
                    coordinates: [supportingTargets[0].coordinate, centerCoordinate, supportingTargets[1].coordinate],
                    path: .explorer
                )
            )
        }

        return routes
    }

    private var categorySummaryTitle: String {
        "Tailored nearby quests"
    }

    private var worldSubtitle: String {
        let eventCount = encounterList.filter { $0.kind == .limitedEvent }.count
        let quickWinCount = encounterList.filter { $0.kind == .daily || $0.kind == .sideQuest }.count
        return "\(highlightedEncounters.count) priority quests · \(eventCount) live events · \(quickWinCount) quick wins around \(tailoredDescriptor)"
    }

    private var mapWorldDependencyKey: String {
        let poiKey = mixedPOIs
            .map {
                let latitude = String(format: "%.4f", $0.coordinate.latitude)
                let longitude = String(format: "%.4f", $0.coordinate.longitude)
                return "\($0.id):\($0.category.rawValue):\(latitude):\(longitude)"
            }
            .joined(separator: ",")
        let activeMapQuestKey = activeMapQuests
            .map { "\($0.poi.id):\($0.isCheckedIn ? 1 : 0):\($0.isCompleted ? 1 : 0)" }
            .sorted()
            .joined(separator: ",")
        let visitedKey = appState.visitedPOIs
            .map(\.id)
            .sorted()
            .joined(separator: ",")
        let eventKey = activeMapEventFeed
            .map { event in
                let start = event.startAtUTC?.timeIntervalSince1970 ?? -1
                return "\(event.id):\(start):\(event.latitude ?? 0):\(event.longitude ?? 0)"
            }
            .sorted()
            .joined(separator: ",")
        let cameraCenter = mapCameraCenter ?? centerCoordinate
        let locationKey = "\(String(format: "%.4f", cameraCenter.latitude)):\(String(format: "%.4f", cameraCenter.longitude))"
        let countdownBucket = Int(eventCountdownNow.timeIntervalSince1970 / 30)
        return [
            poiKey,
            activeMapQuestKey,
            visitedKey,
            eventKey,
            locationKey,
            selectedCategory.rawValue,
            hasExplicitCategoryFocus ? "1" : "0",
            String(Int(poiService.searchRadiusMeters)),
            String(countdownBucket)
        ].joined(separator: "|")
    }

    private func buildMapWorldSnapshot() -> MapWorldSnapshot {
        let normalizedEvents = buildNormalizedMapEvents()
        let encounters = buildEncounterList(normalizedMapEvents: normalizedEvents)
        let diagnosticsSignature = buildExternalEventDiagnosticsSignature(from: normalizedEvents)
        return MapWorldSnapshot(
            encounters: encounters,
            normalizedEvents: normalizedEvents,
            diagnosticsSignature: diagnosticsSignature
        )
    }

    private func scheduleMapWorldRefresh() {
        let nextSignature = mapWorldDependencyKey
        guard nextSignature != mapWorldSignature || preparedMapWorldSnapshot.encounters.isEmpty else { return }

        mapWorldSignature = nextSignature
        mapWorldGeneration += 1
        let generation = mapWorldGeneration
        if preparedMapWorldSnapshot.encounters.isEmpty {
            isPreparingMapWorld = true
        }

        Task { @MainActor in
            let snapshot = buildMapWorldSnapshot()
            guard mapWorldGeneration == generation else { return }
            preparedMapWorldSnapshot = snapshot
            isPreparingMapWorld = false
            if let selectedEncounter {
                self.selectedEncounter = snapshot.encounters.first(where: { $0.id == selectedEncounter.id })
            }
        }
    }

    private var radiusLabel: String {
        let kilometers = poiService.searchRadiusMeters / 1000
        return kilometers >= 1 ? String(format: "%.0f km", kilometers) : String(format: "%.0f m", poiService.searchRadiusMeters)
    }

    private var selectedEncounterDistance: Double? {
        guard let selectedEncounter else { return nil }
        return poiService.distanceToPOI(selectedEncounter.poi)
    }

    var body: some View {
        ZStack {
            ExploreMapView(
                centerCoordinate: centerCoordinate,
                userCoordinate: usesPreviewLocation ? nil : poiService.userLocation?.coordinate,
                encounters: filteredEncounterList,
                districts: [],
                zones: [],
                routes: [],
                selectedEncounterID: selectedEncounter?.id,
                command: mapCommand,
                onSelectEncounter: { encounter in
                    presentEncounter(encounter)
                },
                onRegionChanged: { viewport in
                    handleRegionChanged(viewport)
                }
            )
            .ignoresSafeArea(edges: .top)
            .overlay {
                cinematicAtmosphereOverlay
                    .allowsHitTesting(false)
            }

            if !poiService.locationAuthorized {
                locationPermissionOverlay
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                topChrome
                mapFilterChips
            }
        }
        .overlay(alignment: .top) {
            if showCheckedInConfirmation {
                checkInBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            if poiService.locationAuthorized {
                floatingControls
                    .padding(.trailing, 16)
                    .padding(.bottom, selectedEncounter == nil ? 80 : 220)
                    .padding(.top, 70)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomChrome
        }
        .task {
            if let previewCoordinate {
                poiService.fallbackCoordinate = previewCoordinate
            }
            if appState.externalEventFeed.isEmpty && !appState.isRefreshingExternalEvents {
                await appState.refreshExternalEvents(forceRefresh: false)
            }
            logExternalEventDiagnosticsIfNeeded(signature: externalEventDiagnosticsSignature)
            if poiService.locationAuthorized, !usesPreviewLocation {
                poiService.requestLocation()
            }
            guard !hasLoadedInitialWorld else { return }
            hasLoadedInitialWorld = true
            if let initialCategory = baseRecommendedCategories.first {
                selectedCategory = initialCategory
            }
            isInitialPOILoadProtected = true
            scheduleViewportDrivenPOILoad(center: centerCoordinate, visibleRadius: currentVisibleRadius, force: true)
            scheduleViewportDrivenEventLoad(center: centerCoordinate, visibleRadius: currentVisibleRadius, force: true)
            scheduleMapWorldRefresh()
            Task {
                try? await Task.sleep(for: .seconds(2))
                isInitialPOILoadProtected = false
            }
        }
        .task(id: mapWorldDependencyKey) {
            scheduleMapWorldRefresh()
        }
        .onChange(of: poiService.userLocation) { _, newValue in
            guard let newValue else { return }
            poiService.fallbackCoordinate = nil
            if !hasCenteredOnUser {
                hasCenteredOnUser = true
                mapCommand = ExploreMapCommand(action: .recenter)
            }
            Task {
                await reloadNearbyQuests(near: newValue)
            }
        }
        .onChange(of: poiService.locationAuthorized) { _, authorized in
            if authorized {
                if !usesPreviewLocation {
                    poiService.requestLocation()
                }
                mapCommand = ExploreMapCommand(action: .recenter)
                Task {
                    await reloadNearbyQuests()
                }
            }
        }
        .onChange(of: appState.externalEventSearchLocation) { _, newValue in
            guard usesPreviewLocation, let coordinate = newValue?.coordinate else { return }
            poiService.fallbackCoordinate = coordinate
            mapCommand = ExploreMapCommand(action: .recenter)
            Task {
                await reloadNearbyQuests()
            }
        }
        .onChange(of: appState.pendingMapCategory) { _, newValue in
            guard let newValue else { return }
            appState.pendingMapCategory = nil
            hasExplicitCategoryFocus = true
            withAnimation(.snappy) {
                selectedCategory = newValue
                selectedEncounter = nil
            }
            Task {
                await reloadNearbyQuests()
            }
        }
        .sheet(item: $selectedExternalEvent) { event in
            NavigationStack {
                ExternalEventDetailView(event: event, appState: appState)
            }
        }
        .sheet(item: Binding(
            get: { groupedEventsSheet.map { GroupedEventsWrapper(events: $0) } },
            set: { wrapper in groupedEventsSheet = wrapper?.events }
        )) { wrapper in
            NavigationStack {
                GroupedEventsListView(events: wrapper.events, appState: appState)
            }
            .presentationDetents([.medium, .large])
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            eventCountdownNow = now
        }
        .onDisappear {
            pendingViewportPOILoadTask?.cancel()
            pendingViewportEventLoadTask?.cancel()
        }
        .onChange(of: externalEventDiagnosticsSignature) { _, signature in
            logExternalEventDiagnosticsIfNeeded(signature: signature)
        }
        .onChange(of: encounterList.map(\.id).joined(separator: "|")) { _, _ in
            guard let selectedEncounter else { return }
            self.selectedEncounter = encounterList.first(where: { $0.id == selectedEncounter.id })
        }
        .sensoryFeedback(.selection, trigger: selectedEncounter?.id)
    }

    private static let fitnessCategories: Set<MapQuestCategory> = [
        .gym, .pool, .basketballCourt, .rockClimbingGym, .martialArts, .tennisCourt, .yogaStudio, .danceStudio
    ]
    private static let outdoorsCategories: Set<MapQuestCategory> = [
        .park, .trail, .beach, .lake, .bikePath, .dogPark, .skatePark
    ]
    private static let cultureCategories: Set<MapQuestCategory> = [
        .library, .bookstore, .museum, .artGallery, .communityCenter, .placeOfWorship, .volunteerCenter
    ]

    private var filteredEncounterList: [ExploreEncounter] {
        guard selectedMapFilter != .all else { return encounterList }
        return encounterList.filter { encounter in
            switch selectedMapFilter {
            case .all:
                return true
            case .nightlife:
                guard let event = encounter.externalEvent else { return false }
                return event.eventType == .partyNightlife || event.recordKind == .venueNight
            case .concerts:
                guard let event = encounter.externalEvent else { return false }
                return event.eventType == .concert
            case .sports:
                guard let event = encounter.externalEvent else { return false }
                return event.eventType == .sportsEvent
            case .races:
                guard let event = encounter.externalEvent else { return false }
                return [.groupRun, .race5k, .race10k, .raceHalfMarathon, .raceMarathon].contains(event.eventType)
            case .community:
                guard let event = encounter.externalEvent else { return false }
                return event.eventType == .socialCommunityEvent || event.eventType == .weekendActivity
            case .liveEvents:
                return encounter.kind == .limitedEvent
            case .fitness:
                return encounter.externalEvent == nil && Self.fitnessCategories.contains(encounter.poi.category)
            case .outdoors:
                return encounter.externalEvent == nil && Self.outdoorsCategories.contains(encounter.poi.category)
            case .culture:
                return encounter.externalEvent == nil && Self.cultureCategories.contains(encounter.poi.category)
            }
        }
    }

    private var topChrome: some View {
        HStack(spacing: 10) {
            Text("Explore")
                .font(.system(.title3, design: .default, weight: .bold))
                .foregroundStyle(.white)

            Text("\(filteredEncounterList.count) nearby")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.72), .black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.bottom, -20)
            .ignoresSafeArea(edges: .top)
        )
    }

    private var mapFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MapExploreFilter.allCases) { filter in
                    let isSelected = selectedMapFilter == filter
                    let count = filterCount(for: filter)
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            selectedMapFilter = filter
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if let symbol = filter.symbol {
                                Image(systemName: symbol)
                                    .font(.caption2.weight(.bold))
                            }
                            Text(filter.label)
                                .font(.caption.weight(.semibold))
                            if filter != .all, count > 0 {
                                Text("(\(count))")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .white.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(filterChipBackground(isSelected: isSelected))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.8))
                    .sensoryFeedback(.selection, trigger: isSelected)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .contentMargins(.horizontal, 0)
    }

    @ViewBuilder
    private func filterChipBackground(isSelected: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if isSelected {
                Color.clear.glassEffect(.regular.tint(.blue).interactive(), in: .capsule)
            } else {
                Color.clear.glassEffect(.regular, in: .capsule)
            }
        } else {
            if isSelected {
                Capsule().fill(.blue.opacity(0.55))
            } else {
                Capsule().fill(.white.opacity(0.12))
            }
        }
    }

    private func filterCount(for filter: MapExploreFilter) -> Int {
        switch filter {
        case .all:
            return encounterList.count
        case .nightlife:
            return encounterList.filter { $0.externalEvent?.eventType == .partyNightlife || $0.externalEvent?.recordKind == .venueNight }.count
        case .concerts:
            return encounterList.filter { $0.externalEvent?.eventType == .concert }.count
        case .sports:
            return encounterList.filter { $0.externalEvent?.eventType == .sportsEvent }.count
        case .races:
            return encounterList.filter { guard let t = $0.externalEvent?.eventType else { return false }; return [.groupRun, .race5k, .race10k, .raceHalfMarathon, .raceMarathon].contains(t) }.count
        case .community:
            return encounterList.filter { guard let t = $0.externalEvent?.eventType else { return false }; return t == .socialCommunityEvent || t == .weekendActivity }.count
        case .liveEvents:
            return encounterList.filter { $0.kind == .limitedEvent }.count
        case .fitness:
            return encounterList.filter { $0.externalEvent == nil && Self.fitnessCategories.contains($0.poi.category) }.count
        case .outdoors:
            return encounterList.filter { $0.externalEvent == nil && Self.outdoorsCategories.contains($0.poi.category) }.count
        case .culture:
            return encounterList.filter { $0.externalEvent == nil && Self.cultureCategories.contains($0.poi.category) }.count
        }
    }

    private var floatingControls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            floatingRoundButton(symbol: "scope", action: .focusObjectives)
            floatingRoundButton(symbol: "location.north.fill", action: .recenter)

            VStack(spacing: 10) {
                floatingRoundButton(symbol: "plus", action: .zoomIn)
                floatingRoundButton(symbol: "minus", action: .zoomOut)
            }
        }
    }

    private func floatingRoundButton(symbol: String, action: ExploreMapCommandAction) -> some View {
        Button {
            withAnimation(.snappy) {
                mapCommand = ExploreMapCommand(action: action)
            }
        } label: {
            Image(systemName: symbol)
                .font(.headline.weight(.bold))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
    }

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if let selectedEncounter {
                ExploreEncounterCard(
                    encounter: selectedEncounter,
                    distanceText: selectedEncounterDistance.map(formatDistance),
                    canCheckIn: poiService.canCheckIn(at: selectedEncounter.poi),
                    isAlreadyActive: activeMapQuests.contains { $0.poi.id == selectedEncounter.poi.id },
                    isVisited: appState.hasVisitedPOI(selectedEncounter.poi),
                    onDismiss: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                            self.selectedEncounter = nil
                        }
                    },
                    onPrimaryAction: {
                        handlePrimaryAction(for: selectedEncounter)
                    },
                    onNavigate: {
                        openInMaps(poi: selectedEncounter.poi)
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ExploreWorldSummaryBar(
                    title: "Nearby for you",
                    subtitle: summaryLine,
                    featured: Array(highlightedEncounters.prefix(2)),
                    onSelectEncounter: { encounter in
                        presentEncounter(encounter)
                    },
                    onScanNearby: {
                        showScannerPulse.toggle()
                        Task {
                            await reloadNearbyQuests()
                        }
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .sensoryFeedback(.impact, trigger: showScannerPulse)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: selectedEncounter?.id)
    }

    private var summaryLine: String {
        let liveCount = encounterList.filter { $0.kind == .limitedEvent }.count
        let quickPlayCount = encounterList.filter { $0.kind == .daily || $0.kind == .sideQuest }.count
        return "Mixed from \(recommendedCategories.count) nearby quest types · \(liveCount) live now · \(quickPlayCount) quick plays"
    }

    private var cinematicAtmosphereOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                colors: [.clear, .black.opacity(0.15), .black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)
        }
        .overlay(alignment: .bottomTrailing) {
            RadialGradient(
                colors: [.blue.opacity(0.14), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 220
            )
        }
    }

    private var loadingOrb: some View {
        ZStack {
            Circle()
                .fill(themeCategory.mapColor.opacity(0.18))
                .frame(width: 72, height: 72)
                .blur(radius: 10)
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.18)
        }
    }

    private var checkInBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Quest completed")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text("XP and gold delivered to your reward stack")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var locationPermissionOverlay: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(themeCategory.mapColor.opacity(0.22))
                        .frame(width: 90, height: 90)
                    Image(systemName: "location.viewfinder")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 8) {
                    Text("Unlock Nearby Quests")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Enable location for live districts, check-in ranges, and a camera angle that follows your city like a game board.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }

                Button {
                    poiService.requestPermission()
                } label: {
                    Label("Enable Location", systemImage: "location.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(.black.opacity(0.42))
    }

    private var headerBackground: some ShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [
                    .black.opacity(0.78),
                    themeCategory.mapColor.opacity(0.20),
                    .black.opacity(0.70)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func worldMetricPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.08), in: Capsule())
    }


    private static let minimumVisibleRadiusForPOIs: Double = 2_000
    private static let maximumPOISearchRadius: Double = 80_000
    private static let maximumVisiblePOIs: Int = 400

    private func reloadNearbyQuests(
        near location: CLLocation? = nil,
        visibleRadius: Double? = nil,
        viewport: ExploreMapViewport? = nil
    ) async {
        let searchLocation: CLLocation = {
            if usesPreviewLocation,
               let previewCoordinate {
                return CLLocation(latitude: previewCoordinate.latitude, longitude: previewCoordinate.longitude)
            }
            if let location {
                return location
            }
            if let userLocation = poiService.userLocation {
                return userLocation
            }
            return CLLocation(latitude: centerCoordinate.latitude, longitude: centerCoordinate.longitude)
        }()

        let effectiveVisibleRadius = max(visibleRadius ?? currentVisibleRadius, Self.minimumVisibleRadiusForPOIs)
        let tileSearchRadius = min(max(effectiveVisibleRadius * 0.55, 4_000), Self.maximumPOISearchRadius)
        let categories = recommendedCategories
        let descriptors = poiTileDescriptors(
            around: searchLocation.coordinate,
            visibleRadius: effectiveVisibleRadius,
            searchRadius: tileSearchRadius,
            categories: categories,
            viewport: viewport ?? currentViewport
        )
        let hasFocusedCategory = hasExplicitCategoryFocus
        let focusedCategory = selectedCategory

        if abs(poiService.searchRadiusMeters - tileSearchRadius) > 500 {
            poiService.searchRadiusMeters = tileSearchRadius
        }

        let allCached = cachedPOITiles.values.flatMap { $0 }
        if !allCached.isEmpty {
            applyLoadedPOIs(Array(allCached), center: searchLocation.coordinate)
        }

        let now = Date()
        let missingDescriptors = descriptors.filter { descriptor in
            let key = descriptor.cacheKey
            if let cached = cachedPOITiles[key], !cached.isEmpty {
                return false
            }
            if cachedPOITiles[key] != nil {
                if let emptyTimestamp = emptyPOITileTimestamps[key],
                   now.timeIntervalSince(emptyTimestamp) < Self.emptyTileRetryInterval {
                    return false
                }
                cachedPOITiles.removeValue(forKey: key)
            }
            return true
        }
        guard !missingDescriptors.isEmpty else {
            hasCompletedInitialFetch = true
            return
        }

        let searchCenter = searchLocation.coordinate
        for descriptor in missingDescriptors {
            let key = descriptor.cacheKey
            guard backgroundPOILoadTasks[key] == nil else { continue }
            guard poiSearchSemaphoreCount < Self.maxConcurrentPOISearches else { break }
            let bucketSize: Int = hasFocusedCategory && descriptor.category == focusedCategory ? 18 : 10
            let descriptorCenter = descriptor.center
            let descriptorCategory = descriptor.category
            let descriptorRadius = descriptor.searchRadius
            poiSearchSemaphoreCount += 1
            backgroundPOILoadTasks[key] = Task {
                let tileLocation = CLLocation(latitude: descriptorCenter.latitude, longitude: descriptorCenter.longitude)
                let results = await Self.searchPOIsLightweight(for: descriptorCategory, near: tileLocation, radius: descriptorRadius)
                let trimmed = Array(results.prefix(bucketSize))
                if trimmed.isEmpty {
                    emptyPOITileTimestamps[key] = Date()
                }
                cachedPOITiles[key] = trimmed
                backgroundPOILoadTasks.removeValue(forKey: key)
                poiSearchSemaphoreCount = max(poiSearchSemaphoreCount - 1, 0)
                let merged = Array(cachedPOITiles.values.flatMap { $0 })
                allCachedPOIs = merged
                applyLoadedPOIs(merged, center: searchCenter)
                hasCompletedInitialFetch = true
                await drainPendingPOISearches()
            }
        }
    }

    private func drainPendingPOISearches() async {
        guard poiSearchSemaphoreCount < Self.maxConcurrentPOISearches else { return }
        let center = mapCameraCenter ?? centerCoordinate
        let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
        await reloadNearbyQuests(near: location, visibleRadius: currentVisibleRadius, viewport: currentViewport)
    }



    private func mixedPOIDeduplicationKey(for poi: MapPOI) -> String {
        let latitudeBucket = Int((poi.coordinate.latitude * 10_000).rounded())
        let longitudeBucket = Int((poi.coordinate.longitude * 10_000).rounded())
        return "\(poi.name.lowercased())_\(latitudeBucket)_\(longitudeBucket)"
    }

    private func poiPriorityScore(for poi: MapPOI, centerLocation: CLLocation? = nil) -> Int {
        let resolvedDistance: Double? = {
            if let explicitDistance = poi.distance {
                return explicitDistance
            }
            guard let centerLocation else { return nil }
            return centerLocation.distance(from: CLLocation(latitude: poi.coordinate.latitude, longitude: poi.coordinate.longitude))
        }()
        let distanceBonus = distancePriority(for: resolvedDistance)
        let unvisitedBonus = appState.hasVisitedPOI(poi) ? -20 : 16
        let focusedCategoryBonus = hasExplicitCategoryFocus && poi.category == selectedCategory ? 22 : 0
        return categoryAffinityScore(for: poi.category) + distanceBonus + unvisitedBonus + focusedCategoryBonus
    }

    private func distancePriority(for distance: Double?) -> Int {
        guard let distance else { return 0 }

        switch distance {
        case ..<300:
            return 36
        case ..<800:
            return 24
        case ..<1_500:
            return 14
        default:
            return 6
        }
    }

    private func categoryAffinityScore(for category: MapQuestCategory) -> Int {
        var score: Int = 12

        switch category {
        case .park, .gym:
            score += 14
        case .library, .cafe, .trail:
            score += 12
        case .bookstore, .museum, .pool, .beach:
            score += 8
        case .restaurant, .farmersMarket, .lake, .bikePath, .communityCenter:
            score += 5
        default:
            score += 2
        }

        for (index, path) in appState.pathOrder.enumerated() {
            if category.questPath == path {
                score += max(18 - (index * 6), 6)
            }
        }

        for skill in appState.profile.selectedSkills {
            if categoryMatches(skill: skill, category: category) {
                score += 10
            }
        }

        for interest in appState.profile.selectedInterests {
            if categoryMatches(interest: interest, category: category) {
                score += 10
            }
        }

        if activeMapQuests.contains(where: { $0.category.questPath == category.questPath }) {
            score += 8
        }

        return score
    }

    private func categoryMatches(skill: UserSkill, category: MapQuestCategory) -> Bool {
        switch skill {
        case .charisma, .leadership:
            return [.communityCenter, .volunteerCenter, .restaurant, .cafe].contains(category)
        case .mindfulness, .focus, .intelligence, .creativity:
            return [.library, .bookstore, .museum, .artGallery, .yogaStudio, .cafe, .placeOfWorship].contains(category)
        case .discipline, .strength, .endurance, .resilience:
            return [.gym, .park, .trail, .pool, .basketballCourt, .martialArts, .rockClimbingGym, .bikePath, .tennisCourt].contains(category)
        }
    }

    private func categoryMatches(interest: UserInterest, category: MapQuestCategory) -> Bool {
        switch interest {
        case .nature, .exploration, .hiking, .travel, .outdoors:
            return [.park, .trail, .beach, .lake, .bikePath].contains(category)
        case .animals:
            return [.dogPark, .park, .volunteerCenter].contains(category)
        case .cardio, .fitness, .running:
            return [.gym, .park, .trail, .pool, .basketballCourt, .bikePath, .tennisCourt].contains(category)
        case .photography, .art:
            return [.artGallery, .museum, .park, .beach, .cafe].contains(category)
        case .writing, .reading, .brainTraining, .chess:
            return [.library, .bookstore, .museum, .cafe].contains(category)
        case .meditation, .yoga, .wellness, .spirituality:
            return [.yogaStudio, .lake, .park, .placeOfWorship, .artGallery].contains(category)
        case .cooking:
            return [.farmersMarket, .restaurant, .cafe].contains(category)
        case .music:
            return [.communityCenter, .cafe, .restaurant, .artGallery].contains(category)
        case .volunteering:
            return [.volunteerCenter, .communityCenter, .placeOfWorship].contains(category)
        }
    }

    private func handlePrimaryAction(for encounter: ExploreEncounter) {
        if !encounter.groupedEvents.isEmpty {
            groupedEventsSheet = encounter.groupedEvents
            return
        }
        if let externalEvent = encounter.externalEvent {
            selectedExternalEvent = externalEvent
            return
        }
        if poiService.canCheckIn(at: encounter.poi), activeMapQuests.contains(where: { $0.poi.id == encounter.poi.id }) {
            handleCheckIn(encounter: encounter)
        } else if !activeMapQuests.contains(where: { $0.poi.id == encounter.poi.id }) && !appState.hasVisitedPOI(encounter.poi) {
            startQuest(encounter: encounter)
        } else {
            openInMaps(poi: encounter.poi)
        }
    }

    private func handleCheckIn(encounter: ExploreEncounter) {
        guard poiService.canCheckIn(at: encounter.poi) else { return }

        if let index = activeMapQuests.firstIndex(where: { $0.poi.id == encounter.poi.id }) {
            activeMapQuests[index].isCheckedIn = true
            activeMapQuests[index].checkedInAt = Date()
            activeMapQuests[index].isCompleted = true
        }

        completeMapQuest(encounter: encounter)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            showCheckedInConfirmation = true
            selectedEncounter = nil
        }

        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeInOut(duration: 0.2)) {
                showCheckedInConfirmation = false
            }
        }
    }

    private func completeMapQuest(encounter: ExploreEncounter) {
        let quest = encounter.quest ?? Self.makeQuestFromPOI(encounter.poi)
        appState.recordVisitedPOI(encounter.poi, questTitle: quest.title)

        if let index = appState.activeInstances.firstIndex(where: { $0.quest.id == quest.id && $0.state.isActive }) {
            appState.activeInstances[index].state = .verified
            appState.activeInstances[index].verifiedAt = Date()
            appState.activeInstances[index].submittedAt = Date()
        }

        let streakMultiplier = LevelSystem.streakMultiplier(for: appState.profile.currentStreak)
        let rawXP = Int(Double(quest.xpReward) * streakMultiplier)
        let rawGold = Int(Double(quest.goldReward) * streakMultiplier)

        let instance = QuestInstance(
            id: UUID().uuidString,
            quest: quest,
            state: .verified,
            mode: .solo,
            startedAt: Date(),
            submittedAt: Date(),
            verifiedAt: Date(),
            groupId: nil
        )
        appState.openPlayHistory.insert(instance, at: 0)

        let reward = RewardEvent(
            id: UUID().uuidString,
            questTitle: quest.title,
            xpEarned: rawXP,
            goldEarned: rawGold,
            diamondsEarned: 0,
            streakBonus: streakMultiplier > 1.0,
            streakMultiplier: streakMultiplier,
            newBadge: nil,
            createdAt: Date()
        )
        appState.profile.totalScore += rawXP
        appState.profile.gold += rawGold
        appState.pendingRewards.append(reward)
        appState.completedHistory.insert(reward, at: 0)
        appState.showRewardOverlay = true
        appState.recordDailyCompletion()
    }

    private func startQuest(encounter: ExploreEncounter) {
        let poi = encounter.poi
        guard !activeMapQuests.contains(where: { $0.poi.id == poi.id }) else { return }
        let quest = encounter.quest ?? Self.makeQuestFromPOI(poi)
        appState.acceptQuest(quest, mode: .solo)

        let instance = MapQuestInstance(
            id: UUID().uuidString,
            poi: poi,
            category: poi.category,
            startedAt: Date(),
            isCheckedIn: false,
            checkedInAt: nil,
            isCompleted: false
        )
        activeMapQuests.append(instance)
        poiService.startContinuousUpdates()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            selectedEncounter = encounterList.first(where: { $0.poi.id == poi.id && $0.kind == .activeQuest })
        }
    }

    static func makeQuestFromPOI(_ poi: MapPOI) -> Quest {
        let category = poi.category
        return Quest(
            id: "map_\(category.rawValue.lowercased())_\(poi.id)",
            title: "Visit \(poi.name)",
            description: "Travel to \(poi.name) and check in through the Explore map. Stay within \(Int(category.checkInRadiusMeters))m for at least \(category.presenceTimerMinutes) minutes.",
            path: category.questPath,
            difficulty: category.questDifficulty,
            type: .verified,
            evidenceType: nil,
            xpReward: category.questXPReward,
            goldReward: category.questGoldReward,
            diamondReward: 0,
            milestoneIds: [],
            minCompletionMinutes: category.presenceTimerMinutes,
            isRepeatable: false,
            requiresUniqueLocation: true,
            isFeatured: false,
            featuredExpiresAt: nil,
            completionCount: 0,
            cooldownDays: category.cooldownDays
        )
    }

    private func handleRegionChanged(_ viewport: ExploreMapViewport) {
        currentVisibleRadius = viewport.visibleRadius
        mapCameraCenter = viewport.center
        currentViewport = viewport
        scheduleViewportDrivenEventLoad(center: viewport.center, visibleRadius: viewport.visibleRadius)
        scheduleViewportDrivenPOILoad(center: viewport.center, visibleRadius: viewport.visibleRadius)
    }

    private func openInMaps(poi: MapPOI) {
        let placemark = MKPlacemark(coordinate: poi.coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = poi.name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters)) m away"
        }
        return String(format: "%.1f km away", meters / 1000)
    }

    private func radiusButtonTitle(for radius: Double) -> String {
        let kilometers = radius / 1000
        return kilometers >= 1 ? String(format: "%.0f km", kilometers) : String(format: "%.0f m", radius)
    }

    private func presentEncounter(_ encounter: ExploreEncounter) {
        if !encounter.groupedEvents.isEmpty {
            groupedEventsSheet = encounter.groupedEvents
        } else if let externalEvent = encounter.externalEvent {
            selectedEncounter = nil
            selectedExternalEvent = externalEvent
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                selectedEncounter = encounter
            }
        }
    }

    private func scheduleViewportDrivenEventLoad(
        center: CLLocationCoordinate2D,
        visibleRadius: Double,
        force: Bool = false
    ) {
        guard isViewportEventTileFeedEnabled else { return }

        let viewport = currentViewport ?? fallbackViewport(center: center, visibleRadius: visibleRadius)
        let request = makeViewportEventRequest(for: viewport)
        if !force, request.signature == lastViewportEventRequestSignature {
            return
        }
        lastViewportEventRequestSignature = request.signature

        let cachedEvents = aggregatedAllCachedViewportEvents()
        if !cachedEvents.isEmpty || hasResolvedViewportEventFeed {
            viewportExternalEvents = cachedEvents
        }

        let missingIntents = request.intents.filter { intent in
            requestTileCacheKeys(for: request, intent: intent).contains { viewportEventTileCache[$0] == nil }
        }
        guard !missingIntents.isEmpty else {
            viewportExternalEvents = cachedEvents
            hasResolvedViewportEventFeed = true
            return
        }

        pendingViewportEventLoadTask?.cancel()
        pendingViewportEventLoadTask = Task {
            guard !Task.isCancelled else { return }

            let service = SupabaseEventViewportTileService.shared
            let loadedBundles = await withTaskGroup(
                of: ExternalEventViewportTileBundle?.self,
                returning: [ExternalEventViewportTileBundle].self
            ) { group in
                for intent in missingIntents {
                    group.addTask {
                        await service.loadBundle(
                            intent: intent,
                            range: request.range,
                            countryCode: request.countryCode,
                            state: nil
                        )
                    }
                }

                var bundles: [ExternalEventViewportTileBundle] = []
                for await bundle in group {
                    if let bundle {
                        bundles.append(bundle)
                    }
                }
                return bundles
            }

            guard !Task.isCancelled, !loadedBundles.isEmpty else { return }

            var updatedCache = viewportEventTileCache
            for bundle in loadedBundles {
                for tile in bundle.tiles {
                    let cacheKey = viewportTileCacheKey(for: tile.tile)
                    var cachedSnapshots = updatedCache[cacheKey] ?? []
                    if let existingIndex = cachedSnapshots.firstIndex(where: { $0.id == tile.id }) {
                        cachedSnapshots[existingIndex] = tile
                    } else {
                        cachedSnapshots.append(tile)
                    }
                    updatedCache[cacheKey] = cachedSnapshots
                }
            }

            viewportEventTileCache = updatedCache
            viewportExternalEvents = aggregatedAllCachedViewportEvents()
            hasResolvedViewportEventFeed = true
        }
    }

    private func aggregatedAllCachedViewportEvents() -> [ExternalEvent] {
        viewportEventTileCache.values
            .flatMap { $0 }
            .flatMap(\.mergedEvents)
    }

    private func makeViewportEventRequest(for viewport: ExploreMapViewport) -> ViewportEventRequest {
        let bounds = ExternalEventViewportBounds(
            northLatitude: max(viewport.northEast.latitude, viewport.northWest.latitude),
            southLatitude: min(viewport.southEast.latitude, viewport.southWest.latitude),
            eastLongitude: max(viewport.northEast.longitude, viewport.southEast.longitude),
            westLongitude: min(viewport.northWest.longitude, viewport.southWest.longitude)
        )

        var zoom = SupabaseEventViewportTileService.shared.recommendedZoom(for: bounds)
        var range = SupabaseEventViewportTileService.shared.tileRange(for: bounds, zoom: zoom)
        while range.tileCount > 196, zoom > 0 {
            zoom -= 1
            range = SupabaseEventViewportTileService.shared.tileRange(for: bounds, zoom: zoom)
        }

        let paddedRange = expandedViewportTileRange(range, padding: 1)
        let resolvedRange = paddedRange.tileCount <= 196 ? paddedRange : range
        let intents = viewportEventTileIntents
        let signature = [
            viewportEventCountryCode,
            intents.map(\.rawValue).joined(separator: ","),
            "z\(resolvedRange.z)",
            "x\(resolvedRange.minX)-\(resolvedRange.maxX)",
            "y\(resolvedRange.minY)-\(resolvedRange.maxY)"
        ].joined(separator: "|")

        return ViewportEventRequest(
            bounds: bounds,
            range: resolvedRange,
            intents: intents,
            countryCode: viewportEventCountryCode,
            signature: signature
        )
    }

    private func expandedViewportTileRange(
        _ range: ExternalEventViewportTileRange,
        padding: Int
    ) -> ExternalEventViewportTileRange {
        ExternalEventViewportTileRange(
            z: range.z,
            minX: max(range.minX - padding, 0),
            maxX: range.maxX + padding,
            minY: max(range.minY - padding, 0),
            maxY: range.maxY + padding
        )
    }

    private func requestTileCacheKeys(
        for request: ViewportEventRequest,
        intent: ExternalDiscoveryIntent
    ) -> [String] {
        var keys: [String] = []
        for x in request.range.minX ... request.range.maxX {
            for y in request.range.minY ... request.range.maxY {
                keys.append(
                    viewportTileCacheKey(
                        intent: intent,
                        countryCode: request.countryCode,
                        z: request.range.z,
                        x: x,
                        y: y
                    )
                )
            }
        }
        return keys
    }

    private func viewportTileCacheKey(for tile: ExternalEventViewportTileKey) -> String {
        viewportTileCacheKey(
            intent: tile.intent,
            countryCode: tile.countryCode,
            z: tile.z,
            x: tile.x,
            y: tile.y
        )
    }

    private func viewportTileCacheKey(
        intent: ExternalDiscoveryIntent,
        countryCode: String,
        z: Int,
        x: Int,
        y: Int
    ) -> String {
        [
            intent.rawValue,
            countryCode.uppercased(),
            String(z),
            String(x),
            String(y)
        ].joined(separator: "::")
    }

    private func aggregatedViewportEvents(
        for request: ViewportEventRequest,
        using cache: [String: [ExternalEventViewportTileSnapshot]]
    ) -> [ExternalEvent] {
        request.intents
            .flatMap { intent in
                requestTileCacheKeys(for: request, intent: intent).flatMap { cache[$0] ?? [] }
            }
            .flatMap(\.mergedEvents)
    }

    private func shouldShowExternalEventOnMap(_ event: ExternalEvent, centerLocation: CLLocation) -> Bool {
        guard !isCancelledExternalEvent(event), !isEndedExternalEvent(event) else { return false }
        guard let coordinate = eventCoordinate(event) else { return false }
        if let viewport = currentViewport {
            return coordinateIsInsideExpandedViewport(coordinate, viewport: viewport)
        }
        return true
    }

    private func coordinateIsInsideExpandedViewport(
        _ coordinate: CLLocationCoordinate2D,
        viewport: ExploreMapViewport
    ) -> Bool {
        let north = max(viewport.northEast.latitude, viewport.northWest.latitude)
        let south = min(viewport.southEast.latitude, viewport.southWest.latitude)
        let east = max(viewport.northEast.longitude, viewport.southEast.longitude)
        let west = min(viewport.northWest.longitude, viewport.southWest.longitude)
        let latitudePadding = max((north - south) * 0.18, 0.02)
        let longitudePadding = max((east - west) * 0.18, 0.02)

        return coordinate.latitude >= south - latitudePadding
            && coordinate.latitude <= north + latitudePadding
            && coordinate.longitude >= west - longitudePadding
            && coordinate.longitude <= east + longitudePadding
    }

    private func scheduleViewportDrivenPOILoad(
        center: CLLocationCoordinate2D,
        visibleRadius: Double,
        force: Bool = false
    ) {
        let viewport = currentViewport ?? fallbackViewport(center: center, visibleRadius: visibleRadius)
        let nextRequest = ViewportPOIRequest(
            center: center,
            visibleRadius: visibleRadius,
            northEast: viewport.northEast,
            northWest: viewport.northWest,
            southEast: viewport.southEast,
            southWest: viewport.southWest
        )
        if !force, nextRequest == lastViewportPOIRequest {
            return
        }
        lastViewportPOIRequest = nextRequest
        if isInitialPOILoadProtected {
            return
        }
        pendingViewportPOILoadTask?.cancel()
        pendingViewportPOILoadTask = Task {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(force ? 0 : 300))
            guard !Task.isCancelled else { return }
            let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
            await reloadNearbyQuests(near: location, visibleRadius: visibleRadius, viewport: viewport)
        }
    }

    private func poiTileDescriptors(
        around center: CLLocationCoordinate2D,
        visibleRadius: Double,
        searchRadius: Double,
        categories: [MapQuestCategory],
        viewport: ExploreMapViewport?
    ) -> [POITileDescriptor] {
        let anchors = viewportAnchors(for: viewport, center: center, visibleRadius: visibleRadius)
        let bucketMeters = max(searchRadius * 0.75, 1_000)
        let latitudeStep = bucketMeters / 111_320
        let safeCosine = max(cos(center.latitude * .pi / 180), 0.2)
        let longitudeStep = bucketMeters / (111_320 * safeCosine)

        var seenKeys: Set<String> = []
        var descriptors: [POITileDescriptor] = []

        for category in categories {
            for anchor in anchors {
                let descriptor = POITileDescriptor(
                    category: category,
                    center: anchor,
                    searchRadius: searchRadius,
                    bucketLatitude: Int((anchor.latitude / latitudeStep).rounded()),
                    bucketLongitude: Int((anchor.longitude / longitudeStep).rounded())
                )
                if seenKeys.insert(descriptor.cacheKey).inserted {
                    descriptors.append(descriptor)
                }
            }
        }

        return descriptors
    }

    private func viewportAnchors(
        for viewport: ExploreMapViewport?,
        center: CLLocationCoordinate2D,
        visibleRadius: Double
    ) -> [CLLocationCoordinate2D] {
        let vp = viewport ?? fallbackViewport(center: center, visibleRadius: visibleRadius)

        let north = max(vp.northEast.latitude, vp.northWest.latitude)
        let south = min(vp.southEast.latitude, vp.southWest.latitude)
        let east = max(vp.northEast.longitude, vp.southEast.longitude)
        let west = min(vp.northWest.longitude, vp.southWest.longitude)

        let latSpan = north - south
        let lonSpan = east - west

        let gridSize: Int
        if visibleRadius > 200_000 {
            gridSize = 5
        } else if visibleRadius > 50_000 {
            gridSize = 4
        } else {
            gridSize = 3
        }

        var anchors: [CLLocationCoordinate2D] = []
        for row in 0 ..< gridSize {
            for col in 0 ..< gridSize {
                let latFraction = (Double(row) + 0.5) / Double(gridSize)
                let lonFraction = (Double(col) + 0.5) / Double(gridSize)
                anchors.append(CLLocationCoordinate2D(
                    latitude: south + latSpan * latFraction,
                    longitude: west + lonSpan * lonFraction
                ))
            }
        }
        return anchors
    }

    private func fallbackViewport(center: CLLocationCoordinate2D, visibleRadius: Double) -> ExploreMapViewport {
        let northEast = offsetCoordinate(from: center, northMeters: visibleRadius, eastMeters: visibleRadius)
        let northWest = offsetCoordinate(from: center, northMeters: visibleRadius, eastMeters: -visibleRadius)
        let southEast = offsetCoordinate(from: center, northMeters: -visibleRadius, eastMeters: visibleRadius)
        let southWest = offsetCoordinate(from: center, northMeters: -visibleRadius, eastMeters: -visibleRadius)
        let topLeftPoint = MKMapPoint(northWest)
        let bottomRightPoint = MKMapPoint(southEast)
        let mapRect = MKMapRect(
            x: min(topLeftPoint.x, bottomRightPoint.x),
            y: min(topLeftPoint.y, bottomRightPoint.y),
            width: abs(bottomRightPoint.x - topLeftPoint.x),
            height: abs(bottomRightPoint.y - topLeftPoint.y)
        )
        return ExploreMapViewport(
            center: center,
            visibleRadius: visibleRadius,
            northEast: northEast,
            northWest: northWest,
            southEast: southEast,
            southWest: southWest,
            mapRect: mapRect
        )
    }

    private func applyLoadedPOIs(_ pois: [MapPOI], center: CLLocationCoordinate2D) {
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let sortedAggregated: [MapPOI] = pois.sorted { lhs, rhs in
            let lhsScore = poiPriorityScore(for: lhs, centerLocation: centerLocation)
            let rhsScore = poiPriorityScore(for: rhs, centerLocation: centerLocation)

            if lhsScore == rhsScore {
                return (lhs.distance ?? .greatestFiniteMagnitude) < (rhs.distance ?? .greatestFiniteMagnitude)
            }
            return lhsScore > rhsScore
        }

        var deduplicated: [MapPOI] = []
        var seenKeys: Set<String> = []
        for poi in sortedAggregated {
            let key = mixedPOIDeduplicationKey(for: poi)
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            deduplicated.append(poi)
        }

        let newPOIs = Array(deduplicated.prefix(Self.maximumVisiblePOIs))
        let oldIDs = Set(mixedPOIs.map(\.id))
        let newIDs = Set(newPOIs.map(\.id))
        guard oldIDs != newIDs else { return }
        mixedPOIs = newPOIs
    }

    private func isCancelledExternalEvent(_ event: ExternalEvent) -> Bool {
        switch (event.status, event.availabilityStatus) {
        case (.cancelled, _), (_, .cancelled):
            return true
        default:
            return false
        }
    }

    private func isEndedExternalEvent(_ event: ExternalEvent) -> Bool {
        if case .ended = event.status { return true }
        if case .ended = event.availabilityStatus { return true }
        if let endAtUTC = event.endAtUTC, endAtUTC <= eventCountdownNow {
            return true
        }
        guard let startAtUTC = event.startAtUTC, startAtUTC <= eventCountdownNow else {
            return false
        }
        let expiryWindowHours: TimeInterval = event.recordKind == .venueNight ? 8 : 6
        return eventCountdownNow.timeIntervalSince(startAtUTC) > (expiryWindowHours * 3600)
    }

    private func eventCoordinate(_ event: ExternalEvent) -> CLLocationCoordinate2D? {
        guard let latitude = event.latitude,
              let longitude = event.longitude else {
            return nil
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private func eventMapAddress(_ event: ExternalEvent) -> String? {
        let parts: [String] = [
            event.addressLine1,
            event.addressLine2,
            event.city,
            event.state,
            event.postalCode
        ]
            .compactMap { value in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func mapTiming(for event: ExternalEvent) -> (primaryLabel: String, secondaryLabel: String?) {
        guard let startAtUTC = event.startAtUTC else {
            return ("Time TBA", nil)
        }

        let timezone = resolvedTimeZone(for: event)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let startLine = formattedLocalStartLine(for: event, timezone: timezone)

        if startAtUTC <= eventCountdownNow {
            if let endAtUTC = event.endAtUTC, endAtUTC > eventCountdownNow {
                return ("Live now", startLine)
            }
            let elapsedMinutes = max(1, Int(eventCountdownNow.timeIntervalSince(startAtUTC) / 60))
            if elapsedMinutes < 60 {
                return ("Started \(elapsedMinutes)m ago", startLine)
            }
            return ("Started \(elapsedMinutes / 60)h ago", startLine)
        }

        let components = calendar.dateComponents([.day, .hour, .minute], from: eventCountdownNow, to: startAtUTC)
        if let day = components.day, day >= 2 {
            return ("In \(day)d", startLine)
        }
        if calendar.isDateInTomorrow(startAtUTC) {
            return ("Tomorrow", startLine)
        }
        if let hour = components.hour, hour >= 1 {
            return ("In \(hour)h", startLine)
        }
        if let minute = components.minute, minute >= 1 {
            return ("In \(minute)m", startLine)
        }
        return ("Starting now", startLine)
    }

    private func formattedLocalStartLine(for event: ExternalEvent, timezone: TimeZone) -> String? {
        guard let startAtUTC = event.startAtUTC else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE h:mm a"
        return "\(formatter.string(from: startAtUTC)) \(timezone.abbreviation(for: startAtUTC) ?? timezone.identifier)"
    }

    private func resolvedTimeZone(for event: ExternalEvent) -> TimeZone {
        if let identifier = event.timezone,
           let timezone = TimeZone(identifier: identifier) {
            return timezone
        }
        return .current
    }

    private func limitedEventSortDate(for encounter: ExploreEncounter) -> Date {
        encounter.externalEvent?.startAtUTC ?? .distantFuture
    }

    private func mapEventPriority(lhs: ExternalEvent, rhs: ExternalEvent) -> Bool {
        let lhsRank = mapEventRank(lhs)
        let rhsRank = mapEventRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        let lhsDistance = eventCoordinate(lhs).map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: centerCoordinate.latitude, longitude: centerCoordinate.longitude))
        } ?? .greatestFiniteMagnitude
        let rhsDistance = eventCoordinate(rhs).map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: centerCoordinate.latitude, longitude: centerCoordinate.longitude))
        } ?? .greatestFiniteMagnitude

        if lhsDistance != rhsDistance {
            return lhsDistance < rhsDistance
        }

        return (lhs.startAtUTC ?? .distantFuture) < (rhs.startAtUTC ?? .distantFuture)
    }

    private func mapDuplicatePreference(lhs: ExternalEvent, rhs: ExternalEvent) -> Bool {
        let lhsCompleteness = ExternalEventSupport.completenessScore(for: lhs)
        let rhsCompleteness = ExternalEventSupport.completenessScore(for: rhs)
        if lhsCompleteness != rhsCompleteness {
            return lhsCompleteness > rhsCompleteness
        }

        let lhsSourcePriority = ExternalEventSupport.sourcePriority(for: lhs)
        let rhsSourcePriority = ExternalEventSupport.sourcePriority(for: rhs)
        if lhsSourcePriority != rhsSourcePriority {
            return lhsSourcePriority > rhsSourcePriority
        }

        let lhsHasImages = !ExternalEventSupport.preferredImageURLs(for: lhs, limit: 1).isEmpty
        let rhsHasImages = !ExternalEventSupport.preferredImageURLs(for: rhs, limit: 1).isEmpty
        if lhsHasImages != rhsHasImages {
            return lhsHasImages && !rhsHasImages
        }

        let lhsHasTimezone = !(lhs.timezone?.isEmpty ?? true)
        let rhsHasTimezone = !(rhs.timezone?.isEmpty ?? true)
        if lhsHasTimezone != rhsHasTimezone {
            return lhsHasTimezone && !rhsHasTimezone
        }

        let lhsHasEnd = lhs.endAtUTC != nil
        let rhsHasEnd = rhs.endAtUTC != nil
        if lhsHasEnd != rhsHasEnd {
            return lhsHasEnd && !rhsHasEnd
        }

        return mapEventPriority(lhs: lhs, rhs: rhs)
    }

    private func mapEventRank(_ event: ExternalEvent) -> Int {
        guard let startAtUTC = event.startAtUTC else { return 3 }
        if startAtUTC <= eventCountdownNow { return 0 }
        let delta = startAtUTC.timeIntervalSince(eventCountdownNow)
        if delta <= 6 * 3600 { return 1 }
        if delta <= 24 * 3600 { return 2 }
        return 3
    }

    private func logExternalEventDiagnosticsIfNeeded(signature: String) {
        guard !signature.isEmpty, signature != loggedExternalEventDiagnosticsSignature else { return }
        loggedExternalEventDiagnosticsSignature = signature

        let missingCoordinates = normalizedMapEvents
            .filter { !isCancelledExternalEvent($0) && eventCoordinate($0) == nil }
            .map(\.id)
            .sorted()
        if !missingCoordinates.isEmpty {
            print("[MapExploreView] Skipping \(missingCoordinates.count) external event(s) on map because normalized coordinates are missing: \(missingCoordinates.joined(separator: ", "))")
        }

        let missingTimezone = normalizedMapEvents
            .filter { $0.startAtUTC != nil && ($0.timezone?.isEmpty ?? true) }
            .map(\.id)
            .sorted()
        if !missingTimezone.isEmpty {
            print("[MapExploreView] Falling back to device timezone \(TimeZone.current.identifier) for \(missingTimezone.count) external event countdown(s) because timezone is missing: \(missingTimezone.joined(separator: ", "))")
        }
    }

    private func priorityValue(for kind: ExploreEncounterKind) -> Int {
        switch kind {
        case .activeQuest:
            return 7
        case .mainQuest:
            return 6
        case .limitedEvent:
            return 5
        case .daily:
            return 4
        case .sideQuest:
            return 3
        case .hotspot:
            return 2
        case .visitedShrine:
            return 1
        }
    }

    private func biomeSubtitle(for path: QuestPath) -> String {
        switch path {
        case .warrior:
            return "Training Grounds"
        case .explorer:
            return "Discovery Biome"
        case .mind:
            return "Focus District"
        }
    }

    private func districtPolygon(center: CLLocationCoordinate2D, northMeters: Double, eastMeters: Double, widthMeters: Double, heightMeters: Double) -> [CLLocationCoordinate2D] {
        let anchor = offsetCoordinate(from: center, northMeters: northMeters, eastMeters: eastMeters)
        return [
            offsetCoordinate(from: anchor, northMeters: heightMeters / 2, eastMeters: -widthMeters / 2),
            offsetCoordinate(from: anchor, northMeters: heightMeters / 2, eastMeters: widthMeters / 2),
            offsetCoordinate(from: anchor, northMeters: -heightMeters / 2, eastMeters: widthMeters / 2),
            offsetCoordinate(from: anchor, northMeters: -heightMeters / 2, eastMeters: -widthMeters / 2)
        ]
    }

    private func offsetCoordinate(from coordinate: CLLocationCoordinate2D, northMeters: Double, eastMeters: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6_378_137.0
        let latitudeOffset = (northMeters / earthRadius) * (180 / Double.pi)
        let longitudeOffset = (eastMeters / (earthRadius * cos(coordinate.latitude * Double.pi / 180))) * (180 / Double.pi)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeOffset,
            longitude: coordinate.longitude + longitudeOffset
        )
    }

    private var districtPalette: [(name: String, subtitle: String)] {
        [
            ("Lantern Rise", "Main objective belt"),
            ("Forge Mile", "Momentum and challenge"),
            ("Quiet Quarter", "Focus and reset")
        ]
    }

    private static let defaultFallback = CLLocationCoordinate2D(latitude: 34.0900, longitude: -118.3617)

    static func searchPOIsLightweight(for category: MapQuestCategory, near location: CLLocation?, radius: Double) async -> [MapPOI] {
        let center = location?.coordinate ?? defaultFallback
        let userLoc = location ?? CLLocation(latitude: center.latitude, longitude: center.longitude)

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category.searchQuery
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )

        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            return response.mapItems.compactMap { item in
                guard let name = item.name else { return nil }
                if let poiCat = item.pointOfInterestCategory, poiCat == .parking { return nil }
                if category == .park || category == .dogPark || category == .skatePark {
                    let lower = name.lowercased()
                    let excluded = ["parking", "garage", "car park", "parking lot", "valet", "park & ride", "park and ride"]
                    if excluded.contains(where: { lower.contains($0) }) { return nil }
                }
                let itemLocation = CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
                let dist = userLoc.distance(from: itemLocation)
                guard dist <= radius else { return nil }
                let address = [item.placemark.subThoroughfare, item.placemark.thoroughfare, item.placemark.locality].compactMap { $0 }.joined(separator: " ")
                return MapPOI(
                    id: "\(category.rawValue)_\(item.placemark.coordinate.latitude)_\(item.placemark.coordinate.longitude)",
                    name: name,
                    coordinate: item.placemark.coordinate,
                    category: category,
                    address: address.isEmpty ? nil : address,
                    distance: dist,
                    placeDescription: nil,
                    websiteURL: item.url,
                    phoneNumber: item.phoneNumber,
                    specificType: nil,
                    neighborhood: item.placemark.subLocality,
                    locality: item.placemark.locality,
                    mapItemIdentifier: item.identifier
                )
            }
            .sorted { ($0.distance ?? 0) < ($1.distance ?? 0) }
        } catch {
            return []
        }
    }
}

private struct ExploreEncounterCard: View {
    let encounter: ExploreEncounter
    let distanceText: String?
    let canCheckIn: Bool
    let isAlreadyActive: Bool
    let isVisited: Bool
    let onDismiss: () -> Void
    let onPrimaryAction: () -> Void
    let onNavigate: () -> Void

    private var primaryButtonTitle: String {
        if canCheckIn && isAlreadyActive {
            return "Check In"
        }
        if isAlreadyActive {
            return "Tracked"
        }
        if isVisited {
            return "Revisit"
        }
        return "Start Quest"
    }

    private var primaryButtonSymbol: String {
        if canCheckIn && isAlreadyActive {
            return "location.fill"
        }
        if isAlreadyActive {
            return "flag.fill"
        }
        if isVisited {
            return "arrow.clockwise"
        }
        return "sparkles"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(encounter.poi.category.mapColor.opacity(0.22))
                        .frame(width: 54, height: 54)
                    Image(systemName: encounter.kind.systemImageName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(encounter.kind.shortLabel)
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(encounter.poi.category.mapColor.opacity(0.26), in: Capsule())
                        if let journeyTitle = encounter.journeyTitle {
                            Text(journeyTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                        }
                    }

                    Text(encounter.title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(encounter.subtitle) · \(encounter.districtName)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }

            Text(encounter.flavorText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                infoPill(icon: "bolt.fill", text: "\(encounter.xp) XP", tint: .orange)
                infoPill(icon: "dollarsign.circle.fill", text: "\(encounter.gold) Gold", tint: .yellow)
                infoPill(icon: "clock.fill", text: "~\(encounter.estimatedMinutes) min", tint: .cyan)
                if let distanceText {
                    infoPill(icon: "figure.walk", text: distanceText, tint: .green)
                }
            }

            HStack(spacing: 12) {
                cardStat(title: "Difficulty", value: encounter.difficulty.rawValue)
                cardStat(title: "Path", value: encounter.poi.category.questPath.rawValue)
                cardStat(title: "Zone", value: encounter.kind.rawValue)
            }

            HStack(spacing: 12) {
                Button {
                    onPrimaryAction()
                } label: {
                    Label(primaryButtonTitle, systemImage: primaryButtonSymbol)
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(canCheckIn ? .green : encounter.poi.category.mapColor)

                Button {
                    onNavigate()
                } label: {
                    Label("Navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    .black.opacity(0.92),
                    encounter.poi.category.mapColor.opacity(0.22),
                    .black.opacity(0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: .rect(cornerRadius: 30)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 22, y: 14)
    }

    private func infoPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private func cardStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white.opacity(0.46))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
    }
}

private struct ExploreWorldSummaryBar: View {
    let title: String
    let subtitle: String
    let featured: [ExploreEncounter]
    let onSelectEncounter: (ExploreEncounter) -> Void
    let onScanNearby: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let first = featured.first {
                Button {
                    onSelectEncounter(first)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: first.kind.systemImageName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(first.poi.category.mapColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(first.poi.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(first.kind.shortLabel)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text("No quests nearby")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Button {
                onScanNearby()
            } label: {
                Image(systemName: "location.magnifyingglass")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
    }
}

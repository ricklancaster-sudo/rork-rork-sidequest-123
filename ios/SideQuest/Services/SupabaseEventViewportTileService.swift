import Foundation

actor SupabaseEventViewportTileService {
    static let shared = SupabaseEventViewportTileService(configuration: .fromEnvironment())

    private let configuration: SupabaseEventFeedCacheConfiguration
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ExternalEventSupport.iso8601Formatter.date(from: value)
                ?? ExternalEventSupport.iso8601NoFractionalSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(value)"
            )
        }
        return decoder
    }()
    private let viewportTileTable: String = "external_event_viewport_tiles"

    init(
        configuration: SupabaseEventFeedCacheConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config)
        }
    }

    nonisolated var isConfigured: Bool {
        configuration.isConfigured
    }

    func loadBundle(
        intent: ExternalDiscoveryIntent,
        range: ExternalEventViewportTileRange,
        countryCode: String = "US",
        state: String? = nil
    ) async -> ExternalEventViewportTileBundle? {
        guard configuration.isConfigured else {
            return nil
        }
        guard range.tileCount > 0, range.tileCount <= 196 else {
            return nil
        }
        guard let request = makeLoadRequest(
            intent: intent,
            range: range,
            countryCode: countryCode,
            state: state
        ) else {
            return nil
        }
        guard let rows = await fetchRows(for: request) else {
            return nil
        }

        let tiles = decodeTiles(from: rows).sorted { lhs, rhs in
            if lhs.tile.y == rhs.tile.y {
                return lhs.tile.x < rhs.tile.x
            }
            return lhs.tile.y < rhs.tile.y
        }

        return ExternalEventViewportTileBundle(
            intent: intent,
            range: range,
            tiles: tiles
        )
    }

    nonisolated func tileRange(
        for bounds: ExternalEventViewportBounds,
        zoom: Int
    ) -> ExternalEventViewportTileRange {
        Self.tileRange(for: bounds, zoom: zoom)
    }

    nonisolated func recommendedZoom(
        for bounds: ExternalEventViewportBounds
    ) -> Int {
        Self.recommendedZoom(for: bounds)
    }

    nonisolated func tileBounds(
        for key: ExternalEventViewportTileKey
    ) -> ExternalEventViewportBounds {
        Self.tileBounds(for: key)
    }

    private func makeLoadRequest(
        intent: ExternalDiscoveryIntent,
        range: ExternalEventViewportTileRange,
        countryCode: String,
        state: String?
    ) -> URLRequest? {
        guard let projectURL = configuration.projectURL else { return nil }

        var components = URLComponents(
            url: projectURL.appendingPathComponent("rest/v1/\(viewportTileTable)"),
            resolvingAgainstBaseURL: false
        )

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "snapshot,intent,country_code,state,z,x,y,quality,event_count,exclusive_count,nightlife_count,fetched_at,expires_at"),
            URLQueryItem(name: "intent", value: "eq.\(intent.rawValue)"),
            URLQueryItem(name: "country_code", value: "eq.\(countryCode.uppercased())"),
            URLQueryItem(name: "z", value: "eq.\(range.z)"),
            URLQueryItem(name: "x", value: "gte.\(range.minX)"),
            URLQueryItem(name: "x", value: "lte.\(range.maxX)"),
            URLQueryItem(name: "y", value: "gte.\(range.minY)"),
            URLQueryItem(name: "y", value: "lte.\(range.maxY)"),
            URLQueryItem(name: "expires_at", value: "gte.\(Self.postgrestTimestamp(from: Date().addingTimeInterval(-Self.staleDisplayWindow)))"),
            URLQueryItem(name: "order", value: "y.asc,x.asc,event_count.desc,fetched_at.desc"),
            URLQueryItem(name: "limit", value: "\(min(max(range.tileCount * 4, range.tileCount), 800))")
        ]

        if let state {
            let trimmedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedState.isEmpty {
                queryItems.append(URLQueryItem(name: "state", value: "eq.\(trimmedState)"))
            }
        }

        components?.queryItems = queryItems

        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        request.setValue(configuration.schema, forHTTPHeaderField: "Accept-Profile")
        return request
    }

    private func applyHeaders(to request: inout URLRequest) {
        guard let anonKey = configuration.anonKey else { return }
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
    }

    private func fetchRows(for request: URLRequest) async -> [[String: Any]]? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  200 ..< 300 ~= httpResponse.statusCode
            else {
                return nil
            }

            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            return nil
        }
    }

    private func decodeTiles(from rows: [[String: Any]]) -> [ExternalEventViewportTileSnapshot] {
        var bestSnapshotsByTile: [String: ExternalEventViewportTileSnapshot] = [:]

        for row in rows {
            let decodedSnapshot: ExternalEventViewportTileSnapshot?
            if let snapshotObject = row["snapshot"],
               let snapshotData = try? JSONSerialization.data(withJSONObject: snapshotObject, options: []),
               let snapshot = try? decoder.decode(ExternalEventViewportTileSnapshot.self, from: snapshotData) {
                decodedSnapshot = snapshot
            } else {
                decodedSnapshot = fallbackTile(from: row)
            }

            guard let snapshot = decodedSnapshot else { continue }
            let physicalTileKey = Self.physicalTileKey(for: snapshot.tile)
            guard let existing = bestSnapshotsByTile[physicalTileKey] else {
                bestSnapshotsByTile[physicalTileKey] = snapshot
                continue
            }

            if Self.shouldPrefer(snapshot, over: existing) {
                bestSnapshotsByTile[physicalTileKey] = snapshot
            }
        }

        return Array(bestSnapshotsByTile.values)
    }

    private func fallbackTile(from row: [String: Any]) -> ExternalEventViewportTileSnapshot? {
        guard let intentValue = row["intent"] as? String,
              let intent = ExternalDiscoveryIntent(rawValue: intentValue),
              let countryCode = row["country_code"] as? String,
              let z = Self.intValue(from: row["z"]),
              let x = Self.intValue(from: row["x"]),
              let y = Self.intValue(from: row["y"]),
              let fetchedAt = Self.dateValue(from: row["fetched_at"])
        else {
            return nil
        }

        let key = ExternalEventViewportTileKey(
            intent: intent,
            countryCode: countryCode,
            state: row["state"] as? String,
            z: z,
            x: x,
            y: y
        )

        return ExternalEventViewportTileSnapshot(
            tile: key,
            bounds: Self.tileBounds(for: key),
            searchLocations: [],
            mergedEvents: [],
            notes: [],
            quality: (row["quality"] as? String).flatMap(ExternalDiscoveryCacheQuality.init(rawValue:)) ?? .fast,
            fetchedAt: fetchedAt,
            expiresAt: Self.dateValue(from: row["expires_at"]),
            eventCount: Self.intValue(from: row["event_count"]) ?? 0,
            exclusiveCount: Self.intValue(from: row["exclusive_count"]) ?? 0,
            nightlifeCount: Self.intValue(from: row["nightlife_count"]) ?? 0
        )
    }

    nonisolated static func tileRange(
        for bounds: ExternalEventViewportBounds,
        zoom: Int
    ) -> ExternalEventViewportTileRange {
        let normalizedZoom = min(max(zoom, 0), 22)
        let westX = longitudeToTileX(bounds.westLongitude, zoom: normalizedZoom)
        let eastX = longitudeToTileX(bounds.eastLongitude, zoom: normalizedZoom)
        let northY = latitudeToTileY(bounds.northLatitude, zoom: normalizedZoom)
        let southY = latitudeToTileY(bounds.southLatitude, zoom: normalizedZoom)

        return ExternalEventViewportTileRange(
            z: normalizedZoom,
            minX: min(westX, eastX),
            maxX: max(westX, eastX),
            minY: min(northY, southY),
            maxY: max(northY, southY)
        )
    }

    nonisolated static func recommendedZoom(
        for bounds: ExternalEventViewportBounds
    ) -> Int {
        let span = max(bounds.latitudeSpan, bounds.longitudeSpan)

        switch span {
        case ..<0.02:
            return 14
        case ..<0.05:
            return 13
        case ..<0.12:
            return 12
        case ..<0.3:
            return 11
        case ..<0.75:
            return 10
        case ..<1.5:
            return 9
        case ..<3.0:
            return 8
        case ..<7.0:
            return 7
        case ..<14.0:
            return 6
        case ..<28.0:
            return 5
        default:
            return 4
        }
    }

    nonisolated static func tileBounds(
        for key: ExternalEventViewportTileKey
    ) -> ExternalEventViewportBounds {
        let scale = pow(2.0, Double(key.z))
        let westLongitude = (Double(key.x) / scale) * 360.0 - 180.0
        let eastLongitude = (Double(key.x + 1) / scale) * 360.0 - 180.0
        let northLatitude = tileYToLatitude(key.y, zoom: key.z)
        let southLatitude = tileYToLatitude(key.y + 1, zoom: key.z)

        return ExternalEventViewportBounds(
            northLatitude: northLatitude,
            southLatitude: southLatitude,
            eastLongitude: eastLongitude,
            westLongitude: westLongitude
        )
    }

    nonisolated private static func longitudeToTileX(_ longitude: Double, zoom: Int) -> Int {
        let normalized = min(max((longitude + 180.0) / 360.0, 0.0), 0.999_999_999)
        let scale = pow(2.0, Double(zoom))
        return Int(floor(normalized * scale))
    }

    nonisolated private static func latitudeToTileY(_ latitude: Double, zoom: Int) -> Int {
        let clampedLatitude = min(max(latitude, -85.051_128_78), 85.051_128_78)
        let radians = clampedLatitude * .pi / 180.0
        let mercator = log(tan(.pi / 4.0 + radians / 2.0))
        let normalized = min(max((1.0 - mercator / .pi) / 2.0, 0.0), 0.999_999_999)
        let scale = pow(2.0, Double(zoom))
        return Int(floor(normalized * scale))
    }

    nonisolated private static func tileYToLatitude(_ y: Int, zoom: Int) -> Double {
        let scale = pow(2.0, Double(zoom))
        let mercator = .pi - (2.0 * .pi * Double(y) / scale)
        return atan(sinh(mercator)) * 180.0 / .pi
    }

    nonisolated private static func intValue(from rawValue: Any?) -> Int? {
        if let value = rawValue as? Int {
            return value
        }
        if let value = rawValue as? NSNumber {
            return value.intValue
        }
        if let value = rawValue as? String {
            return Int(value)
        }
        return nil
    }

    nonisolated private static func dateValue(from rawValue: Any?) -> Date? {
        guard let string = rawValue as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    nonisolated private static func physicalTileKey(for tile: ExternalEventViewportTileKey) -> String {
        [
            tile.intent.rawValue,
            tile.countryCode.uppercased(),
            String(tile.z),
            String(tile.x),
            String(tile.y)
        ].joined(separator: "::")
    }

    nonisolated private static func shouldPrefer(
        _ candidate: ExternalEventViewportTileSnapshot,
        over existing: ExternalEventViewportTileSnapshot
    ) -> Bool {
        if candidate.mergedEvents.count != existing.mergedEvents.count {
            return candidate.mergedEvents.count > existing.mergedEvents.count
        }
        if candidate.eventCount != existing.eventCount {
            return candidate.eventCount > existing.eventCount
        }
        if candidate.fetchedAt != existing.fetchedAt {
            return candidate.fetchedAt > existing.fetchedAt
        }
        switch (candidate.expiresAt, existing.expiresAt) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs > rhs
        case (_?, nil):
            return true
        default:
            break
        }
        return (candidate.tile.state ?? "") < (existing.tile.state ?? "")
    }

    static let staleDisplayWindow: TimeInterval = 72 * 60 * 60

    nonisolated static func isTileStale(_ tile: ExternalEventViewportTileSnapshot) -> Bool {
        guard let expiresAt = tile.expiresAt else { return true }
        return expiresAt < Date()
    }

    nonisolated private static func postgrestTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

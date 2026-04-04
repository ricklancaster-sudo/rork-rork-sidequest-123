import Foundation
import CoreLocation
import MapKit

actor SupabasePOIViewportTileService {
    static let shared = SupabasePOIViewportTileService(configuration: .fromEnvironment())

    private let configuration: SupabaseEventFeedCacheConfiguration
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let poiTileTable: String = "poi_viewport_tiles"

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

    func loadTiles(
        range: ExternalEventViewportTileRange,
        countryCode: String = "US"
    ) async -> POIViewportTileBundle? {
        guard configuration.isConfigured else { return nil }
        guard range.tileCount > 0, range.tileCount <= 256 else { return nil }
        guard let request = makeLoadRequest(range: range, countryCode: countryCode) else { return nil }
        guard let rows = await fetchRows(for: request) else { return nil }

        let tiles = decodeTiles(from: rows)
        return POIViewportTileBundle(range: range, tiles: tiles)
    }

    func seedTile(
        key: POIViewportTileKey,
        pois: [POIViewportTilePOI]
    ) async {
        guard configuration.isConfigured else { return }
        guard let request = makeUpsertRequest(key: key, pois: pois) else { return }
        _ = try? await session.data(for: request)
    }

    private func makeLoadRequest(
        range: ExternalEventViewportTileRange,
        countryCode: String
    ) -> URLRequest? {
        guard let projectURL = configuration.projectURL else { return nil }

        var components = URLComponents(
            url: projectURL.appendingPathComponent("rest/v1/\(poiTileTable)"),
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(name: "select", value: "snapshot,country_code,z,x,y,poi_count,fetched_at,expires_at"),
            URLQueryItem(name: "country_code", value: "eq.\(countryCode.uppercased())"),
            URLQueryItem(name: "z", value: "eq.\(range.z)"),
            URLQueryItem(name: "x", value: "gte.\(range.minX)"),
            URLQueryItem(name: "x", value: "lte.\(range.maxX)"),
            URLQueryItem(name: "y", value: "gte.\(range.minY)"),
            URLQueryItem(name: "y", value: "lte.\(range.maxY)"),
            URLQueryItem(name: "expires_at", value: "gte.\(Self.postgrestTimestamp(from: Date()))"),
            URLQueryItem(name: "order", value: "y.asc,x.asc"),
            URLQueryItem(name: "limit", value: "\(range.tileCount)")
        ]

        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        request.setValue(configuration.schema, forHTTPHeaderField: "Accept-Profile")
        return request
    }

    private func makeUpsertRequest(
        key: POIViewportTileKey,
        pois: [POIViewportTilePOI]
    ) -> URLRequest? {
        guard let projectURL = configuration.projectURL else { return nil }

        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60)

        let snapshot = POIViewportTileSnapshot(
            tile: key,
            pois: pois,
            poiCount: pois.count,
            fetchedAt: now,
            expiresAt: expiresAt
        )

        let snapshotJSON: Any
        if let snapshotData = try? encoder.encode(snapshot),
           let snapshotObj = try? JSONSerialization.jsonObject(with: snapshotData) {
            snapshotJSON = snapshotObj
        } else {
            return nil
        }

        let body: [String: Any] = [
            "country_code": key.countryCode.uppercased(),
            "z": key.z,
            "x": key.x,
            "y": key.y,
            "snapshot": snapshotJSON,
            "poi_count": pois.count,
            "fetched_at": Self.postgrestTimestamp(from: now),
            "expires_at": Self.postgrestTimestamp(from: expiresAt)
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var components = URLComponents(
            url: projectURL.appendingPathComponent("rest/v1/\(poiTileTable)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "on_conflict", value: "country_code,z,x,y")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        applyHeaders(to: &request)
        request.setValue(configuration.schema, forHTTPHeaderField: "Content-Profile")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
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
            else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            return nil
        }
    }

    private func decodeTiles(from rows: [[String: Any]]) -> [POIViewportTileSnapshot] {
        rows.compactMap { row in
            if let snapshotObject = row["snapshot"],
               let snapshotData = try? JSONSerialization.data(withJSONObject: snapshotObject),
               let snapshot = try? decoder.decode(POIViewportTileSnapshot.self, from: snapshotData) {
                return snapshot
            }
            return nil
        }
    }

    nonisolated static func tileRange(
        for bounds: ExternalEventViewportBounds,
        zoom: Int
    ) -> ExternalEventViewportTileRange {
        SupabaseEventViewportTileService.tileRange(for: bounds, zoom: zoom)
    }

    nonisolated static func recommendedZoom(
        for bounds: ExternalEventViewportBounds
    ) -> Int {
        let span = max(bounds.latitudeSpan, bounds.longitudeSpan)
        switch span {
        case ..<0.02: return 14
        case ..<0.05: return 13
        case ..<0.12: return 12
        case ..<0.3: return 11
        case ..<0.75: return 10
        case ..<1.5: return 9
        case ..<3.0: return 8
        case ..<7.0: return 7
        case ..<14.0: return 6
        default: return 5
        }
    }

    nonisolated static func tileBounds(
        for key: POIViewportTileKey
    ) -> ExternalEventViewportBounds {
        let eventKey = ExternalEventViewportTileKey(
            intent: .nearbyWorthIt,
            countryCode: key.countryCode,
            state: nil,
            z: key.z,
            x: key.x,
            y: key.y
        )
        return SupabaseEventViewportTileService.tileBounds(for: eventKey)
    }

    nonisolated static func tileKey(
        for coordinate: CLLocationCoordinate2D,
        zoom: Int,
        countryCode: String = "US"
    ) -> POIViewportTileKey {
        let scale = pow(2.0, Double(zoom))
        let normalizedLon = min(max((coordinate.longitude + 180.0) / 360.0, 0.0), 0.999_999_999)
        let x = Int(floor(normalizedLon * scale))

        let clampedLat = min(max(coordinate.latitude, -85.051_128_78), 85.051_128_78)
        let radians = clampedLat * .pi / 180.0
        let mercator = log(tan(.pi / 4.0 + radians / 2.0))
        let normalizedLat = min(max((1.0 - mercator / .pi) / 2.0, 0.0), 0.999_999_999)
        let y = Int(floor(normalizedLat * scale))

        return POIViewportTileKey(countryCode: countryCode.uppercased(), z: zoom, x: x, y: y)
    }

    nonisolated private static func postgrestTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

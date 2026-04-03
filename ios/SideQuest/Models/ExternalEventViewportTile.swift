import Foundation

nonisolated struct ExternalEventViewportBounds: Codable, Hashable, Sendable {
    let northLatitude: Double
    let southLatitude: Double
    let eastLongitude: Double
    let westLongitude: Double

    init(
        northLatitude: Double,
        southLatitude: Double,
        eastLongitude: Double,
        westLongitude: Double
    ) {
        self.northLatitude = max(northLatitude, southLatitude)
        self.southLatitude = min(northLatitude, southLatitude)
        self.eastLongitude = eastLongitude
        self.westLongitude = westLongitude
    }

    var latitudeSpan: Double {
        northLatitude - southLatitude
    }

    var longitudeSpan: Double {
        let rawDelta = eastLongitude - westLongitude
        return rawDelta >= 0 ? rawDelta : rawDelta + 360
    }
}

nonisolated struct ExternalEventViewportTileRange: Codable, Hashable, Sendable {
    let z: Int
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int

    var tileCount: Int {
        guard maxX >= minX, maxY >= minY else { return 0 }
        return (maxX - minX + 1) * (maxY - minY + 1)
    }
}

nonisolated struct ExternalEventViewportTileKey: Codable, Hashable, Sendable, Identifiable {
    let intent: ExternalDiscoveryIntent
    let countryCode: String
    let state: String?
    let z: Int
    let x: Int
    let y: Int

    var id: String {
        [
            intent.rawValue,
            countryCode.uppercased(),
            normalizedState,
            String(z),
            String(x),
            String(y)
        ].joined(separator: "::")
    }

    var normalizedState: String {
        state?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
    }
}

nonisolated struct ExternalEventViewportTileSnapshot: Codable, Hashable, Sendable, Identifiable {
    let tile: ExternalEventViewportTileKey
    let bounds: ExternalEventViewportBounds
    let searchLocations: [ExternalEventSearchLocation]
    let mergedEvents: [ExternalEvent]
    let notes: [String]
    let quality: ExternalDiscoveryCacheQuality
    let fetchedAt: Date
    let expiresAt: Date?
    let eventCount: Int
    let exclusiveCount: Int
    let nightlifeCount: Int

    var id: String {
        tile.id
    }
}

nonisolated struct ExternalEventViewportTileBundle: Codable, Hashable, Sendable {
    let intent: ExternalDiscoveryIntent
    let range: ExternalEventViewportTileRange
    let tiles: [ExternalEventViewportTileSnapshot]
}

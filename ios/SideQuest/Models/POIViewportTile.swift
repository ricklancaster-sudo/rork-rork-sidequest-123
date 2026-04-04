import Foundation
import CoreLocation

nonisolated struct POIViewportTileKey: Codable, Hashable, Sendable, Identifiable {
    let countryCode: String
    let z: Int
    let x: Int
    let y: Int

    var id: String {
        [
            "poi",
            countryCode.uppercased(),
            String(z),
            String(x),
            String(y)
        ].joined(separator: "::")
    }
}

nonisolated struct POIViewportTilePOI: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let category: String
    let address: String?
    let specificType: String?
    let neighborhood: String?
    let locality: String?
    let websiteURL: String?
    let phoneNumber: String?
    let placeDescription: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated struct POIViewportTileSnapshot: Codable, Hashable, Sendable, Identifiable {
    let tile: POIViewportTileKey
    let pois: [POIViewportTilePOI]
    let poiCount: Int
    let fetchedAt: Date
    let expiresAt: Date?

    var id: String { tile.id }
}

nonisolated struct POIViewportTileBundle: Sendable {
    let range: ExternalEventViewportTileRange
    let tiles: [POIViewportTileSnapshot]
}

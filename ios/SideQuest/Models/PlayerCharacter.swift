import Foundation

nonisolated enum PlayerCharacterType: String, CaseIterable, Codable, Sendable, Identifiable {
    case base = "base"

    var id: String { rawValue }

    var displayName: String {
        "Adventurer"
    }

    var fileName: String {
        "WhiteMale"
    }

    var lore: String {
        "A blank canvas ready for any adventure. Equip gear to forge your identity."
    }

    var iconName: String {
        "person.fill"
    }

    var shopPrice: Int {
        0
    }

    var isStarterSkin: Bool {
        true
    }

    var heroProfileYawDegrees: Int {
        154
    }

    var homeHeroYawDegrees: Int {
        206
    }
}

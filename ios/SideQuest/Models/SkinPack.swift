import SwiftUI

nonisolated struct SkinPackPiece: Identifiable, Sendable, Hashable {
    nonisolated static func == (lhs: SkinPackPiece, rhs: SkinPackPiece) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: String
    let name: String
    let slot: EquipmentSlot
    let equipmentItemId: String
    let price: Int
    let icon: String
    let gradient: LinearGradient
}

nonisolated struct SkinPack: Identifiable, Sendable, Hashable {
    nonisolated static func == (lhs: SkinPack, rhs: SkinPack) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: String
    let name: String
    let description: String
    let pieces: [SkinPackPiece]
    let bundlePrice: Int
    let gradient: LinearGradient
    let icon: String
    let sourceFile: String

    var individualTotal: Int {
        pieces.reduce(0) { $0 + $1.price }
    }

    var savings: Int {
        individualTotal - bundlePrice
    }

    var savingsPercent: Int {
        guard individualTotal > 0 else { return 0 }
        return Int(round(Double(savings) / Double(individualTotal) * 100))
    }

    func allPieceIds() -> [String] {
        pieces.map { $0.id }
    }
}

enum SkinPackCatalog {
    static let cowboyPack = SkinPack(
        id: "cowboy_pack",
        name: "Cowboy",
        description: "A rugged frontier outfit complete with jacket, pants, boots, and hat. Yeehaw.",
        pieces: [
            SkinPackPiece(
                id: "cowboy_top",
                name: "Cowboy Jacket",
                slot: .top,
                equipmentItemId: "cowboy_top",
                price: 400,
                icon: "tshirt.fill",
                gradient: LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 0.2), Color(red: 0.4, green: 0.25, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ),
            SkinPackPiece(
                id: "cowboy_bottom",
                name: "Cowboy Pants",
                slot: .bottom,
                equipmentItemId: "cowboy_bottom",
                price: 300,
                icon: "figure.stand",
                gradient: LinearGradient(colors: [Color(red: 0.45, green: 0.3, blue: 0.18), Color(red: 0.35, green: 0.22, blue: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ),
            SkinPackPiece(
                id: "cowboy_shoes",
                name: "Cowboy Boots",
                slot: .shoes,
                equipmentItemId: "cowboy_shoes",
                price: 250,
                icon: "shoe.fill",
                gradient: LinearGradient(colors: [Color(red: 0.5, green: 0.32, blue: 0.18), Color(red: 0.38, green: 0.2, blue: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ),
            SkinPackPiece(
                id: "cowboy_hat",
                name: "Cowboy Hat",
                slot: .hat,
                equipmentItemId: "cowboy_hat",
                price: 350,
                icon: "crown.fill",
                gradient: LinearGradient(colors: [Color(red: 0.6, green: 0.4, blue: 0.22), Color(red: 0.45, green: 0.28, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        ],
        bundlePrice: 1000,
        gradient: LinearGradient(colors: [Color(red: 0.6, green: 0.4, blue: 0.2), Color(red: 0.35, green: 0.2, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
        icon: "lasso",
        sourceFile: "Cowboy"
    )

    static let allPacks: [SkinPack] = [cowboyPack]

    static func pack(withId id: String) -> SkinPack? {
        allPacks.first { $0.id == id }
    }

    static func piece(withId id: String) -> SkinPackPiece? {
        allPacks.flatMap { $0.pieces }.first { $0.id == id }
    }
}

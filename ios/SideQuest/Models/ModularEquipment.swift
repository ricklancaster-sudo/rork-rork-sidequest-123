import Foundation

nonisolated enum EquipmentSlot: String, CaseIterable, Codable, Sendable, Identifiable {
    case top
    case bottom
    case shoes
    case hat

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .shoes: return "Shoes"
        case .hat: return "Hat"
        }
    }

    var iconName: String {
        switch self {
        case .top: return "tshirt.fill"
        case .bottom: return "figure.stand"
        case .shoes: return "shoe.fill"
        case .hat: return "crown.fill"
        }
    }
}

nonisolated struct EquipmentItem: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let label: String
    let slot: EquipmentSlot
    let sourceFile: String
    let meshNames: [String]
    let hideBaseMeshes: [String]
    let scale: Double
    let parentNodeHints: [String: [String]]
    var sourceNodeHints: [String: [String]]

    static func == (lhs: EquipmentItem, rhs: EquipmentItem) -> Bool {
        lhs.id == rhs.id
    }

    var jsConfigDictionary: [String: Any] {
        [
            "id": id,
            "sourceFile": sourceFile,
            "meshNames": meshNames,
            "hideBaseMeshes": hideBaseMeshes,
            "parentNodeHints": parentNodeHints,
            "sourceNodeHints": sourceNodeHints,
            "scale": scale
        ]
    }
}

nonisolated struct EquipmentCatalog: Sendable {
    let tops: [EquipmentItem]
    let bottoms: [EquipmentItem]
    let shoes: [EquipmentItem]
    let hats: [EquipmentItem]

    func items(for slot: EquipmentSlot) -> [EquipmentItem] {
        switch slot {
        case .top: return tops
        case .bottom: return bottoms
        case .shoes: return shoes
        case .hat: return hats
        }
    }

    static let cowboyCatalog = EquipmentCatalog(
        tops: [
            EquipmentItem(
                id: "cowboy_top",
                label: "Cowboy Top",
                slot: .top,
                sourceFile: "Cowboy",
                meshNames: [
                    "Belly-Mesh", "Chest_A-Mesh",
                    "LeftArm-Mesh", "LeftForearm-Mesh", "LeftHand-Mesh",
                    "RightArm-Mesh", "RightForearm-Mesh", "RightHand-Mesh",
                    "Scarf-Mesh"
                ],
                hideBaseMeshes: [
                    "Belly1-Mesh", "Chest_A1-Mesh",
                    "LeftArm1-Mesh", "LeftForearm1-Mesh", "LeftHand1-Mesh",
                    "RightArm1-Mesh", "RightForearm1-Mesh", "RightHand1-Mesh"
                ],
                scale: 1.0,
                parentNodeHints: [
                    "Belly-Mesh": ["Rest_Jacket-Global", "Belly-Global", "Belly-Local"],
                    "Chest_A-Mesh": ["Chest_Jacket-Global", "Chest-Global", "Chest-Local"],
                    "LeftArm-Mesh": ["L_Arm-Global", "Left_Arm-Global", "Left_Arm-Local"],
                    "LeftForearm-Mesh": ["L_Forearm-Global", "Left_Forearm-Global", "Left_Forearm-Local"],
                    "LeftHand-Mesh": ["L_Hand-Global", "Left_Hand-Global", "Left_Hand-Local"],
                    "RightArm-Mesh": ["R_Arm-Global", "Right_Arm-Global", "Right_Arm-Local"],
                    "RightForearm-Mesh": ["R_Forearm-Global", "Right_Forearm-Global", "Right_Forearm-Local"],
                    "RightHand-Mesh": ["R_Hand-Global", "Right_Hand-Global", "Right_Hand-Local"],
                    "Scarf-Mesh": ["Scarf-Global", "Chest-Global", "Chest-Local"]
                ],
                sourceNodeHints: [
                    "Belly-Mesh": ["Rest_Jacket-Local", "Belly-Mesh"],
                    "Chest_A-Mesh": ["Chest_Jacket-Local", "Chest_A-Mesh"],
                    "LeftArm-Mesh": ["L_Arm-Local", "LeftArm-Mesh"],
                    "LeftForearm-Mesh": ["L_Forearm-Local", "LeftForearm-Mesh"],
                    "LeftHand-Mesh": ["L_Hand-Local", "LeftHand-Mesh"],
                    "RightArm-Mesh": ["R_Arm-Local", "RightArm-Mesh"],
                    "RightForearm-Mesh": ["R_Forearm-Local", "RightForearm-Mesh"],
                    "RightHand-Mesh": ["R_Hand-Local", "RightHand-Mesh"],
                    "Scarf-Mesh": ["Scarf-Local", "Scarf-Mesh"]
                ]
            )
        ],
        bottoms: [
            EquipmentItem(
                id: "cowboy_bottom",
                label: "Cowboy Bottom",
                slot: .bottom,
                sourceFile: "Cowboy",
                meshNames: [
                    "Hip-Mesh",
                    "LeftThigh-Mesh", "LeftLeg-Mesh",
                    "RightThigh-Mesh", "RightLeg-Mesh"
                ],
                hideBaseMeshes: [
                    "Hip1-Mesh",
                    "LeftThigh1-Mesh", "LeftLeg1-Mesh",
                    "RightThigh1-Mesh", "RightLeg1-Mesh"
                ],
                scale: 1.0,
                parentNodeHints: [
                    "Hip-Mesh": ["Pants-Global", "Hip-Global", "Hip-Local"],
                    "LeftThigh-Mesh": ["L_Thigh-Global", "Left_Thigh-Global", "Left_Thigh-Local"],
                    "LeftLeg-Mesh": ["L_Leg-Global", "Left_Leg-Global", "Left_Leg-Local"],
                    "RightThigh-Mesh": ["R_Thigh-Global", "Right_Thigh-Global", "Right_Thigh-Local"],
                    "RightLeg-Mesh": ["R_Leg-Global", "Right_Leg-Global", "Right_Leg-Local"]
                ],
                sourceNodeHints: [
                    "Hip-Mesh": ["Pants-Local", "Hip-Mesh"],
                    "LeftThigh-Mesh": ["L_Thigh-Local", "LeftThigh-Mesh"],
                    "LeftLeg-Mesh": ["L_Leg-Local", "LeftLeg-Mesh"],
                    "RightThigh-Mesh": ["R_Thigh-Local", "RightThigh-Mesh"],
                    "RightLeg-Mesh": ["R_Leg-Local", "RightLeg-Mesh"]
                ]
            )
        ],
        shoes: [
            EquipmentItem(
                id: "cowboy_shoes",
                label: "Cowboy Shoes",
                slot: .shoes,
                sourceFile: "Cowboy",
                meshNames: [
                    "LeftFoot-Mesh", "RightFoot-Mesh"
                ],
                hideBaseMeshes: [
                    "LeftFoot1-Mesh", "RightFoot1-Mesh"
                ],
                scale: 1.0,
                parentNodeHints: [
                    "LeftFoot-Mesh": ["L_Foot-Global", "Left_Foot-Global", "Left_Foot-Local"],
                    "RightFoot-Mesh": ["R_Foot-Global", "Right_Foot-Global", "Right_Foot-Local"]
                ],
                sourceNodeHints: [
                    "LeftFoot-Mesh": ["L_Foot-Local", "LeftFoot-Mesh"],
                    "RightFoot-Mesh": ["R_Foot-Local", "RightFoot-Mesh"]
                ]
            )
        ],
        hats: [
            EquipmentItem(
                id: "cowboy_hat",
                label: "Cowboy Hat",
                slot: .hat,
                sourceFile: "Cowboy",
                meshNames: [
                    "Hat_A-Mesh"
                ],
                hideBaseMeshes: [],
                scale: 1.0,
                parentNodeHints: [
                    "Hat_A-Mesh": ["Hat-Global", "Head-Global", "Head-Local"]
                ],
                sourceNodeHints: [
                    "Hat_A-Mesh": ["Hat-Local", "Hat_A-Mesh"]
                ]
            )
        ]
    )
}

struct CharacterEquipmentState: Codable, Sendable, Equatable {
    var equippedTop: String?
    var equippedBottom: String?
    var equippedShoes: String?
    var equippedHat: String?

    func equipped(for slot: EquipmentSlot) -> String? {
        switch slot {
        case .top: return equippedTop
        case .bottom: return equippedBottom
        case .shoes: return equippedShoes
        case .hat: return equippedHat
        }
    }

    mutating func setEquipped(_ itemId: String?, for slot: EquipmentSlot) {
        switch slot {
        case .top: equippedTop = itemId
        case .bottom: equippedBottom = itemId
        case .shoes: equippedShoes = itemId
        case .hat: equippedHat = itemId
        }
    }

    func resolvedItem(for slot: EquipmentSlot) -> EquipmentItem? {
        guard let itemId = equipped(for: slot) else { return nil }
        return EquipmentCatalog.cowboyCatalog.items(for: slot).first { $0.id == itemId }
    }

    var requiredSourceFiles: Set<String> {
        var files = Set<String>()
        for slot in EquipmentSlot.allCases {
            if let item = resolvedItem(for: slot) {
                files.insert(item.sourceFile)
            }
        }
        return files
    }

    func jsConfigJSON() -> String {
        var dict: [String: Any] = [:]
        for slot in EquipmentSlot.allCases {
            if let item = resolvedItem(for: slot) {
                dict[slot.rawValue] = item.jsConfigDictionary
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    func jsSlotConfigJSON(for slot: EquipmentSlot) -> String? {
        guard let item = resolvedItem(for: slot) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: item.jsConfigDictionary),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    var sourceFilesKey: String {
        requiredSourceFiles.sorted().joined(separator: ",")
    }

    static let fullCowboy = CharacterEquipmentState(
        equippedTop: "cowboy_top",
        equippedBottom: "cowboy_bottom",
        equippedShoes: "cowboy_shoes",
        equippedHat: "cowboy_hat"
    )

    static let naked = CharacterEquipmentState()
}

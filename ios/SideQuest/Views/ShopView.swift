import SwiftUI

struct ShopView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: ShopCategory = .skinPacks
    @State private var purchaseTarget: ShopItem?
    @State private var showPurchaseResult: Bool = false
    @State private var purchaseSuccess: Bool = false
    @State private var selectedPack: SkinPack?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    goldBar
                    categoryPicker

                    switch selectedCategory {
                    case .skinPacks:
                        skinPacksSection
                    default:
                        shopGrid
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Shop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(purchaseSuccess ? "Purchased!" : "Not Enough Gold", isPresented: $showPurchaseResult) {
                Button("OK") {}
            } message: {
                Text(purchaseSuccess ? "Item added to your collection." : "Earn more gold by completing quests.")
            }
            .sheet(item: $selectedPack) { pack in
                SkinPackDetailView(appState: appState, pack: pack)
            }
        }
    }

    private var goldBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title3)
                Text("\(appState.profile.gold)")
                    .font(.headline.monospacedDigit())
                Text("Gold")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill")
                    .foregroundStyle(.cyan)
                    .font(.title3)
                Text("\(appState.profile.diamonds)")
                    .font(.headline.monospacedDigit())
                Text("Diamonds")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ShopCategory.allCases) { category in
                    Button {
                        withAnimation(.snappy) {
                            selectedCategory = category
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: category.icon)
                            Text(category.rawValue)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selectedCategory == category ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background {
                            if selectedCategory == category {
                                Capsule().fill(.blue)
                            } else {
                                Capsule().fill(Color(.tertiarySystemGroupedBackground))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contentMargins(.horizontal, 0)
        .scrollIndicators(.hidden)
    }

    // MARK: - Skin Packs

    private var skinPacksSection: some View {
        VStack(spacing: 16) {
            ForEach(SkinPackCatalog.allPacks) { pack in
                skinPackCard(pack)
            }
        }
    }

    private func skinPackCard(_ pack: SkinPack) -> some View {
        let ownedCount = appState.ownedPieceCount(for: pack)
        let totalCount = pack.pieces.count
        let isFullyOwned = ownedCount == totalCount

        return Button {
            selectedPack = pack
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(pack.gradient)
                        .frame(height: 180)
                        .overlay {
                            Character3DView(
                                characterType: appState.profile.selectedCharacter,
                                allowsControl: false,
                                autoRotate: true,
                                framing: .fullBody,
                                modelYawDegrees: 180,
                                equipment: .fullCowboy
                            )
                            .allowsHitTesting(false)
                        }
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 6) {
                                Image(systemName: pack.icon)
                                    .font(.caption.weight(.bold))
                                Text(pack.name)
                                    .font(.subheadline.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.4), in: Capsule())
                            .padding(12)
                        }
                        .overlay(alignment: .topTrailing) {
                            if isFullyOwned {
                                Text("OWNED")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.green.gradient, in: Capsule())
                                    .padding(12)
                            } else if pack.savingsPercent > 0 {
                                Text("SAVE \(pack.savingsPercent)%")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.orange.gradient, in: Capsule())
                                    .padding(12)
                            }
                        }

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 60)
                }

                VStack(spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(pack.name) Pack")
                                .font(.headline)
                            Text("\(totalCount) pieces · \(ownedCount)/\(totalCount) owned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        if isFullyOwned {
                            Button {
                                appState.equipFullSkinPack(pack)
                            } label: {
                                Text("Equip All")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.blue.gradient, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            let cost = appState.bundleCostForUnowned(pack)
                            HStack(spacing: 4) {
                                Image(systemName: "dollarsign.circle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                                Text("\(cost)")
                                    .font(.subheadline.weight(.bold))
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(pack.pieces) { piece in
                            let owned = appState.isSkinPackPieceOwned(piece.id)
                            let equipped = appState.characterEquipment.equipped(for: piece.slot) == piece.equipmentItemId
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(piece.gradient)
                                        .frame(height: 44)
                                    Image(systemName: piece.icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                    if owned && equipped {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(.yellow, lineWidth: 2)
                                            .frame(height: 44)
                                    } else if owned {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white)
                                            .background(.green, in: Circle())
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                            .padding(3)
                                    }
                                }
                                Text(piece.slot.displayName)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(14)
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Generic Shop Grid (Backgrounds, Effects, Remove Ads)

    private var shopGrid: some View {
        let columns: [GridItem] = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(shopItems, id: \.name) { item in
                let owned: Bool = isOwned(item)
                let equipped: Bool = isEquipped(item)

                Button {
                    handleTap(on: item, owned: owned)
                } label: {
                    VStack(spacing: 8) {
                        previewCard(for: item, equipped: equipped, owned: owned)

                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity)

                        itemStatus(for: item, owned: owned, equipped: equipped)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog(
            "Purchase \(purchaseTarget?.name ?? "")?",
            isPresented: Binding(
                get: { purchaseTarget != nil },
                set: { if !$0 { purchaseTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = purchaseTarget {
                Button("Buy for \(item.price) Gold") {
                    purchaseSuccess = appState.purchaseItem(name: item.name, price: item.price)
                    showPurchaseResult = true
                    purchaseTarget = nil
                }
                Button("Cancel", role: .cancel) {
                    purchaseTarget = nil
                }
            }
        } message: {
            if let item = purchaseTarget {
                Text("You have \(appState.profile.gold) gold. This costs \(item.price) gold.")
            }
        }
    }

    private func previewCard(for item: ShopItem, equipped: Bool, owned: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(item.gradient)
            .frame(height: 120)
            .overlay {
                switch selectedCategory {
                case .skinPacks:
                    EmptyView()
                case .callingCards:
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text("Profile Background")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                case .effects:
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.18))
                            .frame(width: 78, height: 78)
                        CharacterEffectView(effectName: item.name, diameter: 82)
                    }
                case .removeAds:
                    Image(systemName: item.icon)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .overlay(alignment: .topTrailing) {
                if equipped {
                    Image(systemName: "star.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(6)
                } else if owned {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .background(.green, in: Circle())
                        .padding(6)
                }
            }
            .clipShape(.rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func itemStatus(for item: ShopItem, owned: Bool, equipped: Bool) -> some View {
        if equipped {
            Text("Tap to Unequip")
                .font(.caption.weight(.bold))
                .foregroundStyle(.yellow)
        } else if owned {
            Text("Tap to Equip")
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(.yellow)
                Text("\(item.price)")
                    .font(.caption.weight(.bold))
            }
        }
    }

    private var shopItems: [ShopItem] {
        switch selectedCategory {
        case .skinPacks:
            return []
        case .callingCards:
            return [
                ShopItem(name: "Sunset Blaze", icon: "sun.max.fill", price: 200, gradient: .linearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)),
                ShopItem(name: "Arctic Frost", icon: "snowflake", price: 220, gradient: .linearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)),
                ShopItem(name: "Royal Night", icon: "moon.stars.fill", price: 250, gradient: .linearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)),
                ShopItem(name: "Emerald Dream", icon: "leaf.fill", price: 220, gradient: .linearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing))
            ]
        case .effects:
            return [
                ShopItem(name: "Fire Aura", icon: "flame.fill", price: 800, gradient: .linearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)),
                ShopItem(name: "Lightning", icon: "bolt.fill", price: 700, gradient: .linearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)),
                ShopItem(name: "Frost Ring", icon: "snowflake", price: 750, gradient: .linearGradient(colors: [.cyan, .white], startPoint: .topLeading, endPoint: .bottomTrailing))
            ]
        case .removeAds:
            return [
                ShopItem(name: "Remove Ads", icon: "xmark.circle.fill", price: 0, gradient: .linearGradient(colors: [.gray, .secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
            ]
        }
    }

    private func isOwned(_ item: ShopItem) -> Bool {
        appState.profile.ownedItems.contains(item.name)
    }

    private func isEquipped(_ item: ShopItem) -> Bool {
        switch selectedCategory {
        case .skinPacks:
            return false
        case .callingCards:
            return appState.profile.equippedCallingCard == item.name
        case .effects:
            return appState.profile.equippedEffect == item.name
        case .removeAds:
            return false
        }
    }

    private func handleTap(on item: ShopItem, owned: Bool) {
        guard selectedCategory != .removeAds else { return }
        guard selectedCategory != .skinPacks else { return }

        if owned {
            appState.equipItem(name: item.name, category: selectedCategory)
        } else {
            purchaseTarget = item
        }
    }
}

struct ShopItem {
    let name: String
    let icon: String
    let price: Int
    let gradient: LinearGradient
}

nonisolated enum ShopCategory: String, CaseIterable, Identifiable {
    case skinPacks = "Skin Packs"
    case callingCards = "Backgrounds"
    case effects = "Effects"
    case removeAds = "Remove Ads"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .skinPacks: "person.2.fill"
        case .callingCards: "photo.stack.fill"
        case .effects: "sparkles"
        case .removeAds: "xmark.circle"
        }
    }
}

import SwiftUI

struct SkinPackDetailView: View {
    let appState: AppState
    let pack: SkinPack
    @Environment(\.dismiss) private var dismiss
    @State private var purchasePiece: SkinPackPiece?
    @State private var showBundlePurchase: Bool = false
    @State private var showPurchaseResult: Bool = false
    @State private var purchaseSuccess: Bool = false
    @State private var purchaseMessage: String = ""

    private var isFullyOwned: Bool {
        appState.isFullPackOwned(pack)
    }

    private var ownedCount: Int {
        appState.ownedPieceCount(for: pack)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroSection
                    bundleSection
                    piecesSection
                }
                .padding(16)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(pack.name) Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(purchaseSuccess ? "Purchased!" : "Not Enough Gold", isPresented: $showPurchaseResult) {
                Button("OK") {}
            } message: {
                Text(purchaseMessage)
            }
            .confirmationDialog(
                "Buy \(purchasePiece?.name ?? "")?",
                isPresented: Binding(
                    get: { purchasePiece != nil },
                    set: { if !$0 { purchasePiece = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let piece = purchasePiece {
                    Button("Buy for \(piece.price) Gold") {
                        purchaseSuccess = appState.purchaseSkinPackPiece(piece)
                        purchaseMessage = purchaseSuccess
                            ? "\(piece.name) is now yours and equipped!"
                            : "You need \(piece.price - appState.profile.gold) more gold."
                        showPurchaseResult = true
                        purchasePiece = nil
                    }
                    Button("Cancel", role: .cancel) { purchasePiece = nil }
                }
            } message: {
                if let piece = purchasePiece {
                    Text("You have \(appState.profile.gold) gold. This costs \(piece.price) gold.")
                }
            }
            .confirmationDialog(
                "Buy Remaining Pack Pieces?",
                isPresented: $showBundlePurchase,
                titleVisibility: .visible
            ) {
                let cost = appState.bundleCostForUnowned(pack)
                let unownedCount = pack.pieces.count - ownedCount
                Button("Buy \(unownedCount) pieces for \(cost) Gold") {
                    purchaseSuccess = appState.purchaseSkinPackBundle(pack)
                    purchaseMessage = purchaseSuccess
                        ? "Full \(pack.name) pack is now yours!"
                        : "You need \(cost - appState.profile.gold) more gold."
                    showPurchaseResult = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let cost = appState.bundleCostForUnowned(pack)
                Text("You have \(appState.profile.gold) gold. Bundle costs \(cost) gold.")
            }
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 20)
                .fill(pack.gradient)
                .frame(height: 280)
                .overlay {
                    Character3DView(
                        characterType: appState.profile.selectedCharacter,
                        allowsControl: true,
                        autoRotate: false,
                        framing: .fullBody,
                        modelYawDegrees: 180,
                        equipment: .fullCowboy
                    )
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: pack.icon)
                                .font(.caption.weight(.bold))
                            Text(pack.name)
                                .font(.headline.weight(.bold))
                        }
                        .foregroundStyle(.white)

                        Text(pack.description)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                    .padding(14)
                    .background(.black.opacity(0.35), in: .rect(cornerRadius: 12))
                    .padding(12)
                }

            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 80)
            .clipShape(.rect(cornerRadius: 20))
        }
        .clipShape(.rect(cornerRadius: 20))
    }

    private var bundleSection: some View {
        VStack(spacing: 12) {
            if isFullyOwned {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Complete Pack Owned")
                            .font(.headline)
                        Text("All \(pack.pieces.count) pieces unlocked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        appState.equipFullSkinPack(pack)
                    } label: {
                        Text("Equip All")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.blue.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            } else {
                VStack(spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Buy Full Pack")
                                .font(.headline)
                            Text("\(ownedCount)/\(pack.pieces.count) pieces owned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 2) {
                                Text("Individual:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                let unownedIndividual = pack.pieces.filter { !appState.isSkinPackPieceOwned($0.id) }.reduce(0) { $0 + $1.price }
                                Text("\(unownedIndividual)")
                                    .font(.caption.weight(.semibold))
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("Bundle:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "dollarsign.circle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                                let bundleCost = appState.bundleCostForUnowned(pack)
                                Text("\(bundleCost)")
                                    .font(.subheadline.weight(.bold))
                            }
                        }

                        Spacer()

                        if pack.savingsPercent > 0 {
                            Text("SAVE \(pack.savingsPercent)%")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.orange.gradient, in: Capsule())
                        }

                        Button {
                            showBundlePurchase = true
                        } label: {
                            Text("Buy Bundle")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.orange.gradient, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            }
        }
    }

    private var piecesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Individual Pieces")
                .font(.headline)

            ForEach(pack.pieces) { piece in
                pieceRow(piece)
            }
        }
    }

    private func pieceRow(_ piece: SkinPackPiece) -> some View {
        let owned = appState.isSkinPackPieceOwned(piece.id)
        let equipped = appState.characterEquipment.equipped(for: piece.slot) == piece.equipmentItemId

        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(piece.gradient)
                    .frame(width: 56, height: 56)
                Image(systemName: piece.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(piece.name)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text(piece.slot.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if equipped {
                        Text("EQUIPPED")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.15), in: Capsule())
                    }
                }
            }

            Spacer()

            if owned {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        appState.equipSkinPackPiece(piece)
                    }
                } label: {
                    Text(equipped ? "Unequip" : "Equip")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(equipped ? .orange : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            equipped
                                ? AnyShapeStyle(Color(.tertiarySystemGroupedBackground))
                                : AnyShapeStyle(.blue.gradient),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    purchasePiece = piece
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "dollarsign.circle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text("\(piece.price)")
                            .font(.subheadline.weight(.bold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}


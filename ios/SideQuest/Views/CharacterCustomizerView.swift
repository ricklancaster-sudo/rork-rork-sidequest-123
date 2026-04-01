import SwiftUI

struct CharacterCustomizerView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    previewCard
                    equipmentSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Customize Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(.secondarySystemGroupedBackground))

            RoundedRectangle(cornerRadius: 28)
                .fill(
                    RadialGradient(
                        colors: [Color.orange.opacity(0.2), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 180
                    )
                )

            Character3DView(
                characterType: .base,
                allowsControl: true,
                autoRotate: false,
                framing: .fullBody,
                modelYawDegrees: 180,
                equipment: appState.characterEquipment
            )
            .padding(12)

            if let equippedEffect = appState.profile.equippedEffect {
                CharacterEffectView(effectName: equippedEffect, diameter: 246)
            }
        }
        .frame(height: 360)
        .clipShape(.rect(cornerRadius: 28))
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your Character")
                    .font(.title2.weight(.bold))

                Text("Drag to inspect · Tap slots to equip gear")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private var equipmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Equipment Slots")
                .font(.headline)
                .padding(.horizontal, 2)

            ForEach(EquipmentSlot.allCases) { slot in
                equipmentSlotRow(slot)
            }
        }
    }

    private func equipmentSlotRow(_ slot: EquipmentSlot) -> some View {
        let isEquipped: Bool = appState.characterEquipment.equipped(for: slot) != nil
        let item = appState.characterEquipment.resolvedItem(for: slot)

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                appState.toggleEquipmentSlot(slot)
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isEquipped ? Color.orange.opacity(0.12) : Color(.tertiarySystemGroupedBackground))
                        .frame(width: 52, height: 52)
                    Image(systemName: slot.iconName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isEquipped ? .orange : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(item?.label ?? "None equipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(isEquipped ? "Unequip" : "Equip")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isEquipped ? .orange : .blue)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        isEquipped
                            ? Color.orange.opacity(0.1)
                            : Color.blue.opacity(0.1),
                        in: Capsule()
                    )
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isEquipped)
    }
}

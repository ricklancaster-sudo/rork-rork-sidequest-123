import SwiftUI

nonisolated struct Character3DDevConfig: Codable, Sendable, Equatable {
    var camY: Double = 0
    var mdlY: Double = 0
    var tgtX: Double = 0
    var tgtY: Double = 0
    var tgtZ: Double = 0
    var fov: Double = 32
    var scale: Double = 1.0
    var frameW: Double = 180
    var frameH: Double = 300
    var clipW: Double = 146
    var clipH: Double = 154

    nonisolated func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    nonisolated static func from(json: String) -> Character3DDevConfig? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Character3DDevConfig.self, from: data)
    }
}

struct Character3DDevOverlay: View {
    @Binding var config: Character3DDevConfig
    @Binding var isVisible: Bool
    @State private var copied: Bool = false

    var body: some View {
        if isVisible {
            ScrollView {
                VStack(spacing: 6) {
                    HStack {
                        Text("3D Dev")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = config.jsonString()
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        } label: {
                            Text(copied ? "Copied!" : "Copy JSON")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(copied ? .green : .orange, in: Capsule())
                        }
                        Button {
                            isVisible = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                    devRow("Cam Y", value: $config.camY, step: 0.5, range: -50...50)

                    devRow("Mdl Y", value: $config.mdlY, step: 0.5, range: -50...50)

                    sectionLabel("Target")
                    devRow("Tgt X", value: $config.tgtX, step: 0.5, range: -50...50)
                    devRow("Tgt Y", value: $config.tgtY, step: 0.5, range: -50...50)
                    devRow("Tgt Z", value: $config.tgtZ, step: 0.5, range: -50...50)

                    devRow("FOV", value: $config.fov, step: 1, range: 10...120)

                    devRow("Scale", value: $config.scale, step: 0.05, range: 0.1...3.0)

                    sectionLabel("Frame")
                    devRow("Frame W", value: $config.frameW, step: 2, range: 50...500)
                    devRow("Frame H", value: $config.frameH, step: 2, range: 50...500)

                    sectionLabel("Clip")
                    devRow("Clip W", value: $config.clipW, step: 2, range: 50...500)
                    devRow("Clip H", value: $config.clipH, step: 2, range: 50...500)
                }
                .padding(.bottom, 10)
            }
            .frame(maxHeight: 340)
            .background(Color.black.opacity(0.9))
            .clipShape(.rect(cornerRadius: 10))
            .padding(.horizontal, 12)
            .onChange(of: config) { _, newVal in
                sendJSCommands(newVal)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 2)
    }

    private func devRow(_ label: String, value: Binding<Double>, step: Double, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 56, alignment: .leading)

            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.15), in: Circle())
            }

            Text(formatValue(value.wrappedValue))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)
                .frame(width: 52)

            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.15), in: Circle())
            }

            Slider(value: value, in: range, step: step)
                .tint(.green)
        }
        .padding(.horizontal, 10)
    }

    private func formatValue(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private func sendJSCommands(_ c: Character3DDevConfig) {
        let cmds = [
            "window._devCam && window._devCam(0, \(c.camY), 0)",
            "window._devModel && window._devModel(0, \(c.mdlY), 0)",
            "window._devTarget && window._devTarget(\(c.tgtX), \(c.tgtY), \(c.tgtZ))",
            "window._devFOV && window._devFOV(\(c.fov))",
            "window._devScale && window._devScale(\(c.scale))"
        ]
        for cmd in cmds {
            NotificationCenter.default.post(
                name: .character3DDevCommand,
                object: nil,
                userInfo: ["js": cmd]
            )
        }
    }
}

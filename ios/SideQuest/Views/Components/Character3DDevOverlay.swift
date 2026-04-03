import SwiftUI

nonisolated struct Character3DDevConfig: Codable, Sendable, Equatable {
    var camY: Double = 0
    var mdlY: Double = 0
    var tgtX: Double = 0
    var tgtY: Double = 0
    var tgtZ: Double = 0
    var fov: Double = 50
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
    @State private var jsonText: String = ""
    @State private var statusMessage: String = ""

    var body: some View {
        if isVisible {
            VStack(spacing: 0) {
                HStack {
                    Text("3D Dev")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        jsonText = config.jsonString()
                        statusMessage = "Exported"
                    } label: {
                        Text("Export")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green, in: Capsule())
                    }
                    Button {
                        applyJSON()
                    } label: {
                        Text("Apply")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.orange, in: Capsule())
                    }
                    Button {
                        isVisible = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }

                TextEditor(text: $jsonText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green)
                    .scrollContentBackground(.hidden)
                    .frame(height: 200)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
            .background(Color.black.opacity(0.88))
            .clipShape(.rect(cornerRadius: 10))
            .padding(.horizontal, 12)
            .onAppear {
                jsonText = config.jsonString()
            }
        }
    }

    private func applyJSON() {
        guard let parsed = Character3DDevConfig.from(json: jsonText) else {
            statusMessage = "Invalid JSON"
            return
        }
        config = parsed
        sendJSCommands(parsed)
        statusMessage = "Applied"
    }

    private func sendJSCommands(_ c: Character3DDevConfig) {
        let cmds = [
            "window._devCam && window._devCam(0, \(c.camY), 0)",
            "window._devModel && window._devModel(0, \(c.mdlY), 0)",
            "window._devTarget && window._devTarget(\(c.tgtX), \(c.tgtY), \(c.tgtZ))",
            "window._devFOV && window._devFOV(\(c.fov))"
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

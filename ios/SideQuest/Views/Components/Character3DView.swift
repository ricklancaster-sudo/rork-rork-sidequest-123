import SwiftUI
import WebKit

struct Character3DView: View {
    let characterType: PlayerCharacterType
    var allowsControl: Bool = false
    var autoRotate: Bool = true
    var framing: Character3DFraming = .fullBody
    var modelYawDegrees: Int = 0
    var sceneStyle: Character3DSceneStyle = .standard
    var debugMode: Character3DDebugMode = .beauty
    var isActive: Bool = true
    var equipment: CharacterEquipmentState? = nil

    @State private var isPreviewReady: Bool = false
    @State private var loadError: String? = nil
    @State private var lookupNotes: [String] = []

    var body: some View {
        ZStack {
            CharacterWebView(
                request: previewRequest,
                equipment: equipment,
                isActive: isActive,
                isPreviewReady: $isPreviewReady,
                loadError: $loadError,
                lookupNotes: $lookupNotes
            )

            if !isPreviewReady {
                if let error = loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text("Load Error")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                } else {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.42), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            isPreviewReady = false
            loadError = nil
        }
        .onChange(of: previewRequest.key) { _, _ in
            isPreviewReady = false
            loadError = nil
        }
        .animation(.easeOut(duration: 0.18), value: isPreviewReady)
    }

    private var previewRequest: CharacterPreviewRequest {
        CharacterPreviewRequest(
            characterType: characterType,
            allowsControl: allowsControl,
            autoRotate: autoRotate,
            framing: framing,
            modelYawDegrees: modelYawDegrees,
            sceneStyle: sceneStyle,
            debugMode: debugMode,
            equipment: equipment
        )
    }
}

struct CharacterPreviewRequest: Sendable {
    let characterType: PlayerCharacterType
    let allowsControl: Bool
    let autoRotate: Bool
    let framing: Character3DFraming
    let modelYawDegrees: Int
    let sceneStyle: Character3DSceneStyle
    let debugMode: Character3DDebugMode
    let equipment: CharacterEquipmentState?

    var isModular: Bool { equipment != nil }

    var key: String {
        let modeStr = isModular ? "modular|\(equipment?.sourceFilesKey ?? "")" : "single"
        return "\(modeStr)|\(characterType.rawValue)|\(framing.rawValue)|\(modelYawDegrees)|\(sceneStyle.rawValue)|\(debugMode.rawValue)|\(allowsControl)|\(autoRotate)"
    }
}

private struct CharacterWebView: UIViewRepresentable {
    let request: CharacterPreviewRequest
    let equipment: CharacterEquipmentState?
    let isActive: Bool
    @Binding var isPreviewReady: Bool
    @Binding var loadError: String?
    @Binding var lookupNotes: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPreviewReady: $isPreviewReady,
            loadError: $loadError,
            lookupNotes: $lookupNotes
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.handlerName)
        config.userContentController = userContentController
        config.setURLSchemeHandler(CharacterPreviewSchemeHandler(), forURLScheme: CharacterPreviewSchemeHandler.scheme)

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.bind(webView)
        context.coordinator.load(request)
        context.coordinator.setActive(isActive, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.navigationDelegate = context.coordinator
        context.coordinator.isPreviewReady = $isPreviewReady
        context.coordinator.loadError = $loadError
        context.coordinator.lookupNotes = $lookupNotes
        context.coordinator.load(request)
        if let equipment {
            context.coordinator.updateEquipment(equipment)
        }
        context.coordinator.setActive(isActive, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let handlerName = "previewState"

        private weak var webView: WKWebView?
        private var requestKey: String?
        private var lastRequest: CharacterPreviewRequest?
        private var currentlyActive: Bool = true
        private var isReady: Bool = false
        private var currentEquipment: CharacterEquipmentState?
        var isPreviewReady: Binding<Bool>
        var loadError: Binding<String?>
        var lookupNotes: Binding<[String]>

        init(
            isPreviewReady: Binding<Bool>,
            loadError: Binding<String?>,
            lookupNotes: Binding<[String]>
        ) {
            self.isPreviewReady = isPreviewReady
            self.loadError = loadError
            self.lookupNotes = lookupNotes
        }

        func bind(_ webView: WKWebView) {
            self.webView = webView
        }

        func setActive(_ active: Bool, in webView: WKWebView) {
            guard active != currentlyActive else { return }
            currentlyActive = active
            let js = active ? "window._resume && window._resume()" : "window._pause && window._pause()"
            webView.evaluateJavaScript(js)
        }

        func load(_ request: CharacterPreviewRequest, forceReload: Bool = false) {
            guard let webView else { return }
            guard forceReload || requestKey != request.key else { return }

            isPreviewReady.wrappedValue = false
            loadError.wrappedValue = nil
            lookupNotes.wrappedValue = []
            requestKey = request.key
            lastRequest = request
            isReady = false
            currentEquipment = request.equipment

            var components = URLComponents()
            components.scheme = CharacterPreviewSchemeHandler.scheme
            components.host = "preview"
            components.path = "/index.html"

            var queryItems = [
                URLQueryItem(name: "controls", value: request.allowsControl ? "1" : "0"),
                URLQueryItem(name: "rotate", value: request.autoRotate ? "1" : "0"),
                URLQueryItem(name: "framing", value: request.framing.rawValue),
                URLQueryItem(name: "yaw", value: "\(request.modelYawDegrees)"),
                URLQueryItem(name: "sceneStyle", value: request.sceneStyle.rawValue)
            ]

            if request.isModular, let equipment = request.equipment {
                queryItems.append(URLQueryItem(name: "mode", value: "modular"))
                queryItems.append(URLQueryItem(name: "baseModel", value: "WhiteMale"))
                let configJSON = equipment.jsConfigJSON()
                let encoded = configJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "{}"
                queryItems.append(URLQueryItem(name: "config", value: encoded))
            } else {
                queryItems.append(URLQueryItem(name: "mode", value: "single"))
                queryItems.append(URLQueryItem(name: "model", value: request.characterType.fileName))
            }

            components.queryItems = queryItems

            guard let url = components.url else { return }
            webView.load(URLRequest(url: url))
        }

        func updateEquipment(_ newEquipment: CharacterEquipmentState) {
            guard isReady, let currentEquipment, newEquipment != currentEquipment else { return }
            let old = currentEquipment
            self.currentEquipment = newEquipment

            for slot in EquipmentSlot.allCases {
                let wasEquipped = old.equipped(for: slot) != nil
                let isEquipped = newEquipment.equipped(for: slot) != nil

                if wasEquipped != isEquipped {
                    if isEquipped {
                        if let configJSON = newEquipment.jsSlotConfigJSON(for: slot) {
                            let escaped = configJSON.replacingOccurrences(of: "'", with: "\\'")
                            webView?.evaluateJavaScript("window._equip && window._equip('\(slot.rawValue)', '\(escaped)')")
                        }
                    } else {
                        webView?.evaluateJavaScript("window._unequip && window._unequip('\(slot.rawValue)')")
                    }
                } else if isEquipped {
                    let oldItem = old.resolvedItem(for: slot)
                    let newItem = newEquipment.resolvedItem(for: slot)
                    if oldItem?.id != newItem?.id {
                        webView?.evaluateJavaScript("window._unequip && window._unequip('\(slot.rawValue)')")
                        if let configJSON = newEquipment.jsSlotConfigJSON(for: slot) {
                            let escaped = configJSON.replacingOccurrences(of: "'", with: "\\'")
                            webView?.evaluateJavaScript("window._equip && window._equip('\(slot.rawValue)', '\(escaped)')")
                        }
                    }
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in reloadIfNeeded() }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in reloadIfNeeded() }
        }

        nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                requestKey = nil
                isReady = false
                reloadIfNeeded()
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            Task { @MainActor in handleMessage(message.body) }
        }

        @MainActor
        private func handleMessage(_ body: Any) {
            let state: String?
            var payload: [String: Any]?
            if let rawState = body as? String {
                state = rawState
            } else if let dict = body as? [String: Any] {
                state = dict["state"] as? String
                payload = dict
            } else {
                state = nil
            }

            switch state {
            case "ready":
                isReady = true
                isPreviewReady.wrappedValue = true
                loadError.wrappedValue = nil
                if let notes = payload?["lookupNotes"] as? [String] {
                    lookupNotes.wrappedValue = notes
                }
            case "init":
                isReady = false
                isPreviewReady.wrappedValue = false
            case "loadError":
                isReady = false
                isPreviewReady.wrappedValue = false
                loadError.wrappedValue = payload?["error"] as? String ?? "Unknown error"
            default:
                break
            }
        }

        private func reloadIfNeeded() {
            guard let request = lastRequest else { return }
            requestKey = nil
            isReady = false
            load(request, forceReload: true)
        }
    }
}

import SwiftUI
import WebKit

struct ModularCharacter3DView: View {
    var allowsControl: Bool = true
    var autoRotate: Bool = false
    var framing: Character3DFraming = .fullBody
    var modelYawDegrees: Int = 154
    var sceneStyle: Character3DSceneStyle = .heroProfile
    var isActive: Bool = true
    var equipment: CharacterEquipmentState = .fullCowboy

    @State private var isPreviewReady: Bool = false

    var body: some View {
        ZStack {
            ModularCharacter3DWebView(
                equipment: equipment,
                allowsControl: allowsControl,
                autoRotate: autoRotate,
                framing: framing,
                modelYawDegrees: modelYawDegrees,
                sceneStyle: sceneStyle,
                isActive: isActive,
                isPreviewReady: $isPreviewReady
            )

            if !isPreviewReady {
                ProgressView()
                    .tint(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.42), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear { isPreviewReady = false }
        .animation(.easeOut(duration: 0.18), value: isPreviewReady)
    }
}

private struct ModularCharacter3DWebView: UIViewRepresentable {
    let equipment: CharacterEquipmentState
    let allowsControl: Bool
    let autoRotate: Bool
    let framing: Character3DFraming
    let modelYawDegrees: Int
    let sceneStyle: Character3DSceneStyle
    let isActive: Bool
    @Binding var isPreviewReady: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isPreviewReady: $isPreviewReady)
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
        context.coordinator.loadModular(
            equipment: equipment,
            allowsControl: allowsControl,
            autoRotate: autoRotate,
            framing: framing,
            yaw: modelYawDegrees,
            sceneStyle: sceneStyle
        )
        context.coordinator.setActive(isActive, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.navigationDelegate = context.coordinator
        context.coordinator.isPreviewReady = $isPreviewReady
        context.coordinator.updateEquipment(equipment)
        context.coordinator.setActive(isActive, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let handlerName = "previewState"

        private weak var webView: WKWebView?
        private var hasLoaded: Bool = false
        private var isReady: Bool = false
        private var currentEquipment: CharacterEquipmentState = .naked
        private var currentlyActive: Bool = true
        var isPreviewReady: Binding<Bool>

        init(isPreviewReady: Binding<Bool>) {
            self.isPreviewReady = isPreviewReady
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

        func loadModular(
            equipment: CharacterEquipmentState,
            allowsControl: Bool,
            autoRotate: Bool,
            framing: Character3DFraming,
            yaw: Int,
            sceneStyle: Character3DSceneStyle
        ) {
            guard let webView else { return }
            guard !hasLoaded else { return }

            isPreviewReady.wrappedValue = false
            currentEquipment = equipment
            hasLoaded = true

            var equipSlots: [String] = []
            for slot in EquipmentSlot.allCases {
                if equipment.equipped(for: slot) != nil {
                    equipSlots.append(slot.rawValue)
                }
            }

            var components = URLComponents()
            components.scheme = CharacterPreviewSchemeHandler.scheme
            components.host = "preview"
            components.path = "/modular.html"
            components.queryItems = [
                URLQueryItem(name: "controls", value: allowsControl ? "1" : "0"),
                URLQueryItem(name: "rotate", value: autoRotate ? "1" : "0"),
                URLQueryItem(name: "framing", value: framing.rawValue),
                URLQueryItem(name: "yaw", value: "\(yaw)"),
                URLQueryItem(name: "sceneStyle", value: sceneStyle.rawValue),
                URLQueryItem(name: "equip", value: equipSlots.joined(separator: ","))
            ]

            guard let url = components.url else { return }
            webView.load(URLRequest(url: url))
        }

        func updateEquipment(_ newEquipment: CharacterEquipmentState) {
            guard isReady, newEquipment != currentEquipment else { return }
            let old = currentEquipment
            currentEquipment = newEquipment

            for slot in EquipmentSlot.allCases {
                let wasEquipped = old.equipped(for: slot) != nil
                let isEquipped = newEquipment.equipped(for: slot) != nil
                if wasEquipped != isEquipped {
                    let js = isEquipped
                        ? "window._equip && window._equip('\(slot.rawValue)')"
                        : "window._unequip && window._unequip('\(slot.rawValue)')"
                    webView?.evaluateJavaScript(js)
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
                hasLoaded = false
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
            if let rawState = body as? String {
                state = rawState
            } else if let payload = body as? [String: Any] {
                state = payload["state"] as? String
            } else {
                state = nil
            }

            switch state {
            case "ready":
                isReady = true
                isPreviewReady.wrappedValue = true
            case "init":
                isReady = false
                isPreviewReady.wrappedValue = false
            default:
                break
            }
        }

        private func reloadIfNeeded() {
            hasLoaded = false
            isReady = false
        }
    }
}

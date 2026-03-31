import Foundation

actor FlyioScraperTriggerService {
    static let shared = FlyioScraperTriggerService()

    private let baseURL = URL(string: "https://sidequest-ingestion-worker.fly.dev")!
    private let session: URLSession
    private var recentTriggers: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 120

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    func triggerRefreshIfNeeded(
        searchLocation: ExternalEventSearchLocation,
        intent: ExternalDiscoveryIntent
    ) {
        let metroSlug = metroSlug(for: searchLocation)
        guard let metroSlug else { return }

        let triggerKey = "\(metroSlug)::\(intent.rawValue)"
        if let lastTrigger = recentTriggers[triggerKey],
           Date().timeIntervalSince(lastTrigger) < cooldownInterval {
            return
        }
        recentTriggers[triggerKey] = Date()

        Task.detached(priority: .utility) { [session, baseURL] in
            let url = baseURL.appendingPathComponent("api/trigger-refresh")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let intentSlug: String
            switch intent {
            case .nearbyWorthIt: intentSlug = "nearby_and_worth_it"
            case .biggestTonight: intentSlug = "biggest_tonight"
            case .exclusiveHot: intentSlug = "exclusive_hot"
            case .lastMinutePlans: intentSlug = "last_minute_plans"
            }

            let body: [String: String] = [
                "metro_slug": metroSlug,
                "intent": intentSlug
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            _ = try? await session.data(for: request)
        }
    }

    private nonisolated func metroSlug(for searchLocation: ExternalEventSearchLocation) -> String? {
        let city = ExternalEventSupport.normalizeToken(searchLocation.city)
        let state = ExternalEventSupport.normalizeStateToken(searchLocation.state)
        let display = ExternalEventSupport.normalizeToken(searchLocation.displayName)
        let haystack = "\(city) \(state) \(display)"

        let metroMap: [(tokens: [String], slug: String)] = [
            (["los angeles", "west hollywood", "hollywood", "beverly hills"], "los-angeles"),
            (["new york", "manhattan", "brooklyn", "queens"], "new-york"),
            (["miami", "miami beach", "south beach"], "miami"),
            (["chicago"], "chicago"),
            (["las vegas", "vegas"], "las-vegas"),
            (["austin"], "austin"),
            (["nashville"], "nashville"),
            (["dallas"], "dallas"),
            (["houston"], "houston"),
            (["atlanta"], "atlanta"),
            (["denver"], "denver"),
            (["scottsdale", "phoenix"], "scottsdale"),
            (["boston"], "boston"),
            (["philadelphia"], "philadelphia"),
            (["seattle"], "seattle"),
            (["new orleans"], "new-orleans"),
            (["washington", "district of columbia"], "washington-dc"),
            (["san francisco"], "san-francisco"),
            (["san diego"], "san-diego"),
            (["sacramento"], "sacramento"),
            (["orlando"], "orlando"),
            (["tampa"], "tampa"),
            (["san antonio"], "san-antonio"),
            (["portland"], "portland"),
            (["minneapolis"], "minneapolis"),
            (["charlotte"], "charlotte"),
            (["detroit"], "detroit"),
            (["columbus"], "columbus"),
            (["cleveland"], "cleveland"),
            (["cincinnati"], "cincinnati"),
            (["pittsburgh"], "pittsburgh"),
            (["indianapolis"], "indianapolis"),
            (["milwaukee"], "milwaukee"),
            (["salt lake city"], "salt-lake-city"),
            (["kansas city"], "kansas-city"),
            (["raleigh"], "raleigh"),
            (["baltimore"], "baltimore"),
            (["st louis", "saint louis"], "st-louis"),
        ]

        for entry in metroMap {
            if entry.tokens.contains(where: { haystack.contains($0) }) {
                return entry.slug
            }
        }

        return nil
    }
}

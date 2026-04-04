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

    func triggerPOITileRefreshIfNeeded(
        searchLocation: ExternalEventSearchLocation
    ) {
        let metroSlug = metroSlug(for: searchLocation)
        guard let metroSlug else { return }

        let triggerKey = "poi::\(metroSlug)"
        if let lastTrigger = recentTriggers[triggerKey],
           Date().timeIntervalSince(lastTrigger) < cooldownInterval {
            return
        }
        recentTriggers[triggerKey] = Date()

        Task.detached(priority: .utility) { [session, baseURL] in
            let url = baseURL.appendingPathComponent("api/trigger-poi-refresh")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "metro_slug": metroSlug
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

        for entry in Self.metroMap {
            if entry.tokens.contains(where: { haystack.contains($0) }) {
                return entry.slug
            }
        }

        return nil
    }

    private nonisolated static let metroMap: [(tokens: [String], slug: String)] = [
        (["los angeles", "west hollywood", "hollywood", "beverly hills", "santa monica", "culver city"], "los-angeles"),
        (["new york", "manhattan", "brooklyn", "queens", "bronx", "harlem"], "new-york"),
        (["miami", "miami beach", "south beach", "wynwood", "brickell"], "miami"),
        (["chicago", "wicker park", "lincoln park", "lakeview"], "chicago"),
        (["las vegas", "vegas", "the strip"], "las-vegas"),
        (["austin", "sixth street", "east austin"], "austin"),
        (["nashville", "broadway", "music row"], "nashville"),
        (["dallas", "uptown dallas", "deep ellum"], "dallas"),
        (["houston", "montrose", "midtown houston"], "houston"),
        (["atlanta", "buckhead", "midtown atlanta"], "atlanta"),
        (["denver", "lodo", "rino"], "denver"),
        (["scottsdale"], "phoenix"),
        (["phoenix", "tempe"], "phoenix"),
        (["boston", "back bay", "fenway"], "boston"),
        (["philadelphia", "philly", "old city"], "philadelphia"),
        (["seattle", "capitol hill", "belltown"], "seattle"),
        (["new orleans", "french quarter", "bourbon street"], "new-orleans"),
        (["washington", "district of columbia", "georgetown", "dupont circle"], "washington-dc"),
        (["san francisco", "soma", "mission district", "castro"], "san-francisco"),
        (["san diego", "gaslamp", "pacific beach"], "san-diego"),
        (["sacramento", "midtown sacramento"], "sacramento"),
        (["orlando", "downtown orlando"], "orlando"),
        (["tampa", "ybor city", "channelside"], "tampa"),
        (["san antonio", "river walk"], "san-antonio"),
        (["portland", "pearl district", "hawthorne"], "portland"),
        (["minneapolis", "uptown minneapolis", "northeast minneapolis"], "minneapolis"),
        (["charlotte", "uptown charlotte", "noda"], "charlotte"),
        (["detroit", "corktown", "midtown detroit"], "detroit"),
        (["columbus", "short north", "german village"], "columbus"),
        (["cleveland", "ohio city", "tremont"], "cleveland"),
        (["cincinnati", "over-the-rhine"], "cincinnati"),
        (["pittsburgh", "strip district", "lawrenceville"], "pittsburgh"),
        (["indianapolis", "broad ripple", "mass ave"], "indianapolis"),
        (["milwaukee", "third ward", "brady street"], "milwaukee"),
        (["salt lake city", "slc"], "salt-lake-city"),
        (["kansas city", "westport", "power and light"], "kansas-city"),
        (["raleigh", "glenwood south"], "raleigh"),
        (["baltimore", "fells point", "federal hill"], "baltimore"),
        (["st louis", "saint louis", "soulard", "the grove"], "st-louis"),
        (["san jose", "santana row"], "san-jose"),
        (["jacksonville", "jax beach", "riverside jax"], "jacksonville"),
        (["fort worth", "sundance square"], "fort-worth"),
        (["memphis", "beale street"], "memphis"),
        (["louisville", "bardstown road", "nulu"], "louisville"),
        (["tucson", "fourth avenue"], "tucson"),
        (["albuquerque"], "albuquerque"),
        (["fresno"], "fresno"),
        (["mesa"], "mesa"),
        (["omaha", "old market"], "omaha"),
        (["tulsa", "blue dome"], "tulsa"),
        (["oakland", "jack london square", "temescal"], "oakland"),
        (["virginia beach"], "virginia-beach"),
        (["long beach", "belmont shore"], "long-beach"),
        (["colorado springs"], "colorado-springs"),
        (["el paso"], "el-paso"),
        (["honolulu", "waikiki"], "honolulu"),
        (["oklahoma city", "bricktown"], "oklahoma-city"),
        (["new haven", "yale"], "new-haven"),
        (["richmond", "shockoe bottom", "carytown"], "richmond"),
        (["buffalo", "elmwood village"], "buffalo"),
        (["boise", "downtown boise"], "boise"),
        (["madison", "state street madison"], "madison"),
        (["des moines", "east village des moines"], "des-moines"),
        (["little rock", "river market"], "little-rock"),
        (["birmingham", "avondale", "lakeview birmingham"], "birmingham"),
        (["knoxville", "market square", "old city knoxville"], "knoxville"),
        (["providence", "federal hill"], "providence"),
        (["chattanooga", "north shore chattanooga"], "chattanooga"),
        (["grand rapids", "downtown grand rapids"], "grand-rapids"),
        (["hartford", "downtown hartford"], "hartford"),
        (["greenville", "downtown greenville sc"], "greenville"),
        (["charleston", "king street"], "charleston"),
        (["savannah", "river street"], "savannah"),
        (["norfolk", "ghent"], "norfolk"),
        (["lexington", "downtown lexington"], "lexington"),
        (["wichita", "old town wichita"], "wichita"),
        (["durham", "downtown durham"], "durham"),
        (["anchorage"], "anchorage"),
        (["bakersfield"], "bakersfield"),
        (["aurora colorado", "aurora co"], "aurora"),
        (["stockton"], "stockton"),
        (["riverside"], "riverside"),
        (["corpus christi"], "corpus-christi"),
        (["irvine"], "irvine"),
        (["st petersburg", "saint petersburg", "st pete"], "st-petersburg"),
        (["newark", "ironbound"], "newark"),
        (["jersey city", "hoboken"], "jersey-city"),
        (["anaheim", "disneyland"], "anaheim"),
        (["santa ana"], "santa-ana"),
        (["henderson nevada", "henderson nv"], "henderson"),
        (["reno", "midtown reno"], "reno"),
        (["chandler"], "chandler"),
        (["north las vegas"], "north-las-vegas"),
        (["gilbert arizona", "gilbert az"], "gilbert"),
        (["plano"], "plano"),
        (["laredo"], "laredo"),
        (["lubbock"], "lubbock"),
        (["huntsville"], "madison-al"),
        (["spokane"], "spokane"),
        (["tacoma", "stadium district"], "tacoma"),
        (["rochester new york", "rochester ny"], "rochester"),
        (["baton rouge", "tigerland"], "baton-rouge"),
        (["columbia south carolina", "columbia sc", "five points columbia"], "columbia-sc"),
        (["asheville", "downtown asheville"], "asheville"),
        (["wilmington north carolina", "wilmington nc"], "wilmington"),
        (["fort lauderdale", "las olas"], "fort-lauderdale"),
        (["west palm beach", "clematis street"], "west-palm-beach"),
        (["naples florida", "naples fl"], "naples"),
        (["sarasota"], "sarasota"),
        (["pensacola"], "pensacola"),
        (["tallahassee", "college town tallahassee"], "tallahassee"),
        (["gainesville florida", "gainesville fl", "midtown gainesville"], "gainesville"),
        (["eugene oregon", "eugene or"], "eugene"),
        (["ann arbor", "south university"], "ann-arbor"),
    ]
}

import Foundation

actor CronSweepService {
    static let shared = CronSweepService()

    private let flyBaseURL = URL(string: "https://sidequest-ingestion-worker.fly.dev")!
    private let session: URLSession
    private var lastSweepAt: Date?
    private let sweepCooldown: TimeInterval = 2 * 60 * 60

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    func sweepIfNeeded() async {
        if let lastSweep = lastSweepAt,
           Date().timeIntervalSince(lastSweep) < sweepCooldown {
            return
        }
        lastSweepAt = Date()

        let configuration = SupabaseEventFeedCacheConfiguration.fromEnvironment()
        guard configuration.isConfigured,
              let projectURL = configuration.projectURL,
              let anonKey = configuration.anonKey else { return }

        let metros = await fetchDueMetros(projectURL: projectURL, anonKey: anonKey)
        guard !metros.isEmpty else { return }

        for metro in metros {
            await triggerEventRefresh(slug: metro.slug, intent: "nearby_and_worth_it")
            await triggerPOIRefresh(slug: metro.slug)
            await updateLastRefresh(slug: metro.slug, projectURL: projectURL, anonKey: anonKey)
        }
    }

    private func fetchDueMetros(
        projectURL: URL,
        anonKey: String
    ) async -> [MetroEntry] {
        var components = URLComponents(
            url: projectURL.appendingPathComponent("rest/v1/ingestion_metros"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "slug,refresh_interval_minutes,last_refresh_at"),
            URLQueryItem(name: "enabled", value: "eq.true"),
            URLQueryItem(name: "order", value: "tier.asc,slug.asc"),
            URLQueryItem(name: "limit", value: "40")
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else { return [] }

        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        let now = Date()
        return rows.compactMap { row -> MetroEntry? in
            guard let slug = row["slug"] as? String,
                  let intervalMinutes = row["refresh_interval_minutes"] as? Int else { return nil }

            if let lastRefreshStr = row["last_refresh_at"] as? String,
               let lastRefresh = Self.parseDate(lastRefreshStr) {
                let elapsed = now.timeIntervalSince(lastRefresh)
                if elapsed < Double(intervalMinutes) * 60 {
                    return nil
                }
            }
            return MetroEntry(slug: slug, intervalMinutes: intervalMinutes)
        }
    }

    private func triggerEventRefresh(slug: String, intent: String) async {
        let url = flyBaseURL.appendingPathComponent("api/trigger-refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metro_slug": slug,
            "intent": intent
        ])
        _ = try? await session.data(for: request)
    }

    private func triggerPOIRefresh(slug: String) async {
        let url = flyBaseURL.appendingPathComponent("api/trigger-poi-refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metro_slug": slug
        ])
        _ = try? await session.data(for: request)
    }

    private func updateLastRefresh(
        slug: String,
        projectURL: URL,
        anonKey: String
    ) async {
        var components = URLComponents(
            url: projectURL.appendingPathComponent("rest/v1/ingestion_metros"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "slug", value: "eq.\(slug)")
        ]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let now = Self.postgrestTimestamp(from: Date())
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "last_refresh_at": now,
            "updated_at": now
        ])
        _ = try? await session.data(for: request)
    }

    nonisolated private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    nonisolated private static func postgrestTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct MetroEntry {
    let slug: String
    let intervalMinutes: Int
}

import Foundation

nonisolated struct SupabasePlayerProfile: Codable, Sendable {
    let user_id: String
    var username: String
    var display_name: String
    var avatar_name: String
    var selected_character: String
    var level: Int
    var total_score: Int
    var gold: Int
    var diamonds: Int
    var current_streak: Int
    var verified_count: Int
    var warrior_rank: Int
    var explorer_rank: Int
    var mind_rank: Int
    var selected_skills: [String]
    var selected_interests: [String]
    var goals: [String]
    var equipment_state: String?
    var owned_items: [String]
    var owned_skin_pack_pieces: [String]
    var earned_badges: [String]
    var updated_at: String?
}

actor SupabaseProfileService {
    static let shared = SupabaseProfileService()

    private var projectURL: URL?
    private var anonKey: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)

        let env = ProcessInfo.processInfo.environment
        let resolvedURL = Self.nonEmpty(Config.allValues["EXPO_PUBLIC_SUPABASE_URL"])
            ?? Self.nonEmpty(env["SUPABASE_URL"])
            ?? Self.nonEmpty(env["EXPO_PUBLIC_SUPABASE_URL"])
        let resolvedKey = Self.nonEmpty(Config.allValues["EXPO_PUBLIC_SUPABASE_ANON_KEY"])
            ?? Self.nonEmpty(env["SUPABASE_ANON_KEY"])
            ?? Self.nonEmpty(env["EXPO_PUBLIC_SUPABASE_ANON_KEY"])

        self.projectURL = resolvedURL.flatMap(URL.init(string:))
        self.anonKey = resolvedKey
    }

    var isConfigured: Bool {
        projectURL != nil && anonKey != nil && !(anonKey?.isEmpty ?? true)
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    func upsertProfile(_ profile: SupabasePlayerProfile) async -> Bool {
        guard let projectURL, let anonKey else { return false }

        let url = projectURL.appendingPathComponent("/rest/v1/player_profiles")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")

        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Prefer"] = "return=minimal,resolution=merge-duplicates"
        request.allHTTPHeaderFields = headers

        guard let body = try? encoder.encode(profile) else { return false }
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    func fetchProfile(userId: String) async -> SupabasePlayerProfile? {
        guard let projectURL, let anonKey else { return nil }

        var components = URLComponents(url: projectURL.appendingPathComponent("/rest/v1/player_profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            let profiles = try decoder.decode([SupabasePlayerProfile].self, from: data)
            return profiles.first
        } catch {
            return nil
        }
    }

    func checkUsernameAvailable(_ username: String, excludingUserId: String?) async -> Bool {
        guard let projectURL, let anonKey else { return true }

        var components = URLComponents(url: projectURL.appendingPathComponent("/rest/v1/player_profiles"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "username", value: "eq.\(username.lowercased())"),
            URLQueryItem(name: "select", value: "user_id"),
            URLQueryItem(name: "limit", value: "1")
        ]
        if let excludeId = excludingUserId {
            queryItems.append(URLQueryItem(name: "user_id", value: "neq.\(excludeId)"))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else { return true }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return true }
            let results = try decoder.decode([[String: String]].self, from: data)
            return results.isEmpty
        } catch {
            return true
        }
    }
}

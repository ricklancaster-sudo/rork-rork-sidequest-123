import Foundation

actor CronSweepService {
    static let shared = CronSweepService()

    private let flyBaseURL = URL(string: "https://sidequest-ingestion-worker.fly.dev")!
    private let session: URLSession
    private var lastTierSweepAt: [Int: Date] = [:]
    private var lastBackfillAt: Date?
    private var lastSupabaseEnqueueAt: Date?
    private var lastReclaimAt: Date?

    private let tierCooldowns: [Int: TimeInterval] = [
        1: 45 * 60,
        2: 90 * 60,
        3: 3 * 60 * 60
    ]
    private let backfillCooldown: TimeInterval = 3 * 60 * 60
    private let supabaseEnqueueCooldown: TimeInterval = 30 * 60
    private let reclaimCooldown: TimeInterval = 10 * 60

    private var supabaseConfig: SupabaseEventFeedCacheConfiguration {
        .fromEnvironment()
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func sweepIfNeeded() async {
        await enqueueScheduledRefreshesIfDue()
        await reclaimStaleJobsIfDue()
        await triggerTierBackfillIfDue(tier: 1)
        await triggerTierBackfillIfDue(tier: 2)
        await triggerTierBackfillIfDue(tier: 3)
    }

    func forceFullBackfill() async {
        await callSupabaseRPC("enqueue_scheduled_refreshes")
        await callSupabaseRPC("reclaim_stale_jobs")
        await triggerBackfill(tier: 3)
        lastBackfillAt = Date()
        lastTierSweepAt[1] = Date()
        lastTierSweepAt[2] = Date()
        lastTierSweepAt[3] = Date()
        lastSupabaseEnqueueAt = Date()
        lastReclaimAt = Date()
    }

    private func enqueueScheduledRefreshesIfDue() async {
        if let last = lastSupabaseEnqueueAt,
           Date().timeIntervalSince(last) < supabaseEnqueueCooldown {
            return
        }
        lastSupabaseEnqueueAt = Date()
        await callSupabaseRPC("enqueue_scheduled_refreshes")
    }

    private func reclaimStaleJobsIfDue() async {
        if let last = lastReclaimAt,
           Date().timeIntervalSince(last) < reclaimCooldown {
            return
        }
        lastReclaimAt = Date()
        await callSupabaseRPC("reclaim_stale_jobs")
    }

    private func triggerTierBackfillIfDue(tier: Int) async {
        let cooldown = tierCooldowns[tier] ?? (4 * 60 * 60)
        if let lastSweep = lastTierSweepAt[tier],
           Date().timeIntervalSince(lastSweep) < cooldown {
            return
        }
        lastTierSweepAt[tier] = Date()
        await triggerBackfill(tier: tier)
    }

    private func triggerBackfill(tier: Int) async {
        let url = flyBaseURL.appendingPathComponent("api/trigger-backfill")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "tier": tier
        ])
        _ = try? await session.data(for: request)
    }

    private func callSupabaseRPC(_ functionName: String) async {
        let cfg = supabaseConfig
        guard let baseURL = cfg.projectURL, let anonKey = cfg.anonKey, !anonKey.isEmpty else { return }
        guard let url = URL(string: "\(baseURL.absoluteString)/rest/v1/rpc/\(functionName)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        _ = try? await session.data(for: request)
    }
}

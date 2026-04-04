import Foundation

actor CronSweepService {
    static let shared = CronSweepService()

    private let flyBaseURL = URL(string: "https://sidequest-ingestion-worker.fly.dev")!
    private let session: URLSession
    private var lastTierSweepAt: [Int: Date] = [:]
    private var lastBackfillAt: Date?

    private let tierCooldowns: [Int: TimeInterval] = [
        1: 60 * 60,
        2: 2 * 60 * 60,
        3: 4 * 60 * 60
    ]
    private let backfillCooldown: TimeInterval = 3 * 60 * 60

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func sweepIfNeeded() async {
        await triggerTierBackfillIfDue(tier: 1)
        await triggerTierBackfillIfDue(tier: 2)
        await triggerTierBackfillIfDue(tier: 3)
    }

    func forceFullBackfill() async {
        await triggerBackfill(tier: 3)
        lastBackfillAt = Date()
        lastTierSweepAt[1] = Date()
        lastTierSweepAt[2] = Date()
        lastTierSweepAt[3] = Date()
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
}

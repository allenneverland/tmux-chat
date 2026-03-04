//
//  NotificationMetricsReporter.swift
//  TmuxChat
//

import Foundation

actor NotificationMetricsReporter {
    static let shared = NotificationMetricsReporter()

    private let userDefaults = UserDefaults.standard
    private let defaultsKey = "notification_metrics_pending_v1"
    private let maxRetentionSeconds: TimeInterval = 24 * 60 * 60
    private let debounceNanos: UInt64 = 1_500_000_000

    private var pendingByDeviceID: [String: PendingIOSMetrics]
    private var flushTask: Task<Void, Never>?

    private init() {
        pendingByDeviceID = Self.loadPending(from: userDefaults, key: defaultsKey)
        pruneExpired(now: Date())
        persist()
    }

    func recordTap(deviceId: String) {
        record(deviceId: deviceId) { pending, now in
            pending.notificationTapTotal = saturatingAdd(pending.notificationTapTotal, 1)
            pending.updatedAt = now
        }
    }

    func recordRouteSuccess(deviceId: String) {
        record(deviceId: deviceId) { pending, now in
            pending.routeSuccessTotal = saturatingAdd(pending.routeSuccessTotal, 1)
            pending.updatedAt = now
        }
    }

    func recordRouteFallback(deviceId: String) {
        record(deviceId: deviceId) { pending, now in
            pending.routeFallbackTotal = saturatingAdd(pending.routeFallbackTotal, 1)
            pending.updatedAt = now
        }
    }

    func flushNow() async {
        pruneExpired(now: Date())
        guard !pendingByDeviceID.isEmpty else {
            persist()
            return
        }

        var changed = false
        for deviceId in pendingByDeviceID.keys.sorted() {
            guard let pending = pendingByDeviceID[deviceId] else { continue }
            if pending.isEmpty {
                pendingByDeviceID.removeValue(forKey: deviceId)
                changed = true
                continue
            }

            do {
                try await TmuxChatAPI.shared.reportIOSMetrics(deviceId: deviceId, deltas: pending.request)
                pendingByDeviceID.removeValue(forKey: deviceId)
                changed = true
            } catch {
                print("Failed to flush iOS metrics for \(deviceId): \(error)")
            }
        }

        if changed {
            persist()
        }
    }

    private func record(
        deviceId: String,
        update: (inout PendingIOSMetrics, Date) -> Void
    ) {
        guard let normalized = normalize(deviceId: deviceId) else { return }

        let now = Date()
        var pending = pendingByDeviceID[normalized] ?? PendingIOSMetrics()
        update(&pending, now)
        pendingByDeviceID[normalized] = pending
        pruneExpired(now: now)
        persist()
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task {
            do {
                try await Task.sleep(nanoseconds: debounceNanos)
            } catch {
                return
            }
            await self.flushNow()
        }
    }

    private func normalize(deviceId: String) -> String? {
        let trimmed = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func pruneExpired(now: Date) {
        let before = pendingByDeviceID.count
        pendingByDeviceID = pendingByDeviceID.filter { _, pending in
            now.timeIntervalSince(pending.updatedAt) <= maxRetentionSeconds
        }
        if pendingByDeviceID.count != before {
            persist()
        }
    }

    private func persist() {
        if pendingByDeviceID.isEmpty {
            userDefaults.removeObject(forKey: defaultsKey)
            return
        }

        guard let encoded = try? JSONEncoder().encode(pendingByDeviceID) else { return }
        userDefaults.set(encoded, forKey: defaultsKey)
    }

    private static func loadPending(from defaults: UserDefaults, key: String) -> [String: PendingIOSMetrics] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: PendingIOSMetrics].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

private struct PendingIOSMetrics: Codable {
    var notificationTapTotal: Int = 0
    var routeSuccessTotal: Int = 0
    var routeFallbackTotal: Int = 0
    var updatedAt: Date = Date()

    var isEmpty: Bool {
        notificationTapTotal <= 0 && routeSuccessTotal <= 0 && routeFallbackTotal <= 0
    }

    var request: IOSMetricsIngestRequest {
        IOSMetricsIngestRequest(
            notificationTapTotal: max(notificationTapTotal, 0),
            routeSuccessTotal: max(routeSuccessTotal, 0),
            routeFallbackTotal: max(routeFallbackTotal, 0)
        )
    }
}

private func saturatingAdd(_ value: Int, _ delta: Int) -> Int {
    guard delta > 0 else { return value }
    return value > Int.max - delta ? Int.max : value + delta
}

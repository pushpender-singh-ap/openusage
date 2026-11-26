import Foundation

extension WidgetDataStore {
    private var enabledProviderIDs: [String] {
        registry.providers.map(\.id).filter { isProviderEnabled($0) }
    }

    private func nextCheck(for id: String, now: Date) -> Date {
        // An overlapping manual check will record its completion. Give it time to finish without
        // spinning the automatic loop on an already-due deadline.
        let interval = refreshSetting.interval(for: id)
        if refreshingProviderIDs.contains(id) { return now.addingTimeInterval(interval) }
        return lastCheckedAt[id]?.addingTimeInterval(interval) ?? now
    }

    var nextAutomaticRefreshAt: Date? {
        let time = now()
        return enabledProviderIDs.map { nextCheck(for: $0, now: time) }.min()
    }

    func refreshDueProviders() async {
        let time = now()
        let due = enabledProviderIDs.filter { nextCheck(for: $0, now: time) <= time }
        if !due.isEmpty { await refreshBatch(providerIDs: due, force: false) }
    }

    /// Manual refresh and one-shot reads can request all enabled cards regardless of the timer.
    func refreshAll(force: Bool = false) async {
        await refreshBatch(providerIDs: enabledProviderIDs, force: force)
    }

    private func refreshBatch(providerIDs: [String], force: Bool) async {
        // `Task {}` from MainActor context inherits the isolation (a task-group child can't capture
        // the non-Sendable store), so: fire one task per provider, then await them all.
        let start = monotonicNow()
        AppLog.info(.refresh, "batch start (\(providerIDs.count) providers, force=\(force))")
        snapshotRebuildDeferrals += 1
        let tasks = providerIDs.map { providerID in
            Task { await self.refresh(providerID: providerID, force: force, notifyHistoryChange: false) }
        }
        var outcomes: [RefreshOutcome] = []
        outcomes.reserveCapacity(tasks.count)
        for task in tasks {
            outcomes.append(await task.value)
        }
        snapshotRebuildDeferrals -= 1
        if snapshotRebuildDeferrals == 0 {
            coalescedRebuildTask?.cancel()
            coalescedRebuildTask = nil
            flushPendingSnapshotWork()
        }
        // Keep cards checked together on one timer even if their network requests finished seconds
        // apart. A cache hit or a skipped card keeps its own original deadline.
        let completedAt = now()
        for (id, outcome) in zip(providerIDs, outcomes) where outcome == .refreshed || outcome == .failed {
            lastCheckedAt[id] = completedAt
        }
        let durationMs = durationMilliseconds(since: start)
        // Count THIS batch's actual outcomes, not the long-lived `providerErrors` map (which persists
        // across passes, so reading it would miscount cache hits and stale earlier failures).
        let refreshed = outcomes.count { $0 == .refreshed }
        let failed = outcomes.count { $0 == .failed }
        let cached = outcomes.count { $0 == .cacheHit }
        let backedOff = outcomes.count { $0 == .backedOff }
        if refreshed > 0 { onLocalHistoryChanged?() }
        AppLog.info(.refresh, "batch end (\(durationMs)ms, \(refreshed) ok / \(failed) failed / \(cached) cached / \(backedOff) backed off)")
    }

    /// The user's own Refresh. It's the only refresh that lets a login they denied ask again.
    func refreshOnUserRequest(providerID: String? = nil) async {
        KeychainAccessGuard.forgetDenials()
        if let providerID {
            await refresh(providerID: providerID, force: true)
        } else {
            await refreshAll(force: true)
        }
    }
}

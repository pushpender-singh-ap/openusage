import os
import XCTest
@testable import OpenUsage

/// Provider-specific automatic checks and session-scoped snapshot freshness.
@MainActor
final class RefreshSettingTests: XCTestCase {
    func testDefaultsAndChoicesApplyToEveryAccountInTheProviderFamily() {
        let settings = RefreshSetting()
        for id in ["claude", "claude@account"] {
            XCTAssertEqual(settings.interval(for: id), 600)
            XCTAssertEqual(RefreshSetting.options(for: id), [10, 15, 30, 60])
        }
        for id in ["codex", "codex@account", "cursor"] {
            XCTAssertEqual(settings.interval(for: id), 300)
            XCTAssertEqual(RefreshSetting.options(for: id), [5, 10, 15, 30, 60])
        }
    }

    func testInvalidSavedValuesCannotLowerTheMinimumAndResetRemovesOverrides() {
        let suite = makeDefaults("persist")
        suite.set(["claude": 5, "codex": -1, "cursor": 15], forKey: RefreshSetting.key)
        var settings = RefreshSetting(defaults: suite)
        XCTAssertEqual(settings.minutes(for: "claude@account"), 10)
        XCTAssertEqual(settings.minutes(for: "codex"), 5)
        XCTAssertEqual(settings.minutes(for: "cursor"), 15)
        settings.setMinutes(30, for: "claude@account")
        settings.setMinutes(5, for: "claude")
        settings.save(to: suite)
        XCTAssertEqual(RefreshSetting(defaults: suite).minutes(for: "claude"), 30)
        RefreshSetting().save(to: suite)
        XCTAssertNil(suite.object(forKey: RefreshSetting.key))
    }

    func testMixedDeadlinesAndLiveChangesOnlyRefreshDueProviders() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(start)
        let claude = makeRuntime(id: "claude@account", used: 20)
        let codex = makeRuntime(id: "codex", used: 80)
        let suite = makeDefaults("deadlines")
        let store = WidgetDataStore(
            registry: .from([claude, codex]), providers: [claude, codex],
            cache: ProviderSnapshotCache(userDefaults: suite, now: { clock.now }),
            defaults: suite, now: { clock.now }
        )
        await store.refreshDueProviders()
        XCTAssertEqual([claude.refreshCount, codex.refreshCount], [1, 1])
        XCTAssertEqual(store.nextAutomaticRefreshAt, start.addingTimeInterval(300))

        clock.set(start.addingTimeInterval(300))
        await store.refreshDueProviders()
        XCTAssertEqual([claude.refreshCount, codex.refreshCount], [1, 2])
        store.refreshSetting.setMinutes(15, for: "codex")

        clock.set(start.addingTimeInterval(599))
        await store.refreshDueProviders()
        XCTAssertEqual([claude.refreshCount, codex.refreshCount], [1, 2])
        XCTAssertEqual(store.nextAutomaticRefreshAt, start.addingTimeInterval(600))

        clock.set(start.addingTimeInterval(600))
        await store.refreshDueProviders()
        XCTAssertEqual([claude.refreshCount, codex.refreshCount], [2, 2])
        XCTAssertNil(store.stalenessHint(for: "claude@account"))

        // Shortening an interval after that card is already due fetches it immediately.
        store.refreshSetting.setMinutes(5, for: "codex")
        await store.refreshDueProviders()
        XCTAssertEqual([claude.refreshCount, codex.refreshCount], [2, 3])

        store.refreshSetting.setMinutes(30, for: "claude")
        XCTAssertEqual(RefreshSetting(defaults: suite).minutes(for: "claude@account"), 30)
        clock.set(start.addingTimeInterval(1_200))
        await store.refreshDueProviders()
        XCTAssertEqual([claude.refreshCount, codex.refreshCount], [2, 4])
        XCTAssertNil(store.stalenessHint(for: "claude@account"))
    }

    func testRefreshSettingPostsChangeNotificationOnlyOnActualChangeAndReset() {
        let suite = makeDefaults("notifications")
        let runtime = makeRuntime(id: "claude", used: 20)
        let store = WidgetDataStore(
            registry: .from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite), defaults: suite
        )
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: RefreshSetting.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notifications.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.refreshSetting.setMinutes(10, for: "claude")
        XCTAssertEqual(notifications.withLock { $0 }, 0)

        store.refreshSetting.setMinutes(5, for: "claude")
        XCTAssertEqual(notifications.withLock { $0 }, 0)

        store.refreshSetting.setMinutes(30, for: "claude")
        XCTAssertEqual(notifications.withLock { $0 }, 1)

        store.refreshSetting = RefreshSetting()
        XCTAssertEqual(notifications.withLock { $0 }, 2)
        XCTAssertEqual(store.refreshSetting.minutes(for: "claude"), 10)
        XCTAssertEqual(store.refreshSetting.minutes(for: "codex"), 5)
    }

    func testFailedClaudeWaitsItsIntervalAcrossWakesAndManualRefreshMovesItsDeadline() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(start)
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let claude = CountingProviderRuntime(provider: provider, descriptors: [],
                                             snapshot: .error(provider: provider, message: "Unavailable"))
        let suite = makeDefaults("failed")
        let enablement = ProviderEnablementStore(defaults: suite)
        let store = WidgetDataStore(
            registry: .from([claude]), providers: [claude],
            cache: ProviderSnapshotCache(userDefaults: suite, now: { clock.now }),
            defaults: suite, isProviderEnabled: { enablement.isEnabled($0) }, now: { clock.now }
        )
        enablement.onProviderEnabled = { store.clearFailureBackoff(for: $0) }
        await store.refreshDueProviders()
        enablement.setEnabled(false, for: "claude")
        XCTAssertNil(store.nextAutomaticRefreshAt)
        clock.set(start.addingTimeInterval(300))
        enablement.setEnabled(true, for: "claude")
        await store.refreshDueProviders()
        XCTAssertEqual(claude.refreshCount, 1)
        XCTAssertEqual(store.nextAutomaticRefreshAt, start.addingTimeInterval(600))

        await store.refreshOnUserRequest(providerID: "claude")
        XCTAssertEqual(claude.refreshCount, 2)
        XCTAssertEqual(store.nextAutomaticRefreshAt, start.addingTimeInterval(900))
        clock.set(start.addingTimeInterval(900))
        await store.refreshDueProviders()
        XCTAssertEqual(claude.refreshCount, 3)
    }

    // MARK: - Session-scoped freshness

    func testRelaunchRefetchesEvenWithinIntervalButPaintsCachedValueFirst() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-within")

        // A prior session left a snapshot 4 minutes ago — inside the 5-minute interval.
        storeSnapshot(used: 20, age: 240, into: suite, now: now)

        // A fresh store/cache (= relaunch) loads it from disk for instant paint…
        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))

        // …but a disk-loaded snapshot never gates the refresh, so the first pass refetches (#697) even
        // though the snapshot is still within the interval.
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 80, limit: 100, format: .percent))
    }

    func testWithinSessionPassServedFromCacheUntilInterval() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("within-session")

        // One cache instance shared between the seeding write and the store models a single running
        // session: the snapshot was fetched 4 minutes ago *this* session, so it short-circuits the pass.
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-240)
        ))

        let runtime = makeRuntime(used: 80)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: cache,
            defaults: suite
        )
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0) // fetched this session, within interval => no refetch
        XCTAssertNotNil(store.snapshots["test"])

        now = now.addingTimeInterval(61)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1, "the same-session cache expires after the refresh interval")
    }

    // MARK: - Helpers

    private func storeSnapshot(used: Double, age: TimeInterval, into suite: UserDefaults, now: Date) {
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-age)
        ))
    }

    private func makeRuntime(id: String = "test", used: Double) -> CountingProviderRuntime {
        let provider = Provider(id: id, displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "\(id).session",
            providerID: id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: used, limit: 100)
        )
        return CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: id,
                displayName: "Test",
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
                refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }

    /// Builds a new store and cache over the same defaults to model a relaunch.
    private func makeStore(runtime: CountingProviderRuntime, suite: UserDefaults, now: Date) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now }),
            defaults: suite
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.RefreshSetting.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

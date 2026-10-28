import XCTest
@testable import OpenUsage

private func historyBody(_ json: String) -> Data { Data(json.utf8) }

private func historyResponse(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: historyBody(json))
}

/// Same shape as the live daily endpoint; values are synthetic. The nested totals and per-model
/// counts must not be added to the already aggregated daily series.
private let dailyHistory = #"""
{"code":200,"success":true,"data":{
  "granularity":"daily",
  "x_time":["2026-09-27","2026-09-28","2026-10-27","2026-10-28","2026-10-29"],
  "tokensUsage":[9000,100000,200000,300000,9000],
  "totalUsage":{"totalTokensUsage":618000},
  "modelDataList":[{"modelName":"GLM-5.3","tokensUsage":[9000,100000,200000,300000,9000]}]
}}
"""#

private let historyPricing = ModelPricing(
    supplement: PricingSupplement(pricing: [
        "glm-5.3": ModelRates(inputPerMillion: 1.4, outputPerMillion: 4.4,
                             cacheWritePerMillion: 1.4, cacheReadPerMillion: 0.26,
                             inputAbove200kPerMillion: 99)
    ]),
    primary: PricingCatalog(), secondary: PricingCatalog()
)

final class ZAIUsageHistoryMapperTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))! }

    func testDailySeriesUsesAggregateTokensWithoutInventingCostAndClipsWindow() throws {
        let series = try ZAIUsageHistoryMapper.map(historyBody(dailyHistory), now: now, calendar: calendar)
        XCTAssertEqual(series.daily.map(\.date), ["2026-09-28", "2026-10-27", "2026-10-28"])
        XCTAssertEqual(series.daily.map(\.totalTokens), [100_000, 200_000, 300_000])
        XCTAssertTrue(series.daily.allSatisfy { $0.costUSD == nil })
    }

    func testInvalidHistoriesFailInsteadOfShowingZeroOrPartialTotals() {
        let invalid = [
            "not-json", "{}", #"{"success":false,"data":{"x_time":[],"tokensUsage":[]}}"#,
            #"{"data":{"x_time":["2026-10-28"],"tokensUsage":[]}}"#,
            #"{"data":{"x_time":["2026-10-28"],"tokensUsage":[null]}}"#,
            #"{"data":{"x_time":["2026-10-28"],"tokensUsage":[true]}}"#,
            #"{"data":{"x_time":["2026-10-28"],"tokensUsage":[-1]}}"#,
            #"{"data":{"x_time":["2026-10-28"],"tokensUsage":[1.5]}}"#,
            #"{"data":{"x_time":["2026-10-28"],"tokensUsage":[1e30]}}"#,
            #"{"data":{"x_time":["2026-10-28","2026-10-27"],"tokensUsage":[9e18,9e18]}}"#,
            #"{"data":{"x_time":["2026-10-28","2026-10-28"],"tokensUsage":[1,2]}}"#,
            #"{"data":{"x_time":["2026-02-30"],"tokensUsage":[1]}}"#,
            #"{"data":{"x_time":["2026-10-28 12:00"],"tokensUsage":[1]}}"#,
            #"{"data":{"granularity":"hourly","x_time":[],"tokensUsage":[]}}"#
        ]
        for json in invalid {
            XCTAssertThrowsError(try ZAIUsageHistoryMapper.map(historyBody(json), now: now, calendar: calendar), json) {
                XCTAssertEqual($0 as? ZAIUsageError, .invalidResponse)
            }
        }
    }

    func testApprovedGLMInputApproximationUsesSharedRatesWithoutDailyLongContextSurcharge() throws {
        let series = try ZAIUsageHistoryMapper.map(
            historyBody(dailyHistory), now: now, calendar: calendar, pricing: historyPricing
        )
        for (entry, expected) in zip(series.daily, [0.14, 0.28, 0.42]) {
            XCTAssertEqual(try XCTUnwrap(entry.costUSD), expected, accuracy: 0.000001)
        }
    }

    func testExplicitEmptyAndIdleSeriesAreValidWithoutFabricatedSpend() throws {
        for json in [
            #"{"data":{"x_time":[],"tokensUsage":[]}}"#,
            #"{"data":{"x_time":["2026-10-28"],"tokensUsage":[0]}}"#
        ] {
            let series = try ZAIUsageHistoryMapper.map(historyBody(json), now: now, calendar: calendar)
            var lines: [MetricLine] = []
            SpendTileMapper.appendTokenUsage(series, to: &lines, now: now, estimated: false)
            XCTAssertTrue(lines.isEmpty)
        }
    }
}

@MainActor
final class ZAIUsageHistoryProviderTests: XCTestCase {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))! }

    func testRefreshAddsAllThreeTokenRowsAndKeepsQuotaMeters() async throws {
        let snapshot = await provider(history: { historyResponse(dailyHistory) }).refresh()
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertEqual(snapshot.refreshedAt, now)
        for (label, expected) in [("Today", 300_000.0), ("Yesterday", 200_000.0), ("Last 30 Days", 600_000.0)] {
            guard case .values(_, let values, _, _, _, _) = snapshot.line(label: label) else {
                return XCTFail("Missing \(label)")
            }
            XCTAssertEqual(values.count, 2)
            let tokens = try XCTUnwrap(values.first { $0.kind == .count })
            let cost = try XCTUnwrap(values.first { $0.kind == .dollars })
            XCTAssertEqual(tokens.number, expected)
            XCTAssertEqual(tokens.label, "tokens")
            XCTAssertFalse(tokens.estimated)
            XCTAssertEqual(cost.number, expected * 1.4 / 1_000_000, accuracy: 0.000001)
            XCTAssertTrue(cost.estimated)
        }
        XCTAssertNil(snapshot.usageHistory, "Account totals must not enter machine-local history sync")
    }

    func testHistoryFailuresWarnWithoutHidingQuotaMeters() async {
        let responses = [
            historyResponse("{}", status: 401), historyResponse("{}", status: 403),
            historyResponse("{}", status: 500), historyResponse("{}"),
            historyResponse(#"{"success":false,"data":{"x_time":[],"tokensUsage":[]}}"#)
        ]
        for response in responses {
            let snapshot = await provider(history: { response }).refresh()
            XCTAssertNotNil(snapshot.line(label: "Session"))
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertTrue(snapshot.warning?.hasPrefix("Couldn't load Z.ai usage history.") == true)
            XCTAssertNil(snapshot.line(label: "Today"))
            XCTAssertNil(snapshot.line(label: "Last 30 Days"))
        }
        let snapshot = await provider(history: { throw URLError(.notConnectedToInternet) }).refresh()
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.warning)
    }

    func testRegisteredZAIHistoryFeedsTopChartAndKeepsEstimateExplanation() async throws {
        let runtime = provider(history: { historyResponse(dailyHistory) })
        let registry = WidgetRegistry.from([runtime])
        let suite = "ZAITotalChartTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        let store = WidgetDataStore(registry: registry, providers: [runtime],
                                   cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults)
        await store.refreshAll()
        XCTAssertEqual(layout.spendCapableProviders.map(\.id), ["zai"])
        for (period, expected) in [(TotalSpendPeriod.today, 300_000.0), (.yesterday, 200_000.0), (.last30, 600_000.0)] {
            let total = TotalSpendAggregator.total(for: period, providers: layout.spendCapableProviders,
                                                  snapshots: store.snapshots)
            XCTAssertEqual(total.projection(for: .tokens).slices.map(\.id), ["zai"])
            XCTAssertEqual(total.projection(for: .tokens).centerValue, expected)
            XCTAssertFalse(total.projection(for: .tokens).isEstimated)
            XCTAssertEqual(total.projection(for: .cost).centerValue, expected * 1.4 / 1_000_000, accuracy: 0.000001)
            XCTAssertEqual(total.projection(for: .costPerMtok).centerValue, 1.4, accuracy: 0.000001)
            XCTAssertTrue(total.projection(for: .cost).isEstimated)
        }
        let descriptor = try XCTUnwrap(registry.descriptor(id: "zai.last30"))
        XCTAssertEqual(store.data(for: descriptor).infoNote, ZAIProvider.costEstimateNote)
        XCTAssertTrue(store.data(for: descriptor).unboundedValueTooltip?.contains("GLM-5.3 input") == true)
        for id in ["zai.today", "zai.yesterday", "zai.last30"] { layout.setMetricEnabled(id, false) }
        XCTAssertEqual(layout.spendCapableProviders.map(\.id), ["zai"], "Hiding rows must not drop chart totals")
        XCTAssertNil(registry.historyDescriptorsByProvider["zai"], "Account totals are not machine-local sync data")
    }

    func testMissingPricingKeepsZAIInTokensChartAndWarnsWithoutInventingCost() async throws {
        let runtime = provider(pricing: .empty, history: { historyResponse(dailyHistory) })
        let snapshot = await runtime.refresh()
        XCTAssertEqual(snapshot.warning, "GLM-5.3 pricing unavailable. Showing Z.ai tokens only.")
        let total = TotalSpendAggregator.total(for: .last30, providers: [runtime.provider], snapshots: ["zai": snapshot])
        XCTAssertEqual(total.projection(for: .tokens).centerValue, 600_000)
        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testHistoryReplacesNoDataBadgeWhenQuotasAreEmpty() async {
        let snapshot = await provider(quota: #"{"data":{"limits":[]}}"#,
                                      history: { historyResponse(dailyHistory) }).refresh()
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Status"))
    }

    func testClientRequestsCalendarMonthWindowAcrossDSTWithExistingAuthentication() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0, minute: 5))!
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.host, "api.z.ai")
            XCTAssertEqual(request.url.path, ZAIUsageClient.modelUsageURL.path)
            XCTAssertEqual(request.headers["Authorization"], "Bearer test-zai-key")
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "startTime" }?.value, "2026-10-03 00:00:00")
            XCTAssertEqual(items.first { $0.name == "endTime" }?.value, "2026-11-02 00:05:00")
            return historyResponse(dailyHistory)
        }
        _ = try await ZAIUsageClient(http: http).fetchModelUsage(apiKey: "test-zai-key", now: date, calendar: calendar)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testApprovedDefaultsSeedOnDemandOnFreshAndExistingLayoutsWithoutChangingPins() throws {
        let provider = ZAIProvider()
        let registry = WidgetRegistry(providers: [provider.provider], descriptors: provider.widgetDescriptors)
        for existing in [false, true] {
            let suite = "ZAIUsageHistoryTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if existing {
                let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
                persistence.savePlaced([PlacedWidget(descriptorID: "zai.session")])
                persistence.saveSeededDefaults(["zai.session", "zai.weekly", "zai.webSearches"])
                persistence.savePins(["zai.session"])
            }
            let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
            let historyIDs = ["zai.today", "zai.yesterday", "zai.last30"]
            XCTAssertEqual(Array(store.orderedSupportedMetrics(for: "zai").map(\.id).suffix(4)),
                           ["zai.webSearches"] + historyIDs)
            for id in historyIDs {
                XCTAssertTrue(store.isMetricEnabled(id))
                XCTAssertTrue(store.expandedMetricIDs.contains(id))
                XCTAssertFalse(store.isPinned(id))
            }
            XCTAssertFalse(store.expandedMetricIDs.contains("zai.session"))
            XCTAssertEqual(store.spendCapableProviders.map(\.id), ["zai"])
            if existing {
                XCTAssertEqual(store.pinnedMetricIDs, ["zai.session"])
                XCTAssertFalse(store.isMetricEnabled("zai.weekly"), "Preserve previous opt-outs")
            }
            store.setMetricEnabled("zai.today", false)
            let reloaded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
            XCTAssertFalse(reloaded.isMetricEnabled("zai.today"), "Seed once, then respect customization")
        }
    }

    private func provider(
        quota: String = #"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":25}]}}"#,
        pricing: ModelPricing = historyPricing,
        history: @escaping @Sendable () async throws -> HTTPResponse
    ) -> ZAIProvider {
        let date = now
        return ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "test-zai-key"])),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                switch request.url.path {
                case ZAIUsageClient.quotaURL.path: return historyResponse(quota)
                case ZAIUsageClient.subscriptionURL.path: return historyResponse(#"{"data":[]}"#)
                case ZAIUsageClient.modelUsageURL.path: return try await history()
                default: XCTFail("Unexpected endpoint"); return historyResponse("{}", status: 404)
                }
            }),
            now: { date },
            pricing: { pricing }
        )
    }
}

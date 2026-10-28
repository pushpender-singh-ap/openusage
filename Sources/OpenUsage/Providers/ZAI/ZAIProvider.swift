import Foundation

@MainActor
final class ZAIProvider: ProviderRuntime {
    let provider = Provider(
        id: "zai",
        displayName: "Z.ai",
        icon: .providerMark("zai"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://z.ai/manage-apikey/coding-plan/personal/my-plan"),
            ProviderLink(label: "API Keys", url: "https://z.ai/manage-apikey/apikey-list")
        ]
    )

    let authStore: ZAIAuthStore
    let usageClient: ZAIUsageClient
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    static let costEstimateNote = "Approximate API cost: all reported tokens are treated as GLM-5.3 input. "
        + "Input, output, and cached tokens are not separated. This is not your subscription bill."

    init(
        authStore: ZAIAuthStore = ZAIAuthStore(),
        usageClient: ZAIUsageClient = ZAIUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "zai.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "zai.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .boundedCount(id: "zai.webSearches", provider: provider, title: "Web Searches",
                          metricLabel: "Web Searches", limit: 1000, suffix: "searches",
                          periodDurationMs: ZAIUsageMapper.monthlyPeriodMs)
                .exportingLimit("webSearches", unit: "searches")
        ] + WidgetDescriptor.spendTiles(provider: provider, valueTooltipNote: Self.costEstimateNote)
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported API key.
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.missingKey)
        }

        // The quota endpoint is required; the subscription endpoint is best-effort (plan name only),
        // so a failure there must not blank out the meters. Both are fetched, and whatever the quota
        // returns is mapped alongside the plan name if the subscription succeeded.
        let quota = await load { try await usageClient.fetchQuota(apiKey: auth.apiKey) }
        let subscription = await loadOptional { try await usageClient.fetchSubscription(apiKey: auth.apiKey) }

        switch quota {
        case .success(let body):
            // A valid key whose account has no GLM Coding Plan gets a 2xx with `success:false`. Surface
            // that as a clear provider warning (the header's amber notice) rather than three blank "No
            // data" meters that don't explain why nothing's there.
            if ZAIUsageMapper.isNoCodingPlan(body) {
                return ProviderSnapshot.error(provider: provider, error: ZAIUsageError.noCodingPlan)
            }
            do {
                let mapped = try ZAIUsageMapper.map(quotaBody: body, subscriptionBody: subscription)
                let history = await loadHistory(apiKey: auth.apiKey, now: refreshedAt)
                var lines = mapped.lines
                if !history.lines.isEmpty {
                    lines.removeAll { $0 == .noUsageData }
                    lines += history.lines
                }
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: lines,
                                             refreshedAt: refreshedAt, warning: history.warning)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.invalidKey)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// History failure must explain the missing rows without hiding healthy quota meters.
    private func loadHistory(apiKey: String, now: Date) async -> (lines: [MetricLine], warning: String?) {
        let result = await load { try await usageClient.fetchModelUsage(apiKey: apiKey, now: now) }
        do {
            switch result {
            case .success(let body):
                let usage = try ZAIUsageHistoryMapper.map(body, now: now, pricing: await pricing())
                var lines: [MetricLine] = []
                SpendTileMapper.appendTokenUsage(usage, to: &lines, now: now, estimated: true)
                if usage.daily.contains(where: { $0.totalTokens > 0 && $0.costUSD == nil }) {
                    let warning = "GLM-5.3 pricing unavailable. Showing Z.ai tokens only."
                    AppLog.warn(LogTag.plugin("zai"), warning)
                    return (lines, warning)
                }
                return (lines, nil)
            case .authFailure:
                throw ZAIAuthError.invalidKey
            case .failed(let error):
                throw error
            }
        } catch {
            let warning = "Couldn't load Z.ai usage history. \(error.localizedDescription)"
            AppLog.warn(LogTag.plugin("zai"), warning)
            return ([], warning)
        }
    }

    /// Run a usage call and classify the outcome: the body on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx, transport error, or empty body.
    private func load(_ call: () async throws -> HTTPResponse) async -> UsageResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// Run the optional subscription call — never throws into the snapshot: a transport error, a
    /// non-2xx, or an auth failure all just mean "no plan name this refresh". Returns just the body
    /// (the only thing the mapper consumes); the outcome is otherwise discarded.
    private func loadOptional(_ call: () async throws -> HTTPResponse) async -> Data? {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else { return nil }
            return response.body
        } catch {
            return nil
        }
    }
}

extension ZAIProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum UsageResult {
    case success(Data)
    case authFailure
    case failed(ZAIUsageError)
}

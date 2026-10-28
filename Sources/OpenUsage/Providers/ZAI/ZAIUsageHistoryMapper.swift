import Foundation

/// Daily account usage from `/api/monitor/usage/model-usage`, verified against its daily response.
/// `tokensUsage` already sums all models: adding `modelDataList` or `totalUsage` would double-count.
/// There is no billed cost or input/output/cache breakdown. The owner-approved approximation treats
/// all reported tokens as GLM-5.3 input, using the shared pricing engine; it is not measured spend.
enum ZAIUsageHistoryMapper {
    static func map(
        _ body: Data, now: Date, calendar: Calendar = .current, pricing: ModelPricing = .empty
    ) throws -> DailyUsageSeries {
        guard let root = ProviderParse.jsonObject(body),
              ProviderParse.bool(root["success"]) != false,
              let data = root["data"] as? [String: Any],
              let dates = data["x_time"] as? [String],
              let counts = data["tokensUsage"] as? [Any],
              dates.count == counts.count,
              data["granularity"] == nil || data["granularity"] as? String == "daily" else {
            throw ZAIUsageError.invalidResponse
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let window = UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        var seen: Set<String> = []
        var entries: [DailyUsageEntry] = []
        var total = 0
        for (day, value) in zip(dates, counts) {
            guard let date = formatter.date(from: day), formatter.string(from: date) == day,
                  seen.insert(day).inserted,
                  let number = ProviderParse.number(value), let tokens = Int(exactly: number),
                  tokens >= 0 else {
                throw ZAIUsageError.invalidResponse
            }
            guard window.contains(day) else { continue }
            let sum = total.addingReportingOverflow(tokens)
            guard !sum.overflow else { throw ZAIUsageError.invalidResponse }
            total = sum.partialValue
            let cost = pricing.estimatedCostDollars(
                model: "glm-5.3", tokens: TokenBreakdown(input: tokens), applyLongContextRates: false
            )
            entries.append(DailyUsageEntry(date: day, totalTokens: tokens, costUSD: cost))
        }
        return DailyUsageSeries(daily: entries.sorted { $0.date < $1.date })
    }
}

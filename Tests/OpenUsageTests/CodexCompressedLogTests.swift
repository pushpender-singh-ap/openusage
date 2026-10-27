import Foundation
import XCTest
@testable import OpenUsage

final class CodexCompressedLogTests: XCTestCase {
    private let timestamp = "2026-10-15T12:00:00Z"
    private let now = OpenUsageISO8601.date(from: "2026-10-28T12:00:00Z")!

    private func record(input: Int = 100, timestamp: String = "2026-10-15T12:00:00Z") -> String {
        CodexLogFixture.tokenCount(
            timestamp: timestamp, last: CodexLogFixture.usage(input: input, output: 50), model: "gpt-5.2"
        )
    }

    func testMixedPlainAndCompressedRolloutsInBothDirectories() async throws {
        let home = try CodexLogFixture.makeHome(files: ["sessions/active.jsonl": record()])
        defer { try? FileManager.default.removeItem(at: home) }
        try ZstdLogFixture.write(record(input: 200), to: home.appendingPathComponent("sessions/2026/10/older.jsonl.zst"))
        try ZstdLogFixture.write(record(input: 300), to: home.appendingPathComponent("archived_sessions/oldest.jsonl.zst"))

        let files = JSONLScanning.jsonlFiles(under: home, includeCompressed: true)
        XCTAssertEqual(files.count, 3)
        // Other providers keep their plain-only discovery behavior.
        XCTAssertEqual(JSONLScanning.jsonlFiles(under: home).count, 1)
        let scan = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(scan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 750)
    }

    func testCompressedOnlyUsesRecordDatesEvenWithOldMtime() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try ZstdLogFixture.write(
            [record(input: 900, timestamp: "2026-02-01T12:00:00Z"), record()].joined(separator: "\n"),
            to: home.appendingPathComponent("sessions/older.jsonl.zst")
        )
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)

        let scan = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(scan?.series.daily.map(\.totalTokens), [150])
        XCTAssertEqual(scan?.series.daily.map(\.date), [DailyUsageAccumulator.dayKey(from: OpenUsageISO8601.date(from: timestamp)!)])
    }

    func testPlainWinsSameBasenameAcrossDirectoriesInEitherDirection() async throws {
        for (plain, compressed) in [
            ("sessions/x.jsonl", "sessions/x.jsonl.zst"),
            ("sessions/2026/10/x.jsonl", "archived_sessions/x.jsonl.zst"),
            ("archived_sessions/x.jsonl", "sessions/2026/10/x.jsonl.zst")
        ] {
            let home = try CodexLogFixture.makeHome(files: [plain: record()])
            defer { try? FileManager.default.removeItem(at: home) }
            // Different counts prove discovery chose the plain copy, rather than event-level dedup.
            try ZstdLogFixture.write(record(input: 900), to: home.appendingPathComponent(compressed))
            let scan = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: TestPricing.bundled)
            XCTAssertEqual(scan?.series.daily.map(\.totalTokens), [150], plain)
        }
    }

    func testCompressionReplacingCachedPlainFileDoesNotDoubleCount() async throws {
        let home = try CodexLogFixture.makeHome(files: ["sessions/x.jsonl": record()])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexLogFixture.scanner(home: home)
        let before = await scanner.scan(now: now, pricing: TestPricing.bundled)
        try ZstdLogFixture.write(record(), to: home.appendingPathComponent("sessions/x.jsonl.zst"))
        try FileManager.default.removeItem(at: home.appendingPathComponent("sessions/x.jsonl"))
        let after = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(before?.series.daily.map(\.totalTokens), [150])
        XCTAssertEqual(after?.series.daily.map(\.totalTokens), [150])
    }

    func testCompressedReplayAndPricingContextMatchPlainParser() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let usage = CodexLogFixture.usage(input: 100, cached: 20, output: 50, reasoning: 10)
        let lines = [
            CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
            ZstdLogFixture.usageRecord(timestamp: timestamp, usage: usage, thread: usage),
            CodexLogFixture.taskStarted(timestamp: timestamp, startedAt: Int(OpenUsageISO8601.date(from: timestamp)!.timeIntervalSince1970)),
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.2"),
            CodexLogFixture.threadSettingsApplied(timestamp: timestamp, serviceTier: "priority"),
            ZstdLogFixture.usageRecord(timestamp: timestamp, thread: CodexLogFixture.usage(input: 300, cached: 50, output: 90, reasoning: 20))
        ].joined(separator: "\n")
        let file = try ZstdLogFixture.write(lines, to: home.appendingPathComponent("sessions/child.jsonl.zst"))
        let parsed = try XCTUnwrap(CodexLogUsageScanner.tailParser.read(file.path, 0, nil, nil)?.items)
        XCTAssertEqual(parsed, CodexLogUsageScanner.parseFile(Data(lines.utf8)))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.input, 200)
        XCTAssertEqual(parsed.first?.cached, 30)
        XCTAssertEqual(parsed.first?.isFast, true)
        XCTAssertEqual(parsed.first?.model, "gpt-5.2")
    }

    func testTokenUsageShapesAndPairedTokenCountsDoNotDoubleCount() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let usage = CodexLogFixture.usage(input: 100, cached: 20, output: 50, reasoning: 10)
        let secondTotals = CodexLogFixture.usage(input: 200, cached: 40, output: 100, reasoning: 20)
        for reversed in [false, true] {
            let pair = [
                ZstdLogFixture.usageRecord(timestamp: timestamp, usage: usage, turn: usage, thread: usage),
                CodexLogFixture.tokenCount(timestamp: "2026-10-15T12:00:01Z", last: usage, totals: usage)
            ]
            let lines = (reversed ? Array(pair.reversed()) : pair) + [
                ZstdLogFixture.usageRecord(timestamp: "2026-10-15T12:01:00Z", thread: secondTotals)
            ]
            let file = try ZstdLogFixture.write(lines.joined(separator: "\n"), to: home.appendingPathComponent("test.jsonl.zst"))
            let events = try XCTUnwrap(CodexLogUsageScanner.tailParser.read(file.path, 0, nil, nil)?.items)
            XCTAssertEqual(events.map(\.input), [100, 100])
            XCTAssertEqual(events.map(\.total), [150, 150])
        }
    }

    func testUsageOnlyAndTurnOnlyRecordsAcrossBatches() {
        let usage = CodexLogFixture.usage(input: 100, output: 50)
        var parser = CodexLogFileParser()
        let first = parser.parse(Data(ZstdLogFixture.usageRecord(timestamp: timestamp, usage: usage, flattened: true).utf8))
        // Same timestamp/usage, but without shared totals: still one response across parser batches.
        let duplicate = parser.parse(Data(CodexLogFixture.tokenCount(timestamp: timestamp, last: usage).utf8))
        XCTAssertEqual(first.map(\.total), [150])
        XCTAssertTrue(duplicate.isEmpty)

        let lines = [
            ZstdLogFixture.usageRecord(timestamp: timestamp, turn: usage),
            ZstdLogFixture.usageRecord(timestamp: "2026-10-15T12:01:00Z", turn: CodexLogFixture.usage(input: 300, output: 100)),
            ZstdLogFixture.usageRecord(timestamp: "2026-10-15T12:02:00Z", turn: usage, turnID: "turn-2")
        ].joined(separator: "\n")
        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).map(\.total), [150, 250, 150])
    }

    func testGrowingTotalsKeepDistinctResponsesEvenWithMatchingTimestampAndUsage() {
        let usage = CodexLogFixture.usage(input: 100, output: 50)
        let lines = [
            ZstdLogFixture.usageRecord(timestamp: timestamp, usage: usage, thread: usage),
            CodexLogFixture.tokenCount(timestamp: timestamp, last: usage, totals: CodexLogFixture.usage(input: 200, output: 100))
        ].joined(separator: "\n")
        XCTAssertEqual(CodexLogUsageScanner.parseFile(Data(lines.utf8)).map(\.total), [150, 150])
    }

    /// Opt-in real-machine check. Reads rollouts only; all parse-cache writes stay in a temporary
    /// directory. Prints aggregate counts/timing, never conversation content or account credentials.
    func testRealLocalArchives() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENUSAGE_CODEX_ARCHIVE_PARITY"] == "1")
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("CodexArchiveParity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        let persistence = JSONLScanCachePersistence(namespace: "archive-parity", schemaVersion: 1, directory: cache)
        let incremental = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let scanner = CodexLogUsageScanner(incrementalScanner: incremental)
        let homes = CodexLogHomes(read: [home], cache: [home])
        let now = Date()
        let start = Date()
        let cold = await scanner.scan(homes: homes, now: now, pricing: TestPricing.bundled)
        let coldSeconds = Date().timeIntervalSince(start)
        await incremental.flushPendingWrites()
        let restarted = CodexLogUsageScanner(
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        )
        let restartStart = Date()
        let warm = await restarted.scan(homes: homes, now: now, pricing: TestPricing.bundled)
        let warmSeconds = Date().timeIntervalSince(restartStart)
        let total = try XCTUnwrap(cold).series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(warm?.series.daily.reduce(0) { $0 + $1.totalTokens }, total)
        XCTAssertGreaterThan(total, 0)
        print("ARCHIVE PARITY tokens=\(total) cold_seconds=\(coldSeconds) relaunched_seconds=\(warmSeconds)")
    }
}

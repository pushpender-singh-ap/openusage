import Foundation
import XCTest
@testable import OpenUsage

final class ZstdStreamingReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZstdStreamTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testLargeStreamMatchesPlainIncludingFinalUnterminatedRecord() throws {
        // Both compressed input and decompressed output cross many read-buffer boundaries.
        let content = (0..<20_000).map { "\($0) \(UUID())" }.joined(separator: "\n")
        let compressed = try ZstdLogFixture.compress(Data(content.utf8))
        XCTAssertGreaterThan(compressed.count, JSONLStreamingReader.readChunkBytes)
        let archive = directory.appendingPathComponent("events.jsonl.zst")
        try compressed.write(to: archive)
        let plain = directory.appendingPathComponent("events.jsonl")
        try Data(content.utf8).write(to: plain)
        let parser = JSONLTailParser<String>.stateless { data in
            data.split(separator: 10).map { String(decoding: $0, as: UTF8.self) }
        }
        let expected = try XCTUnwrap(parser.read(plain.path, 0, nil, nil))
        let actual = try XCTUnwrap(parser.read(archive.path, 0, nil, nil))
        XCTAssertEqual(actual.items, expected.items)
        XCTAssertEqual(actual.items?.count, 20_000)
        XCTAssertEqual(actual.parsedOffset, expected.parsedOffset)
        XCTAssertFalse(actual.endsAtLineBoundary)
    }

    func testConcatenatedFramesAndEmptyFrame() throws {
        let file = directory.appendingPathComponent("events.jsonl.zst")
        let frames = try ZstdLogFixture.compress(Data("1\n2".utf8))
            + ZstdLogFixture.compress(Data())
            + ZstdLogFixture.compress(Data("\n3\n".utf8))
        try frames.write(to: file)
        XCTAssertEqual(try intParser.read(file.path, 0, nil, nil)?.items, [1, 2, 3])
        try ZstdLogFixture.compress(Data()).write(to: file)
        XCTAssertEqual(try intParser.read(file.path, 0, nil, nil)?.items, [])
    }

    func testCorruptTruncatedAndEmptyFilesThrowInsteadOfReturningPartialUsage() throws {
        let valid = try ZstdLogFixture.compress(Data(String(repeating: "42\n", count: 50_000).utf8))
        let file = directory.appendingPathComponent("events.jsonl.zst")
        for bytes in [Data(), Data("not zstd".utf8), Data(valid.dropLast()), valid + Data([0, 1, 2])] {
            try bytes.write(to: file)
            XCTAssertThrowsError(try intParser.read(file.path, 0, nil, nil))
        }
    }

    func testOversizedRecordIsSkippedAndNextRecordSurvives() throws {
        let content = "1\n" + String(repeating: "x", count: JSONLStreamingReader.maximumRecordBytes + 1) + "\n2\n"
        let file = try ZstdLogFixture.write(content, to: directory.appendingPathComponent("events.jsonl.zst"))
        let result = try XCTUnwrap(intParser.read(file.path, 0, nil, nil))
        XCTAssertEqual(result.items, [1, 2])
        XCTAssertEqual(result.oversizedRecordCount, 1)
    }

    func testCancelledArchiveReadStopsBeforeParsing() async throws {
        let file = try ZstdLogFixture.write("1\n", to: directory.appendingPathComponent("events.jsonl.zst"))
        let parser = intParser
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try parser.read(file.path, 0, nil, nil)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled archive scan must not return events")
        } catch is CancellationError {
            // Expected; the scanner discards cancelled work instead of publishing partial history.
        }
    }

    func testArchiveCacheSurvivesMtimeWindowAndRelaunchButReparsesChangedSize() async throws {
        let file = try ZstdLogFixture.write("1\n", to: directory.appendingPathComponent("events.jsonl.zst"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
        let persistence = JSONLScanCachePersistence(namespace: "zstd-test", schemaVersion: 1, directory: directory.appendingPathComponent("cache"))
        let firstScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        let recorder = LogReadRecorder()
        let parser = recorder.parser(wrapping: intParser)
        let first = await firstScanner.items(from: discover(), since: Date(), tailParser: parser)
        XCTAssertEqual(first, [1])
        await firstScanner.flushPendingWrites()

        let cached = await firstScanner.items(from: discover(), since: .distantFuture, tailParser: parser)
        XCTAssertEqual(cached, [1])
        XCTAssertEqual(recorder.starts, [0])
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let relaunched = IncrementalJSONLScanner<Int>(persistence: persistence)
        let reloaded = await relaunched.items(from: discover(), since: Date(), tailParser: parser)
        XCTAssertEqual(reloaded, [1])
        XCTAssertEqual(recorder.starts, [0])

        // A changed archive is parsed from the beginning, never a decompressed tail offset.
        try ZstdLogFixture.write("2\n3\n", to: file)
        let changed = await relaunched.items(from: discover(), since: Date(), tailParser: parser)
        XCTAssertEqual(changed, [2, 3])
        XCTAssertEqual(recorder.starts, [0, 0])
        await relaunched.flushPendingWrites()
        let snapshot = try XCTUnwrap(JSONLScanCacheWriter().load(persistence: persistence, identity: "default", itemType: Int.self))
        let record = try XCTUnwrap(snapshot.files.values.first)
        XCTAssertEqual(record.items, [2, 3])
        XCTAssertNil(record.parsedOffset)
        XCTAssertNil(record.resumeState)
        XCTAssertNil(record.tailFingerprint)
    }

    func testArchiveCacheDoesNotInterfereWithPlainTailReads() async throws {
        let plain = directory.appendingPathComponent("active.jsonl")
        try Data("1\n".utf8).write(to: plain)
        try ZstdLogFixture.write("3\n", to: directory.appendingPathComponent("old.jsonl.zst"))
        let scanner = IncrementalJSONLScanner<Int>()
        let recorder = LogReadRecorder()
        let parser = recorder.parser(wrapping: intParser)
        let first = await scanner.items(from: discover(), since: .distantPast, tailParser: parser)
        XCTAssertEqual(first, [1, 3])
        let handle = try FileHandle(forWritingTo: plain)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("2\n".utf8))
        try handle.close()
        let second = await scanner.items(from: discover(), since: .distantPast, tailParser: parser)
        XCTAssertEqual(second, [1, 2, 3])
        XCTAssertEqual(recorder.starts.sorted(), [0, 0, 2])
    }

    func testUnreadableArchiveIsReportedAndRetriedWithoutCachingPartialEvents() async throws {
        let file = directory.appendingPathComponent("broken.jsonl.zst")
        try Data("broken".utf8).write(to: file)
        let warnings = WarningRecorder()
        let recorder = LogReadRecorder()
        let scanner = IncrementalJSONLScanner<Int>(readFailureWarning: { warnings.record($0) })
        let parser = recorder.parser(wrapping: intParser)
        for _ in 0..<2 {
            let result = await scanner.items(from: discover(), since: .distantPast, tailParser: parser)
            XCTAssertEqual(result, [])
        }
        XCTAssertEqual(warnings.counts, [1])
        XCTAssertEqual(recorder.starts, [0, 0])
        try ZstdLogFixture.write("42\n", to: file)
        let recovered = await scanner.items(from: discover(), since: .distantPast, tailParser: parser)
        XCTAssertEqual(recovered, [42])
    }

    private var intParser: JSONLTailParser<Int> {
        .stateless { data in data.split(separator: 10).compactMap { Int(String(decoding: $0, as: UTF8.self)) } }
    }

    private func discover() -> [JSONLScanning.DiscoveredFile] {
        JSONLScanning.jsonlFiles(under: directory, includeCompressed: true)
    }
}

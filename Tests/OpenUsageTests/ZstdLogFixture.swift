import Foundation
import XCTest
import libzstd
@testable import OpenUsage

enum ZstdLogFixture {
    static func compress(_ data: Data) throws -> Data {
        var compressed = Data(count: ZSTD_compressBound(data.count))
        let size = data.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                ZSTD_compress(destination.baseAddress, destination.count, source.baseAddress, source.count, 3)
            }
        }
        guard ZSTD_isError(size) == 0 else {
            throw ZstdStreamingReader.ReadError.invalidArchive(String(cString: ZSTD_getErrorName(size)))
        }
        return compressed.prefix(size)
    }

    @discardableResult
    static func write(_ content: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try compress(Data(content.utf8)).write(to: url)
        return url
    }

    static func usageRecord(
        timestamp: String, usage: [String: Int]? = nil, turn: [String: Int]? = nil,
        thread: [String: Int]? = nil, turnID: String = "turn-1", flattened: Bool = false
    ) -> String {
        var payload: [String: Any] = ["turn_id": turnID]
        if let usage { payload["usage"] = usage }
        if let turn { payload["turn_token_usage"] = turn }
        if let thread { payload["thread_token_usage"] = thread }
        var object: [String: Any] = ["type": "token_usage_record", "timestamp": timestamp]
        if flattened {
            object.merge(payload) { _, new in new }
        } else {
            object["payload"] = payload
        }
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }
}

final class LogReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [Int] = []
    var starts: [Int] { lock.withLock { offsets } }

    func parser<Item>(wrapping parser: JSONLTailParser<Item>) -> JSONLTailParser<Item> {
        JSONLTailParser(read: { [self] path, start, end, state in
            lock.withLock { offsets.append(start) }
            return try parser.read(path, start, end, state)
        })
    }
}

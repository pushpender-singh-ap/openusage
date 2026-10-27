import Foundation
import libzstd

/// A single-use, synchronous stream owned by one background parse task. Input and output buffers
/// are bounded independently of rollout size. No decompressed content is ever written to disk.
final class ZstdStreamingReader {
    private let handle: FileHandle
    private let context: OpaquePointer
    private var input = Data()
    private var inputPosition = 0
    private var inputEnded = false
    private var remaining = 1
    private var output = Data(count: JSONLStreamingReader.readChunkBytes)

    enum ReadError: LocalizedError {
        case allocationFailed
        case invalidArchive(String)
        case truncatedArchive

        var errorDescription: String? {
            switch self {
            case .allocationFailed: "Could not open compressed usage history."
            case .invalidArchive(let reason): "Could not decompress usage history: \(reason)."
            case .truncatedArchive: "Compressed usage history is incomplete."
            }
        }
    }

    init(path: String) throws {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        guard let context = ZSTD_createDStream() else {
            try? handle.close()
            throw ReadError.allocationFailed
        }
        self.context = context
    }

    deinit {
        ZSTD_freeDStream(context)
        try? handle.close()
    }

    func read() throws -> Data? {
        while true {
            try Task.checkCancellation()
            if inputPosition == input.count, !inputEnded {
                input = try handle.read(upToCount: JSONLStreamingReader.readChunkBytes) ?? Data()
                inputPosition = 0
                inputEnded = input.isEmpty
            }
            // Zero means the last frame was fully decoded. Continue reading to support concatenated
            // frames, but reject empty/truncated files and trailing corrupt data instead of caching
            // a silently partial set of events.
            if inputEnded, remaining == 0 { return nil }

            var produced = 0
            remaining = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    var sourceBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: inputPosition)
                    var destinationBuffer = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let result = ZSTD_decompressStream(context, &destinationBuffer, &sourceBuffer)
                    inputPosition = sourceBuffer.pos
                    produced = destinationBuffer.pos
                    return result
                }
            }
            guard ZSTD_isError(remaining) == 0 else {
                throw ReadError.invalidArchive(String(cString: ZSTD_getErrorName(remaining)))
            }
            if produced > 0 { return output.prefix(produced) }
            if inputEnded {
                guard remaining == 0 else { throw ReadError.truncatedArchive }
                return nil
            }
        }
    }
}

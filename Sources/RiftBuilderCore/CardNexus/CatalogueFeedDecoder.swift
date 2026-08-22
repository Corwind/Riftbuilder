import Compression
import Foundation

public protocol CatalogueFeedDecoding: Sendable {
    func decode(_ data: Data, encoding: String) -> AsyncThrowingStream<CardPrinting, any Error>
}

public struct AppleGzipCatalogueDecoder: CatalogueFeedDecoding, Sendable {
    private let maximumDecompressedBytes: Int

    public init(maximumDecompressedBytes: Int = 512 * 1_024 * 1_024) {
        self.maximumDecompressedBytes = maximumDecompressedBytes
    }

    public func decode(_ data: Data, encoding: String) -> AsyncThrowingStream<CardPrinting, any Error> {
        do {
            let normalizedEncoding = encoding.lowercased()
            let ndjson: Data
            switch normalizedEncoding {
            case "identity", "", "application/x-ndjson", "ndjson":
                ndjson = data
            case "gzip", "x-gzip", "application/gzip":
                ndjson = try Gzip.decompress(data, maximumOutputSize: maximumDecompressedBytes)
            default:
                throw CardNexusClientError.unsupportedCatalogueEncoding(encoding)
            }
            return NDJSONCatalogueParser.parse(ndjson)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }
}

public enum NDJSONCatalogueParser {
    public static func parse(_ data: Data) -> AsyncThrowingStream<CardPrinting, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var lineNumber = 0
                    for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
                        try Task.checkCancellation()
                        lineNumber += 1
                        let line = rawLine.last == 0x0D ? rawLine.dropLast() : rawLine[...]
                        guard !line.isEmpty else { continue }
                        do {
                            let record = try CardNexusCoding.decoder().decode(CatalogueProductDTO.self, from: Data(line))
                            if let printing = record.model { continuation.yield(printing) }
                        } catch {
                            throw CardNexusClientError.decoding(description: "catalogue line \(lineNumber): \(error)", requestID: nil)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private enum Gzip {
    static func decompress(_ input: Data, maximumOutputSize: Int) throws -> Data {
        let payload = try deflatePayload(in: input)
        guard payload.count <= Int(UInt32.max) else {
            throw CardNexusClientError.unsupportedCatalogueEncoding("gzip payload is too large")
        }

        let expectedSize = Int(input.suffix(4).enumerated().reduce(UInt32(0)) { result, item in
            result | (UInt32(item.element) << UInt32(item.offset * 8))
        })
        var capacity = max(64 * 1_024, expectedSize)
        capacity = min(capacity, maximumOutputSize)

        while capacity <= maximumOutputSize {
            var output = Data(count: capacity)
            let decodedSize = output.withUnsafeMutableBytes { outputBytes in
                payload.withUnsafeBytes { inputBytes in
                    compression_decode_buffer(
                        outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        inputBytes.bindMemory(to: UInt8.self).baseAddress!,
                        payload.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decodedSize > 0 {
                output.count = decodedSize
                if expectedSize != 0, decodedSize != expectedSize {
                    throw CardNexusClientError.unsupportedCatalogueEncoding("invalid gzip length")
                }
                return output
            }
            if capacity == maximumOutputSize { break }
            capacity = min(maximumOutputSize, capacity * 2)
        }
        throw CardNexusClientError.unsupportedCatalogueEncoding("invalid or oversized gzip stream")
    }

    private static func deflatePayload(in input: Data) throws -> Data {
        guard input.count >= 18, input[0] == 0x1f, input[1] == 0x8b, input[2] == 8 else {
            throw CardNexusClientError.unsupportedCatalogueEncoding("invalid gzip header")
        }
        let flags = input[3]
        guard flags & 0xE0 == 0 else {
            throw CardNexusClientError.unsupportedCatalogueEncoding("invalid gzip flags")
        }
        var index = 10

        if flags & 0x04 != 0 {
            guard index + 2 <= input.count - 8 else { throw CardNexusClientError.unsupportedCatalogueEncoding("truncated gzip header") }
            let length = Int(input[index]) | (Int(input[index + 1]) << 8)
            index += 2 + length
        }
        if flags & 0x08 != 0 { index = try skipZeroTerminatedField(in: input, from: index) }
        if flags & 0x10 != 0 { index = try skipZeroTerminatedField(in: input, from: index) }
        if flags & 0x02 != 0 { index += 2 }

        guard index <= input.count - 8 else {
            throw CardNexusClientError.unsupportedCatalogueEncoding("truncated gzip stream")
        }
        return input[index ..< input.count - 8]
    }

    private static func skipZeroTerminatedField(in input: Data, from start: Int) throws -> Int {
        var index = start
        while index < input.count - 8 {
            if input[index] == 0 { return index + 1 }
            index += 1
        }
        throw CardNexusClientError.unsupportedCatalogueEncoding("unterminated gzip header field")
    }
}

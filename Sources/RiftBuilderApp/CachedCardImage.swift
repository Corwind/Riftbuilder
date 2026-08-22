import AppKit
import CryptoKit
import Foundation
import SwiftUI

private enum CardImageCacheError: LocalizedError {
    case invalidResponse
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The card image server returned an invalid response."
        case .invalidImageData: "The downloaded card image could not be decoded."
        }
    }
}

actor CardImageCache {
    static let shared = CardImageCache()

    private let fileManager: FileManager
    private let directory: URL
    private let memoryCache = NSCache<NSURL, NSData>()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = base
            .appending(path: "RiftBuilder", directoryHint: .isDirectory)
            .appending(path: "CardArtwork", directoryHint: .isDirectory)
        memoryCache.totalCostLimit = 128 * 1_024 * 1_024
    }

    func data(for remoteURL: URL) async throws -> Data {
        let cacheKey = remoteURL as NSURL
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached as Data
        }

        let localURL = cachedFileURL(for: remoteURL)
        if let data = try? Data(contentsOf: localURL), !data.isEmpty {
            memoryCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
            return data
        }

        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw CardImageCacheError.invalidResponse
        }
        guard !data.isEmpty else { throw CardImageCacheError.invalidImageData }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
        memoryCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return data
    }

    private func cachedFileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: digest)
    }
}

struct CachedCardImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                guard let url else {
                    phase = .empty
                    return
                }

                phase = .empty
                do {
                    let data = try await CardImageCache.shared.data(for: url)
                    try Task.checkCancellation()
                    guard let image = NSImage(data: data) else {
                        throw CardImageCacheError.invalidImageData
                    }
                    phase = .success(Image(nsImage: image))
                } catch is CancellationError {
                    return
                } catch {
                    phase = .failure(error)
                }
            }
    }
}

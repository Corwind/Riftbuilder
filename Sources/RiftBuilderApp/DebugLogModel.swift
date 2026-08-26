import Foundation
import Observation
import RiftBuilderCore

struct DebugLogEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case request
        case response(statusCode: Int?)
    }

    let id: UUID
    let exchangeID: UUID
    let timestamp: Date
    let attempt: Int
    let method: String
    let path: String
    let kind: Kind
    let details: String

    var searchableText: String {
        let headline: String
        switch kind {
        case .request:
            headline = "REQUEST \(method) \(path)"
        case let .response(statusCode):
            headline = "RESPONSE \(statusCode.map(String.init) ?? "ERROR") \(method) \(path)"
        }
        let attemptText = attempt > 1 ? "Attempt \(attempt)\n" : ""
        return headline + "\n" + attemptText + details
    }
}

@MainActor
@Observable
final class DebugLogModel: CardNexusHTTPDebugLogging {
    private static let enabledDefaultsKey = "riftbuilder.debugMode.enabled"
    private static let maximumEntries = 1_000

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if !isEnabled {
                clear()
            }
        }
    }
    private(set) var entries: [DebugLogEntry] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var activeExchangeIDs: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    func isLoggingEnabled() async -> Bool {
        isEnabled
    }

    func record(_ event: CardNexusHTTPDebugEvent) async {
        guard isEnabled else { return }

        switch event {
        case let .request(request):
            activeExchangeIDs.insert(request.id)
            let query = request.queryItems.isEmpty
                ? "Query: <none>"
                : "Query:\n" + request.queryItems.map { item in
                    item.value.map { "\(item.name)=\($0)" } ?? item.name
                }.joined(separator: "\n")
            let payload = "Payload:\n" + (request.payload ?? "<none>")
            append(DebugLogEntry(
                id: UUID(),
                exchangeID: request.id,
                timestamp: request.timestamp,
                attempt: request.attempt,
                method: request.method,
                path: request.path,
                kind: .request,
                details: query + "\n\n" + payload
            ))
        case let .response(response):
            guard activeExchangeIDs.remove(response.id) != nil else { return }
            append(DebugLogEntry(
                id: UUID(),
                exchangeID: response.id,
                timestamp: response.timestamp,
                attempt: response.attempt,
                method: response.method,
                path: response.path,
                kind: .response(statusCode: response.statusCode),
                details: "Response:\n" + response.payload
            ))
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: isEnabled)
        activeExchangeIDs.removeAll()
    }

    private func append(_ entry: DebugLogEntry) {
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }
}

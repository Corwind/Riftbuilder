import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CardNexusHTTPDebugQueryItem: Hashable, Sendable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

public struct CardNexusHTTPDebugRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let attempt: Int
    public let method: String
    public let path: String
    public let queryItems: [CardNexusHTTPDebugQueryItem]
    public let payload: String?

    public init(id: UUID, timestamp: Date, attempt: Int, method: String, path: String, queryItems: [CardNexusHTTPDebugQueryItem], payload: String?) {
        self.id = id
        self.timestamp = timestamp
        self.attempt = attempt
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.payload = payload
    }
}

public struct CardNexusHTTPDebugResponse: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let attempt: Int
    public let method: String
    public let path: String
    public let statusCode: Int?
    public let payload: String

    public init(id: UUID, timestamp: Date, attempt: Int, method: String, path: String, statusCode: Int?, payload: String) {
        self.id = id
        self.timestamp = timestamp
        self.attempt = attempt
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.payload = payload
    }
}

public enum CardNexusHTTPDebugEvent: Hashable, Sendable {
    case request(CardNexusHTTPDebugRequest)
    case response(CardNexusHTTPDebugResponse)
}

public protocol CardNexusHTTPDebugLogging: Sendable {
    func isLoggingEnabled() async -> Bool
    func record(_ event: CardNexusHTTPDebugEvent) async
}

enum CardNexusHTTPDebugSanitizer {
    private static let maximumCapturedBodyBytes = 128 * 1_024
    private static let redacted = "<redacted>"

    static func request(_ request: URLRequest, id: UUID, attempt: Int) -> CardNexusHTTPDebugRequest {
        let secrets = credentialValues(in: request)
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let path = sanitize(components?.percentEncodedPath ?? request.url?.path ?? "<unknown path>", secrets: secrets)
        let queryItems = (components?.queryItems ?? []).map { item in
            CardNexusHTTPDebugQueryItem(
                name: item.name,
                value: isSensitiveField(item.name) ? redacted : item.value.map { sanitize($0, secrets: secrets) }
            )
        }
        return CardNexusHTTPDebugRequest(
            id: id,
            timestamp: Date(),
            attempt: attempt,
            method: request.httpMethod ?? "GET",
            path: path,
            queryItems: queryItems,
            payload: request.httpBody.map { printableBody($0, secrets: secrets, oversizedLabel: "request") }
        )
    }

    static func response(data: Data, response: HTTPURLResponse, for request: URLRequest, id: UUID, attempt: Int) -> CardNexusHTTPDebugResponse {
        let requestLog = self.request(request, id: id, attempt: attempt)
        return CardNexusHTTPDebugResponse(
            id: id,
            timestamp: Date(),
            attempt: attempt,
            method: requestLog.method,
            path: requestLog.path,
            statusCode: response.statusCode,
            payload: printableBody(data, secrets: credentialValues(in: request), oversizedLabel: "response")
        )
    }

    static func failure(_ error: any Error, for request: URLRequest, id: UUID, attempt: Int) -> CardNexusHTTPDebugResponse {
        let requestLog = self.request(request, id: id, attempt: attempt)
        return CardNexusHTTPDebugResponse(
            id: id,
            timestamp: Date(),
            attempt: attempt,
            method: requestLog.method,
            path: requestLog.path,
            statusCode: nil,
            payload: "Transport error: \(sanitize(error.localizedDescription, secrets: credentialValues(in: request)))"
        )
    }

    private static func printableBody(_ data: Data, secrets: [String], oversizedLabel: String) -> String {
        guard !data.isEmpty else { return "<empty>" }
        guard data.count <= maximumCapturedBodyBytes else {
            return "<\(oversizedLabel) body omitted: \(data.count.formatted()) bytes>"
        }

        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let formatted = try? JSONSerialization.data(withJSONObject: redactJSON(json, secrets: secrets), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let string = String(data: formatted, encoding: .utf8)
        {
            return string
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return "<binary body: \(data.count.formatted()) bytes>"
        }
        return sanitize(string, secrets: secrets)
    }

    private static func redactJSON(_ value: Any, secrets: [String]) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                result[item.key] = isSensitiveField(item.key) ? redacted : redactJSON(item.value, secrets: secrets)
            }
        }
        if let array = value as? [Any] {
            return array.map { redactJSON($0, secrets: secrets) }
        }
        if let string = value as? String {
            return sanitize(string, secrets: secrets)
        }
        return value
    }

    private static func credentialValues(in request: URLRequest) -> [String] {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization") else { return [] }
        let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? [parts[1]] : [authorization]
    }

    private static func sanitize(_ value: String, secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.reduce(value) { result, secret in
            result.replacingOccurrences(of: secret, with: redacted)
        }
    }

    private static func isSensitiveField(_ name: String) -> Bool {
        let normalized = name.lowercased().filter(\.isLetter)
        return normalized == "key"
            || normalized == "authorization"
            || normalized == "cookie"
            || normalized.hasSuffix("apikey")
            || normalized.hasSuffix("accesskey")
            || normalized.hasSuffix("privatekey")
            || normalized.hasSuffix("token")
            || normalized.hasSuffix("secret")
            || normalized.hasSuffix("password")
            || normalized.hasSuffix("signature")
            || normalized.contains("credential")
    }
}

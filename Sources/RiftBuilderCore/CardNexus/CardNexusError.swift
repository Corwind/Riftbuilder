import Foundation

public struct CardNexusAPIErrorEnvelope: Codable, Hashable, Sendable {
    public let code: String
    public let status: Int
    public let message: String
    public let data: [String: JSONValue]

    public init(code: String, status: Int, message: String, data: [String: JSONValue] = [:]) {
        self.code = code
        self.status = status
        self.message = message
        self.data = data
    }
}

public enum CardNexusClientError: Error, Hashable, Sendable {
    case missingCredential
    case invalidResponse
    case invalidURL
    case response(status: Int, requestID: String?, apiError: CardNexusAPIErrorEnvelope?)
    case decoding(description: String, requestID: String?)
    case unsupportedCatalogueEncoding(String)
}

extension CardNexusClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "No CardNexus API credential is configured."
        case .invalidResponse:
            return "CardNexus returned a non-HTTP response."
        case .invalidURL:
            return "A CardNexus request URL could not be constructed."
        case let .response(status, requestID, apiError):
            let detail = apiError.map { "\($0.code): \($0.message)" } ?? "HTTP \(status)"
            return requestID.map { "\(detail) (request \($0))" } ?? detail
        case let .decoding(description, requestID):
            return requestID.map { "Could not decode CardNexus response: \(description) (request \($0))" } ?? "Could not decode CardNexus response: \(description)"
        case let .unsupportedCatalogueEncoding(encoding):
            return "The catalogue feed encoding '\(encoding)' is not supported."
        }
    }
}

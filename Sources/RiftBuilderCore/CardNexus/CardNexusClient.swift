import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CardNexusClient: CardNexusServicing, CardNexusInventoryWriting, CardNexusInventoryLocationManaging, Sendable {
    public static let productionBaseURL = URL(string: "https://public-api.cardnexus.com/v1")!
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let credentialStore: any CredentialStoring
    private let retryPolicy: CardNexusRetryPolicy
    private let sleep: CardNexusSleep
    private let catalogueDecoder: any CatalogueFeedDecoding
    private let debugLogger: (any CardNexusHTTPDebugLogging)?

    public init(baseURL: URL = CardNexusClient.productionBaseURL, transport: any HTTPTransport = URLSessionTransport(), credentialStore: any CredentialStoring, retryPolicy: CardNexusRetryPolicy = .default, sleep: @escaping CardNexusSleep = CardNexusSleeps.continuousClock, catalogueDecoder: any CatalogueFeedDecoding = AppleGzipCatalogueDecoder(), debugLogger: (any CardNexusHTTPDebugLogging)? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.credentialStore = credentialStore
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.catalogueDecoder = catalogueDecoder
        self.debugLogger = debugLogger
    }

    public func verifyCredential() async throws { _ = try await fetchLocations() }

    public func fetchAllInventoryLines(game: String = "riftbound") async throws -> [InventoryLine] {
        var cursor: String?
        var result: [InventoryLine] = []
        repeat {
            try Task.checkCancellation()
            var queryItems = [URLQueryItem(name: "game", value: game), URLQueryItem(name: "limit", value: "100")]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page = try await decoded(InventoryPageDTO.self, from: authenticatedRequest(path: "inventory", queryItems: queryItems))
            result.append(contentsOf: page.data.map(\.model))
            cursor = page.pagination.nextCursor
        } while cursor != nil
        return result
    }

    public func fetchLocations() async throws -> [InventoryLocation] {
        try await decoded([InventoryLocationDTO].self, from: authenticatedRequest(path: "inventory/locations")).map(\.model)
    }

    public func fetchCatalogueMetadata(game: String = "riftbound") async throws -> CatalogueFeedMetadata {
        try await decoded(CatalogueFeedMetadataDTO.self, from: authenticatedRequest(path: "feeds/\(game)/catalog")).model
    }

    public func downloadCatalogue(from url: URL) async throws -> AsyncThrowingStream<CardPrinting, any Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/gzip, application/x-ndjson, application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding") ?? (url.pathExtension.lowercased() == "gz" ? "gzip" : "identity")
        return catalogueDecoder.decode(data, encoding: encoding)
    }

    public func upsertInventoryLocation(_ request: InventoryLocationUpsertRequest) async throws -> InventoryLocation {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw InventoryLocationUpsertValidationError.emptyName }
        guard name.count <= 100 else { throw InventoryLocationUpsertValidationError.nameTooLong }
        let dto = InventoryLocationUpsertDTO(name: name, color: request.color, icon: request.icon)
        var urlRequest = try authenticatedRequest(path: "inventory/locations")
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(dto)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decoded(InventoryLocationDTO.self, from: urlRequest).model
    }

    public func updateInventoryLocation(_ request: InventoryLocationUpdateRequest) async throws -> InventoryLocation {
        let currentName = request.currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentName.isEmpty, !name.isEmpty else { throw InventoryLocationUpsertValidationError.emptyName }
        guard name.count <= 100 else { throw InventoryLocationUpsertValidationError.nameTooLong }
        let dto = InventoryLocationUpdateDTO(name: name, color: request.color, icon: request.icon)
        var urlRequest = try authenticatedLocationRequest(name: currentName)
        urlRequest.httpMethod = "PATCH"
        urlRequest.httpBody = try JSONEncoder().encode(dto)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decoded(InventoryLocationDTO.self, from: urlRequest).model
    }

    public func deleteInventoryLocation(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InventoryLocationUpsertValidationError.emptyName }
        var request = try authenticatedLocationRequest(name: trimmed)
        request.httpMethod = "DELETE"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await decoded(InventoryLocationDeleteResponseDTO.self, from: request)
    }

    public func bulkMoveInventoryLines(_ request: InventoryBulkMoveRequest) async throws -> InventoryBulkMoveResponse {
        guard !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InventoryBulkMoveValidationError.emptyIdempotencyKey
        }
        guard (1 ... 200).contains(request.moves.count) else {
            throw InventoryBulkMoveValidationError.invalidItemCount(request.moves.count)
        }
        var seenIDs: Set<String> = []
        for (index, move) in request.moves.enumerated() {
            guard !move.inventoryID.isEmpty,
                  move.quantity > 0,
                  !move.destinationLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw InventoryBulkMoveValidationError.invalidMove(index: index) }
            guard seenIDs.insert(move.inventoryID).inserted else {
                throw InventoryBulkMoveValidationError.duplicateInventoryID(move.inventoryID)
            }
        }

        let body = InventoryBulkUpdateRequestDTO(items: request.moves.map {
            InventoryBulkUpdateItemDTO(inventoryId: $0.inventoryID, location: $0.destinationLocationName, count: $0.quantity)
        })
        var urlRequest = try authenticatedRequest(path: "inventory/bulk/update")
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        return try await decoded(InventoryBulkUpdateResponseDTO.self, from: urlRequest).model
    }

    private func authenticatedRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        try authenticatedRequest(url: baseURL.appending(path: path), queryItems: queryItems)
    }

    private func authenticatedLocationRequest(name: String) throws -> URLRequest {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { throw CardNexusClientError.invalidURL }
        let basePath = components.percentEncodedPath.hasSuffix("/") ? components.percentEncodedPath : components.percentEncodedPath + "/"
        components.percentEncodedPath = basePath + "inventory/locations/" + encodedName
        guard let url = components.url else { throw CardNexusClientError.invalidURL }
        return try authenticatedRequest(url: url)
    }

    private func authenticatedRequest(url: URL, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        guard let apiKey = try credentialStore.loadAPIKey(), !apiKey.isEmpty else { throw CardNexusClientError.missingCredential }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CardNexusClientError.invalidURL }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw CardNexusClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decoded<Value: Decodable>(_ type: Value.Type, from request: URLRequest) async throws -> Value {
        let (data, response) = try await perform(request)
        do { return try CardNexusCoding.decoder().decode(type, from: data) }
        catch { throw CardNexusClientError.decoding(description: String(describing: error), requestID: response.requestID) }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                let debugID = UUID()
                let shouldLog = await debugLogger?.isLoggingEnabled() == true
                if shouldLog {
                    await debugLogger?.record(.request(CardNexusHTTPDebugSanitizer.request(request, id: debugID, attempt: attempt)))
                }
                let data: Data
                let response: HTTPURLResponse
                do {
                    (data, response) = try await transport.execute(request)
                } catch {
                    if shouldLog {
                        await debugLogger?.record(.response(CardNexusHTTPDebugSanitizer.failure(error, for: request, id: debugID, attempt: attempt)))
                    }
                    throw error
                }
                if shouldLog {
                    await debugLogger?.record(.response(CardNexusHTTPDebugSanitizer.response(data: data, response: response, for: request, id: debugID, attempt: attempt)))
                }
                if (200 ..< 300).contains(response.statusCode) { return (data, response) }
                let transient = response.statusCode == 429 || (500 ... 599).contains(response.statusCode)
                if attempt < retryPolicy.maximumAttempts, transient {
                    let delay = retryDelay(response: response, attempt: attempt)
                    attempt += 1
                    try await sleep(delay)
                    continue
                }
                let envelope = try? CardNexusCoding.decoder().decode(CardNexusAPIErrorEnvelope.self, from: data)
                throw CardNexusClientError.response(status: response.statusCode, requestID: response.requestID, apiError: envelope)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CardNexusClientError {
                throw error
            } catch {
                if attempt < retryPolicy.maximumAttempts {
                    let delay = exponentialBackoff(attempt: attempt)
                    attempt += 1
                    try await sleep(delay)
                    continue
                }
                throw error
            }
        }
    }

    private func retryDelay(response: HTTPURLResponse, attempt: Int) -> Duration {
        if response.statusCode == 429, let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value), seconds >= 0 {
            return min(.milliseconds(Int64(seconds * 1_000)), retryPolicy.maximumRetryAfter)
        }
        return exponentialBackoff(attempt: attempt)
    }

    private func exponentialBackoff(attempt: Int) -> Duration {
        retryPolicy.initialBackoff * Int64(1 << min(attempt - 1, 20))
    }
}

public enum InventoryLocationUpsertValidationError: Error, Hashable, Sendable {
    case emptyName
    case nameTooLong
}

extension InventoryLocationUpsertValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyName: return "A CardNexus location name is required."
        case .nameTooLong: return "A CardNexus location name cannot exceed 100 characters."
        }
    }
}

private extension HTTPURLResponse {
    var requestID: String? { value(forHTTPHeaderField: "X-Request-Id") }
}

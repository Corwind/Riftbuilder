import Foundation
import LocalAuthentication
import Security

public struct CredentialAuthenticationError: Error, Hashable, Sendable, LocalizedError {
    public let operation: KeychainCredentialError.Operation
    public let message: String

    public init(operation: KeychainCredentialError.Operation, message: String) {
        self.operation = operation
        self.message = message
    }

    public var errorDescription: String? {
        "Could not authenticate to \(operation.rawValue) the CardNexus credential: \(message)"
    }
}

public struct KeychainCredentialError: Error, Hashable, Sendable, LocalizedError {
    public enum Operation: String, Hashable, Sendable {
        case load, save, delete, migrate
    }

    public let status: OSStatus
    public let operation: Operation

    public init(status: OSStatus, operation: Operation) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? {
        "Could not \(operation.rawValue) the CardNexus credential (Keychain status \(status))."
    }
}

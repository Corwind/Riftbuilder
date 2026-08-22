import Foundation
import LocalAuthentication
import Security

public final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    public let service: String
    public let account: String
    public let localizedReason: String
    public let authenticationReuseDuration: TimeInterval

    private let storageAccount: String
    private let authenticationContext: BiometricAuthenticationContext

    public init(
        service: String = "com.riftbuilder.cardnexus",
        account: String = "api-key",
        localizedReason: String = "Use Touch ID to access your CardNexus inventory.",
        authenticationReuseDuration: TimeInterval = 30
    ) {
        self.service = service
        self.account = account
        self.localizedReason = localizedReason
        self.authenticationReuseDuration = authenticationReuseDuration
        storageAccount = account + ".local-touch-id-v3"
        authenticationContext = BiometricAuthenticationContext(localizedReason: localizedReason, reuseDuration: authenticationReuseDuration)
    }

    public func loadAPIKey() throws -> String? {
        guard try itemExists(account: storageAccount) else { return nil }
        return try authenticationContext.withAuthentication(operation: .load) { _ in
            try read(account: storageAccount, operation: .load)
        }
    }

    public func saveAPIKey(_ key: String) throws {
        try authenticationContext.withAuthentication(operation: .save) { _ in
            try upsert(key, account: storageAccount, operation: .save)
        }
    }

    public func deleteAPIKey() throws {
        guard try itemExists(account: storageAccount) else { return }
        try authenticationContext.withAuthentication(operation: .delete) { _ in
            let status = SecItemDelete(query(account: storageAccount) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainCredentialError(status: status, operation: .delete)
            }
        }
    }

    private func read(account: String, operation: KeychainCredentialError.Operation) throws -> String? {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainCredentialError(status: status, operation: operation) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError(status: errSecDecode, operation: operation)
        }
        return value
    }

    private func upsert(_ key: String, account: String, operation: KeychainCredentialError.Operation) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainCredentialError(status: errSecParam, operation: operation)
        }

        let lookup = query(account: account)
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addition = lookup
            addition[kSecValueData as String] = data
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialError(status: addStatus, operation: operation)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw KeychainCredentialError(status: updateStatus, operation: operation)
        }
    }

    private func itemExists(account: String) throws -> Bool {
        var lookup = query(account: account)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainCredentialError(status: status, operation: .load)
        }
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private final class BiometricAuthenticationContext: @unchecked Sendable {
    private let lock = NSLock()
    private let context: LAContext
    private let localizedReason: String

    init(localizedReason: String, reuseDuration: TimeInterval) {
        self.localizedReason = localizedReason
        context = LAContext()
        context.localizedReason = localizedReason
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = max(0, reuseDuration)
    }

    func withAuthentication<Value>(operation: KeychainCredentialError.Operation, _ body: (LAContext) throws -> Value) throws -> Value {
        lock.lock()
        defer { lock.unlock() }

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            throw CredentialAuthenticationError(operation: operation, message: policyError?.localizedDescription ?? "Touch ID is unavailable or no fingerprint is enrolled.")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let outcome = BiometricAuthenticationOutcome()
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: localizedReason) { success, error in
            outcome.set(success: success, message: error?.localizedDescription)
            semaphore.signal()
        }
        semaphore.wait()

        let result = outcome.value
        guard result.success else {
            throw CredentialAuthenticationError(operation: operation, message: result.message ?? "Touch ID authentication was not completed.")
        }
        return try body(context)
    }
}

private final class BiometricAuthenticationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = (success: false, message: String?.none)

    func set(success: Bool, message: String?) {
        lock.lock()
        storedValue = (success, message)
        lock.unlock()
    }

    var value: (success: Bool, message: String?) {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

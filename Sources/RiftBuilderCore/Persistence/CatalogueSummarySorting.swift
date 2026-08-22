import Foundation

extension GRDBRiftBuilderRepository {
    static func stableUnique(_ values: [String]) -> [String] {
        var valuesByComparisonKey: [String: String] = [:]
        for value in values {
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if valuesByComparisonKey[key] == nil {
                valuesByComparisonKey[key] = value
            }
        }
        return valuesByComparisonKey.sorted { lhs, rhs in
            if lhs.key == rhs.key { return lhs.value < rhs.value }
            return lhs.key < rhs.key
        }.map(\.value)
    }
}

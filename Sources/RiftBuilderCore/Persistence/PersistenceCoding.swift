import Foundation

enum PersistenceCoding {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return result
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        try decoder.decode(type, from: Data(value.utf8))
    }

    static func date(_ value: Date) -> String {
        String(value.timeIntervalSince1970)
    }

    static func date(from value: String) -> Date {
        Date(timeIntervalSince1970: Double(value) ?? 0)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(for keys: [String]) -> String? {
        for key in keys {
            if case let .string(value)? = self[key] { return value }
        }
        return nil
    }

    func integer(for keys: [String]) -> Int? {
        for key in keys {
            switch self[key] {
            case let .number(value): return Int(value)
            case let .string(value): return Int(value)
            default: continue
            }
        }
        return nil
    }

    func strings(for keys: [String]) -> [String] {
        for key in keys {
            switch self[key] {
            case let .array(values):
                return values.compactMap { value in
                    if case let .string(string) = value { return string }
                    return nil
                }
            case let .string(value):
                return [value]
            default:
                continue
            }
        }
        return []
    }
}

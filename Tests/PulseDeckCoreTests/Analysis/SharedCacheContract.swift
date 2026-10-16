import CoreFoundation
import Foundation
@testable import PulseDeckCore

/// Evaluates the assertions used by the actual shared cache schema, without a second schema copy.
struct SharedCacheContract {
    struct Violation: Error, CustomStringConvertible {
        let description: String
    }

    private let schema: [String: Any]

    init() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/cache_schema_v1.json"))
        guard let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Violation(description: "Shared schema is not an object")
        }
        self.schema = schema
    }

    func validate(entry: TrackCacheEntry) throws {
        let cache = PulseDeckLibraryCache(tracks: [entry.relativePath: entry])
        try validate(data: JSONEncoder().encode(cache))
    }

    func validate(data: Data) throws {
        try validate(try JSONSerialization.jsonObject(with: data), against: schema, path: "$")
    }

    private func validate(_ value: Any, against rule: [String: Any], path: String) throws {
        let supported: Set<String> = ["$schema", "$defs", "$ref", "title", "description", "type", "required",
                                      "properties", "additionalProperties", "items", "minimum", "maximum",
                                      "exclusiveMinimum", "format"]
        guard Set(rule.keys).isSubset(of: supported) else {
            throw Violation(description: "\(path): schema gained an unsupported assertion")
        }
        if let reference = rule["$ref"] as? String {
            guard reference.hasPrefix("#/") else { throw Violation(description: "Unsupported schema reference") }
            var target: Any = schema
            for token in reference.dropFirst(2).split(separator: "/") {
                let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let next = (target as? [String: Any])?[key] else {
                    throw Violation(description: "Missing schema reference \(reference)")
                }
                target = next
            }
            guard let targetRule = target as? [String: Any] else { throw Violation(description: "Invalid schema reference") }
            try validate(value, against: targetRule, path: path)
        }
        let types = (rule["type"] as? [String]) ?? (rule["type"] as? String).map { [$0] } ?? []
        guard types.isEmpty || types.contains(where: { matches(value, type: $0) }) else {
            throw Violation(description: "\(path): expected \(types)")
        }
        if let object = value as? [String: Any] {
            for key in rule["required"] as? [String] ?? [] where object[key] == nil {
                throw Violation(description: "\(path): missing \(key)")
            }
            let properties = rule["properties"] as? [String: [String: Any]] ?? [:]
            for (key, child) in object {
                if let childRule = properties[key] ?? rule["additionalProperties"] as? [String: Any] {
                    try validate(child, against: childRule, path: "\(path).\(key)")
                }
            }
        }
        if let array = value as? [Any], let itemRule = rule["items"] as? [String: Any] {
            for (index, item) in array.enumerated() {
                try validate(item, against: itemRule, path: "\(path)[\(index)]")
            }
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let numeric = number.doubleValue
            guard numeric.isFinite else { throw Violation(description: "\(path): nonfinite number") }
            if let minimum = rule["minimum"] as? NSNumber, numeric < minimum.doubleValue {
                throw Violation(description: "\(path): below minimum \(minimum)")
            }
            if let maximum = rule["maximum"] as? NSNumber, numeric > maximum.doubleValue {
                throw Violation(description: "\(path): above maximum \(maximum)")
            }
            if let minimum = rule["exclusiveMinimum"] as? NSNumber, numeric <= minimum.doubleValue {
                throw Violation(description: "\(path): must exceed \(minimum)")
            }
        }
        if let text = value as? String, rule["format"] as? String == "date-time",
           ISO8601DateFormatter().date(from: text) == nil {
            throw Violation(description: "\(path): invalid ISO 8601 timestamp")
        }
    }

    private func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "null": return value is NSNull
        case "boolean": return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "number", "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let numeric = number.doubleValue
            return numeric.isFinite && (type == "number" || numeric.rounded() == numeric)
        default: return false
        }
    }
}

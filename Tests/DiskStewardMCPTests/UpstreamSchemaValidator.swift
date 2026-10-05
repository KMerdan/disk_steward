import CoreFoundation
import Foundation

/// TASK-714: validates helper responses against the vendored upstream MCP
/// schemas (Fixtures/MCP/upstream). It covers the JSON Schema 2020-12 keywords
/// those files use for results and errors: local `$ref`, `allOf`, `anyOf`,
/// `oneOf`, `type`, `const`, `enum`, `required`, `properties`,
/// `additionalProperties` (boolean or schema), `items`, and length and range
/// bounds. Annotation keywords are ignored.
struct UpstreamSchemaValidator {
    private let definitions: [String: Any]

    init(version: String) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appending(path: "Fixtures/MCP/upstream/schema-\(version).json"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        definitions = root["$defs"] as? [String: Any] ?? [:]
    }

    /// Errors validating `json` (a serialized JSON value) against `$defs/<definition>`.
    func validate(json: String, definition: String) -> [String] {
        guard let instance = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else { return ["not JSON"] }
        guard definitions[definition] != nil else { return ["no definition \(definition)"] }
        return validate(instance, schema: ["$ref": "#/$defs/\(definition)"], path: "$", depth: 0)
    }

    private func validate(_ instance: Any, schema: [String: Any], path: String, depth: Int) -> [String] {
        guard depth < 64 else { return ["\(path): schema nesting too deep"] }
        var errors: [String] = []
        if let reference = schema["$ref"] as? String {
            guard reference.hasPrefix("#/$defs/"), let target = definitions[String(reference.dropFirst("#/$defs/".count))] as? [String: Any] else {
                return ["\(path): unresolved \(reference)"]
            }
            errors += validate(instance, schema: target, path: path, depth: depth + 1)
        }
        for part in schema["allOf"] as? [[String: Any]] ?? [] {
            errors += validate(instance, schema: part, path: path, depth: depth + 1)
        }
        if let alternatives = schema["anyOf"] as? [[String: Any]],
           !alternatives.contains(where: { validate(instance, schema: $0, path: path, depth: depth + 1).isEmpty }) {
            errors.append("\(path): matches none of anyOf")
        }
        if let alternatives = schema["oneOf"] as? [[String: Any]] {
            let matches = alternatives.filter { validate(instance, schema: $0, path: path, depth: depth + 1).isEmpty }.count
            if matches != 1 { errors.append("\(path): matches \(matches) of oneOf") }
        }
        if let types = typeNames(schema), !types.contains(where: { matches(instance, type: $0) }) {
            return errors + ["\(path): expected \(types.joined(separator: " or "))"]
        }
        if let constant = schema["const"], !(instance as AnyObject).isEqual(constant) {
            errors.append("\(path): value does not match const")
        }
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { (instance as AnyObject).isEqual($0) }) {
            errors.append("\(path): value is not in enum")
        }
        if let object = instance as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path).\(key): required property is missing")
            }
            for (key, value) in object {
                if let property = properties[key] as? [String: Any] {
                    errors += validate(value, schema: property, path: "\(path).\(key)", depth: depth + 1)
                } else if schema["additionalProperties"] as? Bool == false {
                    errors.append("\(path).\(key): additional property is forbidden")
                } else if let additional = schema["additionalProperties"] as? [String: Any] {
                    errors += validate(value, schema: additional, path: "\(path).\(key)", depth: depth + 1)
                }
            }
        }
        if let array = instance as? [Any] {
            if let minimum = schema["minItems"] as? Int, array.count < minimum { errors.append("\(path): fewer than \(minimum) items") }
            if let maximum = schema["maxItems"] as? Int, array.count > maximum { errors.append("\(path): more than \(maximum) items") }
            if let items = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() { errors += validate(item, schema: items, path: "\(path)[\(index)]", depth: depth + 1) }
            }
        }
        if let string = instance as? String {
            if let minimum = schema["minLength"] as? Int, string.count < minimum { errors.append("\(path): shorter than \(minimum)") }
            if let maximum = schema["maxLength"] as? Int, string.count > maximum { errors.append("\(path): longer than \(maximum)") }
        }
        if isNumber(instance), let number = instance as? NSNumber {
            if let minimum = schema["minimum"] as? NSNumber, number.compare(minimum) == .orderedAscending { errors.append("\(path): below minimum") }
            if let maximum = schema["maximum"] as? NSNumber, number.compare(maximum) == .orderedDescending { errors.append("\(path): above maximum") }
        }
        return errors
    }

    private func typeNames(_ schema: [String: Any]) -> [String]? {
        if let type = schema["type"] as? String { return [type] }
        return schema["type"] as? [String]
    }

    private func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "integer": return isNumber(value) && (value as? NSNumber).map { $0.doubleValue.rounded() == $0.doubleValue } == true
        case "number": return isNumber(value)
        case "boolean": return isBoolean(value)
        case "null": return value is NSNull
        default: return true
        }
    }

    private func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func isNumber(_ value: Any) -> Bool { value is NSNumber && !isBoolean(value) }
}

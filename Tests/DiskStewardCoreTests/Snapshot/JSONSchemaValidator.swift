import CoreFoundation
import Foundation

struct SnapshotJSONSchemaValidator {
    func validate(instance: Any, schema: [String: Any], path: String = "$") -> [String] {
        var errors: [String] = []

        if let types = typeNames(in: schema), !types.contains(where: { matches(instance, type: $0) }) {
            return ["\(path): expected \(types.joined(separator: " or "))"]
        }
        if let constant = schema["const"], !jsonEqual(instance, constant) {
            errors.append("\(path): value does not match const")
        }
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { jsonEqual(instance, $0) }) {
            errors.append("\(path): value is not in enum")
        }
        if let object = instance as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path).\(key): required property is missing")
            }
            if schema["additionalProperties"] as? Bool == false {
                for key in object.keys where properties[key] == nil {
                    errors.append("\(path).\(key): additional property is forbidden")
                }
            }
            for (key, value) in object {
                if let propertySchema = properties[key] as? [String: Any] {
                    errors += validate(instance: value, schema: propertySchema, path: "\(path).\(key)")
                }
            }
        }
        if let array = instance as? [Any] {
            if let minimum = schema["minItems"] as? Int, array.count < minimum {
                errors.append("\(path): fewer than \(minimum) items")
            }
            if let itemSchema = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() {
                    errors += validate(instance: item, schema: itemSchema, path: "\(path)[\(index)]")
                }
            }
        }
        if let string = instance as? String {
            if let minimum = schema["minLength"] as? Int, string.count < minimum {
                errors.append("\(path): shorter than \(minimum) characters")
            }
            if let pattern = schema["pattern"] as? String,
               string.range(of: pattern, options: .regularExpression) == nil {
                errors.append("\(path): does not match pattern")
            }
        }
        if isNumber(instance), let number = instance as? NSNumber {
            if let minimum = schema["minimum"] as? NSNumber, number.compare(minimum) == .orderedAscending {
                errors.append("\(path): below minimum")
            }
        }
        return errors
    }

    static func loadSchema(named name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Schemas/\(name).schema.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func typeNames(in schema: [String: Any]) -> [String]? {
        if let type = schema["type"] as? String { return [type] }
        return schema["type"] as? [String]
    }

    private func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "integer":
            return isNumber(value) && (value as? NSNumber)?.doubleValue.rounded() == (value as? NSNumber)?.doubleValue
        case "number": return isNumber(value)
        case "boolean": return isBoolean(value)
        case "null": return value is NSNull
        default: return false
        }
    }

    private func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func isNumber(_ value: Any) -> Bool {
        value is NSNumber && !isBoolean(value)
    }

    private func jsonEqual(_ left: Any, _ right: Any) -> Bool {
        (left as AnyObject).isEqual(right)
    }
}

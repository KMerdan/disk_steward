#!/usr/bin/env swift

import Foundation

enum ConfigurationError: Error, CustomStringConvertible {
    case usage(String)
    case invalidRoot

    var description: String {
        switch self {
        case let .usage(message): message
        case .invalidRoot: "The JSON configuration root and mcpServers must be objects."
        }
    }
}

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else {
        throw ConfigurationError.usage("usage: json-config.swift set FILE COMMAND | remove FILE")
    }
    let operation = arguments[0]
    let file = URL(fileURLWithPath: arguments[1])
    var root: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: file.path) {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        guard let object = value as? [String: Any] else { throw ConfigurationError.invalidRoot }
        root = object
    }
    var servers: [String: Any]
    if let existing = root["mcpServers"] {
        guard let object = existing as? [String: Any] else { throw ConfigurationError.invalidRoot }
        servers = object
    } else {
        servers = [:]
    }

    switch operation {
    case "set":
        guard arguments.count == 3 else {
            throw ConfigurationError.usage("set requires an executable path")
        }
        servers["disk_steward"] = [
            "type": "stdio",
            "command": arguments[2],
            "args": [],
            "env": [:],
        ]
    case "remove":
        guard arguments.count == 2 else { throw ConfigurationError.usage("remove accepts only a file") }
        servers.removeValue(forKey: "disk_steward")
    default:
        throw ConfigurationError.usage("unknown operation: \(operation)")
    }

    root["mcpServers"] = servers
    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).disk-steward-\(UUID().uuidString)")
    try data.write(to: temporary, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if FileManager.default.fileExists(atPath: file.path) {
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    } else {
        try FileManager.default.moveItem(at: temporary, to: file)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data(("json-config: \(error)\n").utf8))
    exit(64)
}

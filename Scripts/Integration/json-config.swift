#!/usr/bin/env swift

// Edits only the `disk_steward` entry of an MCP client's JSON configuration.
//
// Ownership rules (TASK-561):
//   - The root and `mcpServers` must be objects; anything else is refused and
//     the file is left untouched.
//   - `set` keeps every key the user added to an existing `disk_steward` entry
//     (env, cwd, unknown keys) and only refreshes type/command/args. A
//     malformed entry (non-string command, non-array args) is refused.
//   - `remove` refuses an entry that carries user additions; remove it by hand.
//   - Every write is check-and-swap: the new bytes are installed only if the
//     file still holds exactly the bytes that were read, otherwise nothing
//     changes and the other writer's file survives (exit 75).
//
// Exit codes: 0 done, 64 usage, 65 refused (malformed or user additions),
// 75 changed concurrently, 74 I/O failure.

import Foundation

enum ConfigurationError: Error, CustomStringConvertible {
    case usage(String)
    case invalidRoot
    case malformedEntry(String)
    case userAdditions([String])
    case concurrentEdit
    case concurrentEditUndoFailed(preserved: String, reason: String)
    case io(String)

    var description: String {
        switch self {
        case let .usage(message): message
        case .invalidRoot: "The JSON configuration root and mcpServers must be objects; nothing was changed."
        case let .malformedEntry(reason): "The existing disk_steward entry is malformed (\(reason)); nothing was changed. Fix or remove it by hand, then retry."
        case let .userAdditions(keys): "The disk_steward entry carries settings Disk Steward does not own (\(keys.joined(separator: ", "))); nothing was changed. Remove the entry by hand if you want it gone."
        case .concurrentEdit: "The file changed while it was being edited; nothing was changed. Retry."
        case let .concurrentEditUndoFailed(preserved, reason): "Another program changed the file while it was being edited and its version could not be put back (\(reason)). Disk Steward's version is in place; the other version is preserved at \(preserved). Merge them by hand."
        case let .io(reason): "Could not write the configuration (\(reason)); nothing was changed."
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: 64
        case .invalidRoot, .malformedEntry, .userAdditions: 65
        case .concurrentEdit: 75
        case .concurrentEditUndoFailed: 70
        case .io: 74
        }
    }
}

let ownedKeys: Set<String> = ["type", "command", "args"]

func userAdditions(in entry: [String: Any]) -> [String] {
    entry.keys.filter { key in
        if ownedKeys.contains(key) { return false }
        if key == "env", let env = entry[key] as? [String: Any], env.isEmpty { return false }
        if entry[key] is NSNull { return false }
        return true
    }.sorted()
}

func validate(_ entry: [String: Any]) throws {
    guard entry["command"] is String, !(entry["command"] as! String).isEmpty else { throw ConfigurationError.malformedEntry("command is not a non-empty string") }
    guard entry["args"] == nil || entry["args"] is [String] else { throw ConfigurationError.malformedEntry("args is not an array of strings") }
}

/// Installs `data` at `file` only if the file still holds `expected` (nil: the
/// file must not exist yet). Uses an atomic swap and verifies what came back.
func commit(_ data: Data, to file: URL, expecting expected: Data?) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".\(file.lastPathComponent).disk-steward-\(UUID().uuidString)")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw ConfigurationError.io(String(cString: strerror(errno))) }
    var committed = false
    defer { close(descriptor); if !committed { unlink(temporary.path) } }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ConfigurationError.io(String(cString: strerror(errno))) }
            offset += count
        }
    }
    guard fsync(descriptor) == 0 else { throw ConfigurationError.io("fsync failed") }
    guard let expected else {
        guard renamex_np(temporary.path, file.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ConfigurationError.concurrentEdit }
            throw ConfigurationError.io(String(cString: strerror(errno)))
        }
        committed = true
        return
    }
    guard renamex_np(temporary.path, file.path, UInt32(RENAME_SWAP)) == 0 else {
        if errno == ENOENT { throw ConfigurationError.concurrentEdit }
        throw ConfigurationError.io(String(cString: strerror(errno)))
    }
    let replaced = try? Data(contentsOf: temporary)
    if replaced != expected {
        guard renamex_np(temporary.path, file.path, UInt32(RENAME_SWAP)) == 0 else {
            // Never delete the other writer's bytes: keep them beside the file.
            committed = true
            let reason = String(cString: strerror(errno))
            let preserved = directory.appendingPathComponent(".\(file.lastPathComponent).concurrent-\(UUID().uuidString.lowercased())")
            let kept = renamex_np(temporary.path, preserved.path, UInt32(RENAME_EXCL)) == 0 ? preserved : temporary
            throw ConfigurationError.concurrentEditUndoFailed(preserved: kept.path, reason: reason)
        }
        throw ConfigurationError.concurrentEdit
    }
    committed = true
    unlink(temporary.path)
}

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else {
        throw ConfigurationError.usage("usage: json-config.swift set FILE COMMAND | remove FILE | inspect FILE")
    }
    let operation = arguments[0]
    let file = URL(fileURLWithPath: arguments[1])
    var original: Data? = nil
    var root: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: file.path) {
        let bytes = try Data(contentsOf: file)
        original = bytes
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ConfigurationError.invalidRoot }
        root = object
    }
    var servers: [String: Any]
    if let existing = root["mcpServers"] {
        guard let object = existing as? [String: Any] else { throw ConfigurationError.invalidRoot }
        servers = object
    } else {
        servers = [:]
    }
    let existingEntry: [String: Any]?
    if let raw = servers["disk_steward"] {
        guard let entry = raw as? [String: Any] else { throw ConfigurationError.malformedEntry("entry is not an object") }
        try validate(entry)
        existingEntry = entry
    } else {
        existingEntry = nil
    }

    switch operation {
    case "inspect":
        let additions = existingEntry.map(userAdditions) ?? []
        let report: [String: Any] = ["present": existingEntry != nil, "command": existingEntry?["command"] ?? NSNull(), "userAdditions": additions]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8) ?? "{}")
        return
    case "set":
        guard arguments.count == 3 else { throw ConfigurationError.usage("set requires an executable path") }
        var entry = existingEntry ?? ["env": [String: Any]()]
        entry["type"] = "stdio"
        entry["command"] = arguments[2]
        entry["args"] = existingEntry?["args"] as? [String] ?? []
        let preserved = existingEntry.map(userAdditions) ?? []
        servers["disk_steward"] = entry
        if !preserved.isEmpty { print("Preserved user settings on disk_steward: \(preserved.joined(separator: ", "))") }
    case "remove":
        guard arguments.count == 2 else { throw ConfigurationError.usage("remove accepts only a file") }
        guard let existingEntry else { return }
        let additions = userAdditions(in: existingEntry)
        guard additions.isEmpty else { throw ConfigurationError.userAdditions(additions) }
        servers.removeValue(forKey: "disk_steward")
    default:
        throw ConfigurationError.usage("unknown operation: \(operation)")
    }

    root["mcpServers"] = servers
    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try commit(data, to: file, expecting: original)
}

do {
    try run()
} catch let error as ConfigurationError {
    FileHandle.standardError.write(Data(("json-config: \(error)\n").utf8))
    exit(error.exitCode)
} catch {
    FileHandle.standardError.write(Data(("json-config: \(error)\n").utf8))
    exit(74)
}

import Darwin
import Foundation

public enum DirectoryEntryType: Sendable, Equatable {
    case file
    case directory
    case symlink
    case other
}

/// One entry of a directory, as the bounded review needs it: no contents, no
/// path, only what sizing, identity and activity require.
public struct DirectoryEntry: Sendable, Equatable {
    public let name: String
    public let type: DirectoryEntryType
    public let device: Int32
    public let fileID: UInt64
    public let linkCount: UInt32
    public let allocatedBytes: Int64
    /// Seconds since 1970.
    public let modified: TimeInterval

    public init(name: String, type: DirectoryEntryType, device: Int32, fileID: UInt64,
                linkCount: UInt32, allocatedBytes: Int64, modified: TimeInterval) {
        self.name = name
        self.type = type
        self.device = device
        self.fileID = fileID
        self.linkCount = linkCount
        self.allocatedBytes = allocatedBytes
        self.modified = modified
    }
}

public struct FileIdentity: Hashable, Sendable {
    public let device: Int32
    public let fileID: UInt64

    public init(device: Int32, fileID: UInt64) {
        self.device = device
        self.fileID = fileID
    }
}

public struct DirectoryListing: Sendable, Equatable {
    public let entries: [DirectoryEntry]
    /// Entries the file system returned with an error; skipped, not guessed.
    public let unreadableEntries: Int

    public init(entries: [DirectoryEntry], unreadableEntries: Int = 0) {
        self.entries = entries
        self.unreadableEntries = unreadableEntries
    }
}

public enum DirectoryReadError: Error, Equatable, Sendable {
    case unreadable(path: String, errno: Int32)
}

/// Reads one directory level. The default reads with `getattrlistbulk`;
/// tests substitute trees the file system cannot produce, such as cycles.
public protocol DirectoryReader: Sendable {
    func identity(of path: String) -> FileIdentity?
    func list(_ path: String) throws -> DirectoryListing
}

/// `getattrlistbulk`: name, type, device, file ID, link count, allocated size
/// and modification time for a whole directory per call, with no per-file
/// `stat` and no symlink ever followed.
public struct BulkDirectoryReader: DirectoryReader {
    private static let bufferBytes = 256 * 1_024
    // <sys/attr.h>; spelled out because several exceed Int32 in Swift.
    private static let commonAttributes: UInt32 = 0x8000_0000 /* RETURNED_ATTRS */ | 0x0000_0001 /* NAME */
        | 0x2000_0000 /* ERROR */ | 0x0000_0002 /* DEVID */ | 0x0000_0008 /* OBJTYPE */
        | 0x0000_0400 /* MODTIME */ | 0x0200_0000 /* FILEID */
    private static let fileAttributes: UInt32 = 0x0000_0001 /* LINKCOUNT */ | 0x0000_0004 /* ALLOCSIZE */
    private static let packInvalidAttributes: UInt64 = 0x0000_0008 // FSOPT_PACK_INVAL_ATTRS

    public init() {}

    public func identity(of path: String) -> FileIdentity? {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FileIdentity(device: status.st_dev, fileID: UInt64(status.st_ino))
    }

    public func list(_ path: String) throws -> DirectoryListing {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DirectoryReadError.unreadable(path: path, errno: errno) }
        defer { close(descriptor) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.commonAttributes
        request.fileattr = Self.fileAttributes
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferBytes, alignment: 8)
        defer { buffer.deallocate() }
        var entries: [DirectoryEntry] = []
        var unreadable = 0
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, Self.bufferBytes, Self.packInvalidAttributes)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DirectoryReadError.unreadable(path: path, errno: errno)
            }
            var cursor = UnsafeRawPointer(buffer)
            for _ in 0 ..< Int(count) {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                if let entry = Self.entry(at: cursor) { entries.append(entry) } else { unreadable += 1 }
                cursor += length
            }
        }
        return DirectoryListing(entries: entries, unreadableEntries: unreadable)
    }

    /// One packed entry. With FSOPT_PACK_INVAL_ATTRS every requested field is
    /// present, so offsets are fixed: length, returned attribute set (20),
    /// error, name reference, device, type, modification time (16), file ID,
    /// link count, allocated size. Fields are only 4-byte aligned.
    private static func entry(at start: UnsafeRawPointer) -> DirectoryEntry? {
        let returnedFileAttributes = start.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        let error = start.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
        guard error == 0 else { return nil }
        let nameOffset = Int(start.loadUnaligned(fromByteOffset: 28, as: Int32.self))
        let nameLength = Int(start.loadUnaligned(fromByteOffset: 32, as: UInt32.self))
        let nameStart = start + 28 + nameOffset
        let name = String(decoding: UnsafeRawBufferPointer(start: nameStart, count: max(0, nameLength - 1)), as: UTF8.self)
        let device = start.loadUnaligned(fromByteOffset: 36, as: Int32.self)
        let objectType = start.loadUnaligned(fromByteOffset: 40, as: UInt32.self)
        let seconds = start.loadUnaligned(fromByteOffset: 44, as: Int64.self)
        let nanoseconds = start.loadUnaligned(fromByteOffset: 52, as: Int64.self)
        let fileID = start.loadUnaligned(fromByteOffset: 60, as: UInt64.self)
        let linkCount = returnedFileAttributes & 0x1 != 0 ? start.loadUnaligned(fromByteOffset: 68, as: UInt32.self) : 1
        let allocated = returnedFileAttributes & 0x4 != 0 ? start.loadUnaligned(fromByteOffset: 72, as: Int64.self) : 0
        let type: DirectoryEntryType
        switch objectType {
        case 1: type = .file // VREG
        case 2: type = .directory // VDIR
        case 5: type = .symlink // VLNK
        default: type = .other
        }
        return DirectoryEntry(name: name, type: type, device: device, fileID: fileID, linkCount: linkCount,
                              allocatedBytes: max(0, allocated), modified: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1e9)
    }
}

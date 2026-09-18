import Darwin
import Foundation

/// Cleanup authority belongs to the created inode, not to a reusable pathname.
struct OwnedExportDirectory: Sendable {
    let url: URL
    private let device: dev_t
    private let inode: ino_t
    private let parentDevice: dev_t
    private let parentInode: ino_t

    init(exclusive url: URL) throws {
        var parent = stat()
        guard stat(url.deletingLastPathComponent().path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard mkdir(url.path, 0o700) == 0 else {
            if errno == EEXIST { throw EvidenceBundleExportError.destinationAlreadyExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.url = url
        device = metadata.st_dev
        inode = metadata.st_ino
        parentDevice = parent.st_dev
        parentInode = parent.st_ino
    }

    @discardableResult
    func removeIfOwned() -> Bool {
        var parent = stat()
        var metadata = stat()
        guard stat(url.deletingLastPathComponent().path, &parent) == 0,
              parent.st_dev == parentDevice, parent.st_ino == parentInode,
              lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_dev == device, metadata.st_ino == inode else { return false }
        do { try FileManager.default.removeItem(at: url); return true }
        catch { return false }
    }
}

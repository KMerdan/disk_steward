import CoreServices
import Foundation
let home = NSHomeDirectory()
let names = ["Documents", "Desktop", "Downloads"]
let roots = names.map { home + "/" + $0 }
final class Box: @unchecked Sendable { let lock = NSLock(); var paths: [String] = [] }
let box = Box()
let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
    let b = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
    let array = unsafeBitCast(paths, to: NSArray.self)
    b.lock.lock(); for i in 0..<count { b.paths.append(array[i] as! String) }; b.lock.unlock()
}
var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
    FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))!
FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "q"))
print("stream-started", FSEventStreamStart(s))
let tccDB = home + "/Library/Application Support/com.apple.TCC/TCC.db"
let fd = open(tccDB, O_RDONLY); let fdaErrno = fd < 0 ? errno : 0; if fd >= 0 { close(fd) }
print("full-disk-access-probe", fd >= 0 ? "granted (TCC.db openable)" : "not granted (open errno \(fdaErrno))")
let marker = ".disk-steward-tcc-probe-\(getpid())"
var wrote: [String: String] = [:]
for root in roots {
    let dir = root + "/" + marker
    do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false); try Data([1]).write(to: URL(fileURLWithPath: dir + "/f")); wrote[root] = "ok" }
    catch { wrote[root] = "write failed: \((error as NSError).code)" }
}
Thread.sleep(forTimeInterval: 3)
for root in roots { try? FileManager.default.removeItem(atPath: root + "/" + marker) }
Thread.sleep(forTimeInterval: 1)
FSEventStreamStop(s); FSEventStreamInvalidate(s)
box.lock.lock(); let seen = box.paths; box.lock.unlock()
for (name, root) in zip(names, roots) {
    let hits = seen.filter { $0.hasPrefix(root + "/" + marker) }.count
    print(name, "write:", wrote[root]!, "events-under-probe-dir:", hits)
}

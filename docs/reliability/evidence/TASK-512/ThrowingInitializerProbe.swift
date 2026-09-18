enum Failure: Error { case expected }
final class LeasePrimitive {
    let fd: Int
    init() throws {
        fd = 42
        print("explicit failure close")
        throw Failure.expected
    }
    deinit { print("deinit also closes") }
}
@main struct Probe { static func main() { _ = try? LeasePrimitive() } }

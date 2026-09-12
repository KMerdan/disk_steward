import CryptoKit
import Foundation

enum SHA256Digest {
    static func hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

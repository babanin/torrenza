import Foundation

/// The compatibility identity advertised on the wire, independent of the app's bundle identity.
/// Changing these labels does not conceal the connection's source IP or protocol behavior.
public enum ClientIdentity {
    public static let userAgent = "qBittorrent/5.1.0"
    public static let peerIDPrefix = "-qB5100-"

    /// KRPC has an optional binary client/version tag, not a human-readable application name.
    public static let dhtVersion = Data([0x71, 0x42, 5, 1])

    /// A fresh session identifier: eight fingerprint bytes plus twelve random bytes.
    public static func makePeerID() -> Data {
        Data(peerIDPrefix.utf8) + Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
    }
}

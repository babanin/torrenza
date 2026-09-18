import Foundation

public indirect enum BencodeValue: Sendable, Equatable {
    case integer(Int64)
    case bytes(Data)
    case list([BencodeValue])
    case dictionary([String: BencodeValue])

    public var intValue: Int64? { if case .integer(let value) = self { value } else { nil } }
    public var dataValue: Data? { if case .bytes(let value) = self { value } else { nil } }
    public var listValue: [BencodeValue]? { if case .list(let value) = self { value } else { nil } }
    public var dictionaryValue: [String: BencodeValue]? { if case .dictionary(let value) = self { value } else { nil } }
    public var stringValue: String? { dataValue.flatMap { String(data: $0, encoding: .utf8) } }
}

/// A bounded codec. Binary dictionary keys use a reversible reserved string representation.
public enum Bencode {
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumNodes = 250_000
    private static let binaryKeyPrefix = "\u{0}bencode:"

    public static func decode(_ data: Data) throws -> BencodeValue {
        let result = try decodePrefix(data)
        guard result.consumed == data.count else { throw invalid("Trailing bencode data") }
        return result.value
    }

    public static func decodePrefix(_ data: Data) throws -> (value: BencodeValue, consumed: Int) {
        var decoder = try Decoder(data)
        let value = try decoder.read(depth: 0)
        return (value, decoder.position)
    }

    // Retaining the original range is essential: re-encoding can change a torrent's identity.
    static func decodeMetainfo(_ data: Data) throws -> (value: BencodeValue, info: Data?) {
        var decoder = try Decoder(data)
        let value = try decoder.read(depth: 0)
        guard decoder.position == data.count else { throw invalid("Trailing metainfo data") }
        return (value, decoder.infoRange.map { Data(decoder.bytes[$0]) })
    }

    public static func encode(_ value: BencodeValue) -> Data {
        var output = Data()
        func writeBytes(_ bytes: Data) {
            output.append(contentsOf: "\(bytes.count):".utf8)
            output.append(bytes)
        }
        func write(_ value: BencodeValue) {
            switch value {
            case .integer(let number): output.append(contentsOf: "i\(number)e".utf8)
            case .bytes(let bytes): writeBytes(bytes)
            case .list(let values):
                output.append(108); values.forEach(write); output.append(101)
            case .dictionary(let values):
                output.append(100)
                let pairs = values.map { (rawKey($0.key), $0.value) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
                for (key, value) in pairs { writeBytes(key); write(value) }
                output.append(101)
            }
        }
        write(value)
        return output
    }

    private static func keyString(_ data: Data) -> String {
        if let value = String(data: data, encoding: .utf8), !value.hasPrefix(binaryKeyPrefix) { return value }
        return binaryKeyPrefix + data.base64EncodedString()
    }
    private static func rawKey(_ value: String) -> Data {
        if value.hasPrefix(binaryKeyPrefix), let data = Data(base64Encoded: String(value.dropFirst(binaryKeyPrefix.count))) { return data }
        return Data(value.utf8)
    }
    private static func invalid(_ reason: String) -> TorrentError { .invalidMetainfo(reason) }

    private struct Decoder {
        let bytes: [UInt8]
        var position = 0
        var nodes = 0
        var infoRange: Range<Int>?
        init(_ data: Data) throws {
            guard !data.isEmpty, data.count <= maximumBytes else { throw invalid("Bencode input is empty or exceeds 16 MiB") }
            bytes = Array(data)
        }
        mutating func read(depth: Int) throws -> BencodeValue {
            nodes += 1
            guard depth <= 64, nodes <= maximumNodes, position < bytes.count else { throw invalid("Truncated or excessively complex bencode") }
            switch bytes[position] {
            case 105:
                position += 1
                let start = position
                while position < bytes.count, bytes[position] != 101 {
                    guard position - start < 20 else { throw invalid("Bencode integer overflow") }
                    position += 1
                }
                guard position < bytes.count else { throw invalid("Unterminated integer") }
                let text = String(decoding: bytes[start..<position], as: UTF8.self)
                position += 1
                guard !text.isEmpty, text != "-0", !text.hasPrefix("+"),
                      !(text.count > 1 && text.hasPrefix("0")), !text.hasPrefix("-0"),
                      text.utf8.enumerated().allSatisfy({ $0.element >= 48 && $0.element <= 57 || $0.offset == 0 && $0.element == 45 }),
                      let number = Int64(text) else { throw invalid("Invalid bencode integer") }
                return .integer(number)
            case 108:
                position += 1
                var list: [BencodeValue] = []
                while position < bytes.count, bytes[position] != 101 { list.append(try read(depth: depth + 1)) }
                try terminator()
                return .list(list)
            case 100:
                position += 1
                var dictionary: [String: BencodeValue] = [:]
                while position < bytes.count, bytes[position] != 101 {
                    let key = keyString(try readBytes())
                    guard dictionary[key] == nil else { throw invalid("Duplicate dictionary key") }
                    let start = position
                    dictionary[key] = try read(depth: depth + 1)
                    if depth == 0 && key == "info" { infoRange = start..<position }
                }
                try terminator()
                return .dictionary(dictionary)
            case 48...57: return .bytes(try readBytes())
            default: throw invalid("Invalid bencode marker")
            }
        }
        mutating func terminator() throws {
            guard position < bytes.count, bytes[position] == 101 else { throw invalid("Unterminated bencode container") }
            position += 1
        }
        mutating func readBytes() throws -> Data {
            let start = position
            var count = 0
            while position < bytes.count, bytes[position] != 58 {
                let byte = bytes[position]
                guard byte >= 48, byte <= 57, position - start < 9 else { throw invalid("Invalid byte string length") }
                count = count * 10 + Int(byte - 48)
                guard count <= maximumBytes else { throw invalid("Byte string exceeds size limit") }
                position += 1
            }
            guard position < bytes.count, position > start,
                  !(position - start > 1 && bytes[start] == 48) else { throw invalid("Invalid byte string") }
            position += 1
            guard count <= bytes.count - position else { throw invalid("Truncated byte string") }
            defer { position += count }
            return Data(bytes[position..<(position + count)])
        }
    }
}

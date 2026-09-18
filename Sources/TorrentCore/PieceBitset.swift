import Foundation

/// Compact, MSB-first piece availability as defined by the BitTorrent wire protocol.
public struct PieceBitset: Sendable, Codable, Equatable {
    public let count: Int
    public private(set) var bytes: Data

    public init(count: Int, repeating: Bool = false) {
        precondition(count >= 0)
        self.count = count
        bytes = Data(repeating: repeating ? 0xff : 0, count: count / 8 + (count % 8 == 0 ? 0 : 1))
        if repeating, count % 8 != 0 {
            bytes[bytes.count - 1] &= UInt8.max << (8 - count % 8)
        }
    }

    public init(count: Int, bytes: Data) throws {
        guard count >= 0, bytes.count == count / 8 + (count % 8 == 0 ? 0 : 1) else {
            throw TorrentError.invalidMessage("Invalid piece bitfield length")
        }
        if count % 8 != 0, let last = bytes.last, last & (UInt8.max >> (count % 8)) != 0 {
            throw TorrentError.invalidMessage("Nonzero padding bits in piece bitfield")
        }
        self.count = count
        // Normalize Data slices so every public index starts at zero.
        self.bytes = bytes.startIndex == 0 ? bytes : Data(bytes)
    }

    public subscript(index: Int) -> Bool {
        get {
            precondition(index >= 0 && index < count)
            return bytes[index / 8] & (0x80 >> (index % 8)) != 0
        }
        set {
            precondition(index >= 0 && index < count)
            let mask: UInt8 = 0x80 >> (index % 8)
            if newValue { bytes[index / 8] |= mask } else { bytes[index / 8] &= ~mask }
        }
    }

    public var setCount: Int { bytes.reduce(0) { $0 + $1.nonzeroBitCount } }
    public var isComplete: Bool { setCount == count }

    /// Finds a set piece at or after `offset`, without wrapping around.
    public func firstSetIndex(from offset: Int = 0) -> Int? {
        guard offset >= 0, offset < count else { return nil }
        var byteIndex = offset / 8
        var byte = bytes[byteIndex] & (UInt8.max >> (offset % 8))
        while true {
            if byte != 0 { return byteIndex * 8 + byte.leadingZeroBitCount }
            byteIndex += 1
            guard byteIndex < bytes.count else { return nil }
            byte = bytes[byteIndex]
        }
    }

    /// Intersects availability and selection, excluding completed and pending pieces.
    /// Four input bitmaps are read directly; only the result bitmap is allocated.
    public static func candidates(available: Self, wanted: Self, verified: Self, inFlight: Self) -> Self {
        precondition(available.count == wanted.count && wanted.count == verified.count && verified.count == inFlight.count)
        var result = Self(count: available.count)
        let length = result.bytes.count
        guard length > 0 else { return result }
        available.bytes.withUnsafeBytes { a in
            wanted.bytes.withUnsafeBytes { w in
                verified.bytes.withUnsafeBytes { v in
                    inFlight.bytes.withUnsafeBytes { f in
                        result.bytes.withUnsafeMutableBytes { output in
                            let ap = a.baseAddress!, wp = w.baseAddress!, vp = v.baseAddress!, fp = f.baseAddress!
                            let destination = output.baseAddress!
                            var offset = 0
                            // Four independent vectors allow the CPU to overlap loads and
                            // avoid one loop branch for each sixteen payload bytes.
                            let wideEnd = length & ~63
                            while offset < wideEnd {
                                for lane in 0..<4 {
                                    let position = offset + lane * 16
                                    let av = ap.loadUnaligned(fromByteOffset: position, as: SIMD16<UInt8>.self)
                                    let wa = wp.loadUnaligned(fromByteOffset: position, as: SIMD16<UInt8>.self)
                                    let ve = vp.loadUnaligned(fromByteOffset: position, as: SIMD16<UInt8>.self)
                                    let fl = fp.loadUnaligned(fromByteOffset: position, as: SIMD16<UInt8>.self)
                                    destination.storeBytes(of: av & wa & ~(ve | fl), toByteOffset: position, as: SIMD16<UInt8>.self)
                                }
                                offset += 64
                            }
                            let vectorEnd = length & ~15
                            while offset < vectorEnd {
                                let av = ap.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                                let wa = wp.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                                let ve = vp.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                                let fl = fp.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                                destination.storeBytes(of: av & wa & ~(ve | fl), toByteOffset: offset, as: SIMD16<UInt8>.self)
                                offset += 16
                            }
                            while offset < length {
                                output[offset] = a[offset] & w[offset] & ~(v[offset] | f[offset])
                                offset += 1
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    /// Bytewise reference implementation for regression tests and release benchmarks.
    /// Swift may automatically vectorize this baseline in optimized builds.
    static func scalarCandidates(available: Self, wanted: Self, verified: Self, inFlight: Self) -> Self {
        precondition(available.count == wanted.count && wanted.count == verified.count && verified.count == inFlight.count)
        var result = Self(count: available.count)
        available.bytes.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            wanted.bytes.withUnsafeBytes { (w: UnsafeRawBufferPointer) in
                verified.bytes.withUnsafeBytes { (v: UnsafeRawBufferPointer) in
                    inFlight.bytes.withUnsafeBytes { (f: UnsafeRawBufferPointer) in
                        result.bytes.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                            for index in output.indices {
                                output[index] = a[index] & w[index] & ~(v[index] | f[index])
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case count, bytes }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(count: container.decode(Int.self, forKey: .count), bytes: container.decode(Data.self, forKey: .bytes))
    }
}

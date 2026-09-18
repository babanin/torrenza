import Foundation
import Testing
@testable import TorrentCore

struct BitsetTests {
    @Test func wireOrderingAndPadding() throws {
        var bits = PieceBitset(count: 10)
        bits[0] = true; bits[7] = true; bits[9] = true
        #expect(bits.bytes == Data([0x81, 0x40]))
        #expect(bits.setCount == 3)
        #expect(bits.firstSetIndex() == 0)
        #expect(bits.firstSetIndex(from: 1) == 7)
        #expect(bits.firstSetIndex(from: 8) == 9)
        #expect(bits.firstSetIndex(from: 10) == nil)
        bits[7] = false
        #expect(bits.firstSetIndex(from: 1) == 9)
        #expect(PieceBitset(count: 10, repeating: true).bytes == Data([0xff, 0xc0]))
        #expect(throws: TorrentError.self) { try PieceBitset(count: 10, bytes: Data([0xff, 0xff])) }
        #expect(throws: TorrentError.self) { try PieceBitset(count: 9, bytes: Data([0xff])) }
        #expect(throws: TorrentError.self) { try PieceBitset(count: -1, bytes: Data()) }
        #expect(PieceBitset(count: 0).isComplete)
    }

    @Test func codableRoundTripAndMalformedInput() throws {
        let original = PieceBitset(count: 131, repeating: true)
        #expect(try JSONDecoder().decode(PieceBitset.self, from: JSONEncoder().encode(original)) == original)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PieceBitset.self, from: Data(#"{"count":1,"bytes":"/w=="}"#.utf8))
        }
    }

    @Test func simdMatchesScalarAcrossTailsAndSlicedInput() throws {
        var random = Generator()
        for count in [0, 1, 7, 8, 9, 119, 120, 127, 128, 129, 135, 255, 256, 257, 2049, 32767] {
            for prefix in 0..<17 {
                var inputs: [PieceBitset] = []
                for _ in 0..<4 {
                    let length = count / 8 + (count % 8 == 0 ? 0 : 1)
                    var data = Data((0..<(length + prefix)).map { _ in random.byte() })
                    if length > 0 && count % 8 != 0 { data[data.count - 1] &= UInt8.max << (8 - count % 8) }
                    inputs.append(try PieceBitset(count: count, bytes: data.dropFirst(prefix)))
                }
                let output = PieceBitset.candidates(available: inputs[0], wanted: inputs[1], verified: inputs[2], inFlight: inputs[3])
                var scalar = PieceBitset(count: count)
                for bit in 0..<count { scalar[bit] = inputs[0][bit] && inputs[1][bit] && !inputs[2][bit] && !inputs[3][bit] }
                #expect(PieceBitset.scalarCandidates(available: inputs[0], wanted: inputs[1], verified: inputs[2], inFlight: inputs[3]) == scalar)
                #expect(output == scalar, "count=\(count), prefix=\(prefix)")
                #expect(output.firstSetIndex() == (0..<count).first(where: { scalar[$0] }))
            }
        }
    }

    @Test func unalignedBorrowedBuffers() throws {
        let size = 4099
        let allocations = (0..<4).map { _ in UnsafeMutableRawPointer.allocate(byteCount: size + 16, alignment: 16) }
        defer { allocations.forEach { $0.deallocate() } }
        var inputs: [PieceBitset] = []
        for index in 0..<4 {
            let pointer = allocations[index].advanced(by: index * 2 + 1)
            pointer.initializeMemory(as: UInt8.self, repeating: UInt8(0xff >> index), count: size)
            let borrowed = Data(bytesNoCopy: pointer, count: size, deallocator: .none)
            inputs.append(try PieceBitset(count: size * 8, bytes: borrowed))
        }
        #expect(inputs[0].bytes.withUnsafeBytes { Int(bitPattern: $0.baseAddress!) % 16 != 0 })
        #expect(PieceBitset.candidates(available: inputs[0], wanted: inputs[1], verified: inputs[2], inFlight: inputs[3]) ==
                PieceBitset.scalarCandidates(available: inputs[0], wanted: inputs[1], verified: inputs[2], inFlight: inputs[3]))
    }

    @Test func fullEmptyAndCopyIsolation() {
        let all = PieceBitset(count: 1000, repeating: true)
        let none = PieceBitset(count: 1000)
        #expect(PieceBitset.candidates(available: all, wanted: all, verified: none, inFlight: none) == all)
        #expect(PieceBitset.candidates(available: all, wanted: all, verified: all, inFlight: none) == none)
        var copy = all; copy[0] = false
        #expect(all[0]); #expect(!copy[0])
    }

    private struct Generator {
        var value: UInt64 = 0x123456789abcdef
        mutating func byte() -> UInt8 {
            value ^= value << 13; value ^= value >> 7; value ^= value << 17
            return UInt8(truncatingIfNeeded: value)
        }
    }
}

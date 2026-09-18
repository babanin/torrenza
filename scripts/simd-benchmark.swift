// Compile alongside Sources/TorrentCore/{Models,PieceBitset}.swift with swiftc -O -whole-module-optimization.
import Foundation

@main struct SIMDBenchmark {
    @inline(never) static func scalar(_ a: PieceBitset, _ w: PieceBitset, _ v: PieceBitset, _ f: PieceBitset) throws -> PieceBitset {
        PieceBitset.scalarCandidates(available: a, wanted: w, verified: v, inFlight: f)
    }

    @inline(never) static func vector(_ a: PieceBitset, _ w: PieceBitset, _ v: PieceBitset, _ f: PieceBitset) -> PieceBitset {
        PieceBitset.candidates(available: a, wanted: w, verified: v, inFlight: f)
    }

    static func main() throws {
        var checksum = 0
        print("bytes,density,iterations,SIMD_ms,scalar_ms,speedup")
        for size in [8, 16, 128, 1024, 16384, 131072] {
            for sparse in [false, true] {
                let a = try PieceBitset(count: size * 8, bytes: Data(repeating: sparse ? 0x80 : 0xfe, count: size))
                let w = PieceBitset(count: size * 8, repeating: true)
                let v = try PieceBitset(count: size * 8, bytes: Data(repeating: 0x24, count: size))
                let f = try PieceBitset(count: size * 8, bytes: Data(repeating: 0x01, count: size))
                let iterations = max(500, 16_000_000 / size)
                var vectorTimes: [Double] = [], scalarTimes: [Double] = []
                // Alternate order and report medians to reduce allocator/warmup bias.
                for trial in 0..<6 {
                    for isVector in trial.isMultiple(of: 2) ? [true, false] : [false, true] {
                        let start = ContinuousClock.now
                        for index in 0..<iterations {
                            let result = isVector ? vector(a, w, v, f) : try scalar(a, w, v, f)
                            checksum &+= Int(result.bytes[index % size])
                        }
                        let duration = start.duration(to: .now).components
                        let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                        if isVector { vectorTimes.append(ms) } else { scalarTimes.append(ms) }
                    }
                }
                let vectorMS = vectorTimes.sorted()[3], scalarMS = scalarTimes.sorted()[3]
                print("\(size),\(sparse ? "sparse" : "dense"),\(iterations),\(String(format: "%.3f", vectorMS)),\(String(format: "%.3f", scalarMS)),\(String(format: "%.2f", scalarMS / vectorMS))")
            }
        }
        print("checksum=\(checksum)")
    }
}

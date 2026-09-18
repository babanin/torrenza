# Piece selection SIMD benchmark

Run from the repository root:

```sh
swiftc -O -whole-module-optimization -module-cache-path /private/tmp/torrenza-simd-modules Sources/TorrentCore/Models.swift Sources/TorrentCore/PieceBitset.swift scripts/simd-benchmark.swift -o /private/tmp/torrenza-simd-benchmark
/private/tmp/torrenza-simd-benchmark
swiftc -O -whole-module-optimization -module-cache-path /private/tmp/torrenza-simd-modules -emit-assembly Sources/TorrentCore/Models.swift Sources/TorrentCore/PieceBitset.swift scripts/simd-benchmark.swift -o /private/tmp/torrenza-simd.s
rg -n 'and\.16b|orr\.16b|bic\.16b' /private/tmp/torrenza-simd.s
```

Measured 2026-09-18 on the development arm64 Mac using Apple Swift 6.3.3,
`-O -whole-module-optimization`. Each result includes result-buffer allocation;
inputs are reused. Six samples alternate implementation order, and the upper
median is reported. Both dense and sparse piece availability are exercised.
The scalar reference uses the same allocation and validation path as SIMD;
Swift can automatically vectorize that bytewise loop.

| Bitmap bytes | Dense SIMD/reference ratio | Sparse SIMD/reference ratio |
|---:|---:|---:|
| 8 | 1.00x | 0.99x |
| 16 | 1.04x | 1.08x |
| 128 | 1.00x | 1.00x |
| 1,024 | 1.01x | 1.01x |
| 16,384 | 0.98x | 1.01x |
| 131,072 | 1.01x | 0.99x |

Ratio is reference time divided by SIMD time; greater than one favors SIMD.
These measurements show parity with Swift's automatically optimized baseline,
not an established application throughput improvement. Assembly inspection of
`PieceBitset.candidates` confirms NEON `and.16b`, `orr.16b`, and `bic.16b` with
128-bit loads/stores. Inputs shorter than sixteen bytes use the scalar tail.
The four-vector loop replaced an initial single-vector loop that regressed on
16 KiB bitmaps. Microbenchmark results do not establish total memory footprint,
network throughput, disk efficiency, or performance on other hardware.

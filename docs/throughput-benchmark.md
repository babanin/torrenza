# Controlled download throughput benchmark

`scripts/throughput_benchmark.py` runs a built Release `TorrentProbe` against
independent Python BitTorrent peers and a private loopback tracker. It creates a
new, exclusive output directory, a deterministic payload, and a separate engine
state directory. It never opens the application's profile or contacts public
discovery services. Python 3.11+ and the normal Swift build tools are sufficient.

Each request's response becomes available after a fixed delay. Requests pipeline
independently; the fixture does not impose an upload bandwidth cap. This models
request-latency sensitivity, rather than an internet swarm or a full TCP network
emulator. Blocks remain 16 KiB. The peers advertise BEP 10 `reqq`.

## Reproduce

From the repository root, build and run the default settings and high preset:

```sh
swift build -c release --product TorrentProbe
python3 scripts/throughput_benchmark.py .build/release/TorrentProbe \
  /private/tmp/torrenza-default-unique --label standard
python3 scripts/throughput_benchmark.py .build/release/TorrentProbe \
  /private/tmp/torrenza-high-unique --label high-throughput \
  --settings '{"maxPeers":1000,"payloadBudget":268435456,"downloadRequestWindow":128}'
```

Use a fresh output path for each run. Default workload: 64 MiB, two seeders,
1 MiB pieces, 50 ms response delay, remote `reqq=128`. `--mib`, `--peers`,
`--latency-ms`, `--reqq`, and `--timeout` select other workloads. The output
contains `result.json`, `probe.log`, the torrent, downloaded fixture, and engine
state. A failed probe or SHA-256 mismatch makes the script exit unsuccessfully.

`TORRENZA_PROBE_SETTINGS` is a development-only JSON override understood by the
probe. The script supplies it from `--settings`. The probe always disables public
DHT bootstrap and selects the SSD storage profile for these fixtures.

For a baseline revision, export that revision into a separate temporary directory
with `git archive`, copy `Sources/TorrentEngine/EngineDiagnostics.swift` and
`Sources/TorrentProbe/main.swift` into the corresponding baseline source paths,
and build its Release probe there. The telemetry observes existing state without
changing the old scheduler or request depth. Run both binaries with the same
benchmark script and fixture parameters. Keep their build products separate.

## Observed on 2026-10-10

Apple Silicon macOS, Apple Swift 6.3.3 toolchain, Release probes. Baseline engine source:
`da6d52323cf508a083c80cb3fc520b0db9aa3587`. The changed engine was built from this
session's working tree. All three runs used the workload above, both peers
connected, all 4,096 blocks downloaded, and the full-file SHA-256 matched
`281e519df3077b557c6b03f5da83c4e8d397219259615dd7c3308f89cae8f2a6`.

| Engine/settings | Payload MiB/s | Whole-run seconds | Whole-run MiB/s | Peak requests per peer / total | Reservation high-water bytes / limit |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline/default | 4.821 | 13.864 | 4.616 | 8 / 16 | 573,440 / 33,554,432 |
| Changed/default | 4.830 | 13.886 | 4.609 | 8 / 16 | 606,208 / 33,554,432 |
| Changed/high throughput | 75.895 | 1.458 | 43.898 | 128 / 256 | 4,554,752 / 268,435,456 |

Payload timing spans the first request received through the last block enqueued
by the seeders. Whole-run timing also includes process startup, engine setup,
piece verification, persistence, and shutdown. Engine snapshots sample pending
requests and connections; the peers also count every request and response.
Budget high-water comes from the engine's reservation actor, so it retains peaks
between samples. Both changed runs reported zero reserved bytes, pending
requests, and admitted connections after shutdown.

A repeat on the final engine after the slot-reclamation adjustment measured
76.248 MiB/s payload throughput and 1.959 seconds whole-run time (32.670 MiB/s),
again with 128 / 256 outstanding requests, the same 4,554,752-byte reservation
high-water mark, matching SHA-256, and zero reservations after shutdown. The
short whole-run timing is sensitive to startup/checkpoint scheduling.

A separate 4 MiB check with one peer, 20 ms delay, the high preset, and remote
`reqq=3` reached exactly three outstanding requests, verified its SHA-256, and
released every reservation on shutdown.

These short runs demonstrate request-window behavior and latency-bound engine
throughput. They do not establish real-swarm bandwidth saturation, 1,000-peer
GUI CPU/memory behavior, HDD performance, VPN performance, or long-duration
memory stability. The reservation budget is not total application memory.


## Picker benchmark and regression checks

Run `TORRENZA_PICKER_BENCHMARK=1 swift test -c release --filter testThousandPeerPickerBenchmark`.
On 2026-10-10, 200 new-piece selections over 16,384 pieces and 1,000 modeled
peer bitfields took 2,703.055 ms with the previous rarity scan and 1.826 ms with
the incremental index. Setup and peer-availability updates are excluded; this
microbenchmark does not predict whole-engine CPU savings.

The full Debug suite passed 75 XCTest cases (one opt-in picker benchmark skipped)
and 137 Swift Testing cases; the full Release suite passed the same cases with
the picker benchmark enabled. Public internet DHT remains opt-in and was skipped.
Regressions cover live budget resize, legacy profiles, request depth/remote limits,
reservation cleanup, slot borrowing/reclamation, handshake admission, verification
cancellation/quarantine, private discovery, delayed trackers, and piece selection.
Announcement validation checks fixed bitmap size and duplicate coalescing, plus
payload/hash progress and pause cancellation while the announcement worker is
held behind a deterministic gate on a loopback connection. It does not saturate
a real slow receiver's TCP buffers.

Debug Settings appearance and profile lifecycle smoke checks passed with isolated
fixtures. The installed Release passed strict signature and bundle comparison
checks; its existing library opened and retained the profile's resource limits.


## Release GUI library-load measurement

On 2026-10-10, a Release GUI copy was re-signed with a separate bundle identifier
and sandbox. It opened a generated profile containing 1,000 paused private
one-piece torrents with High throughput selected (1,000 / 256 MiB / 128), SSD
storage mode, zero active transfers, and zero peers. No trackers, DHT bootstrap,
or payload files were configured. Native UI inspection confirmed the selected
synthetic profile, the transfer count, and completion of profile opening.

Hardware: Apple M3 Pro, 36 GiB RAM, APFS Apple Fabric SSD; macOS 26.5.1 and
Xcode 26.6. Release Mach-O UUID: `6106054B-9F8A-31FB-82B2-9530C329A955`.
This build predates the final change limiting slot reclamation to actual waiting
candidate count; no networking ran in this GUI workload.

There were 39 `ps` samples across 40.223 seconds, starting at process age one
second. Peak RSS was 144,736 KiB (141.34 MiB); the last 20 seconds ranged from
144,688 to 144,736 KiB, with reported CPU 0.0% in each sample. Startup's first CPU
sample was 83.3%, and a sample around 10.6 seconds reported 17.0%. RSS is not the
same metric as Activity Monitor's physical footprint.

Folders were collapsed, so this measures loaded-library startup and idle behavior,
not rendering 1,000 visible rows, live-peer stress, or long-duration stability.
The isolated copy quit normally; SQLite integrity, 1,000 saved transfers, and the
clean-shutdown marker were verified afterward. The installed app's profile and
downloads were not used for this measurement.

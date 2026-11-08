# Validation

## Main-tree refresh checks (2026-11-08)

- Full package suite: 100 XCTest tests, one skipped, no failures; 156 Swift Testing tests passed. Optimized `TreeTests|TreeActionTests`: 20 tests passed.
- The Debug `--ui-scroll-check` fixture adds 1,234 torrents and an expanded 2,048-file torrent with sparse file indices. It checks unchanged updates, four 500 ms progress updates in the same cell, actual AppKit reload calls, recycled names, and progress changed while vertically or horizontally offscreen.
- Snapshot metrics are discarded before sorting; indexed checkbox projections are discarded on snapshot/pending-action changes. Regression tests cover sparse indices, hidden descendants, padding, stale nodes, rollback, and snapshot isolation.
- Release diagnostic flags remain disabled. Debug fixture results establish presentation correctness, not Release scrolling performance.
- Final light/dark scrolling, sorting, file-selection and search diagnostics passed. The stronger nearby prepared-cell check initially exposed stale progress; clip-view bounds observation now refreshes newly exposed cells without rebuilding the tree. Standalone multiselection passed after a combined run lost key-window focus. The isolated profile smoke ended with `PROFILE SMOKE PASSED`.
- The final Release was built, strictly signature-verified, installed with the previous bundle preserved, and checked byte-for-byte against the build. The process ran from `/Applications/Torrenza.app`; the existing 804-transfer library appeared with no opening-profile overlay. Local signing is ad-hoc.
- Release Time Profiler observations: three nominal 30-second baseline captures had main-thread sample weights of 19.671, 14.694 and 18.420 seconds; two after-install captures had 9.786 and 12.143 seconds. These are **not a controlled speedup result**: active transfers changed from 0 to 5, window geometry changed on relaunch, automation increased from 240 to 480 scroll calls per pass, and accessibility work is included. Storage medium type was not established; visible peer counts were zero. Baseline RSS grew from 187,344 to 538,064 KiB; initial after-install RSS was 325,312 KiB, with process age/cache warming unmatched. No memory improvement is established.
- The requested three matched before/after passes and animation-hitch comparison remain incomplete (three before, two after; Time Profiler responsiveness intervals are not frame-hitch measurements). No claim of fewer/shorter measured hitches is made. Private traces and XML exports are under `/private/tmp/torrenza-scroll-before-{c,d,e}.trace`, `/private/tmp/torrenza-scroll-after-{c,d}.trace`, and `/private/tmp/torrenza-{before,after}-*-profile.xml`. Baseline executable SHA-256: `38c264ff31515966a681f58e74e27c2e9bd3c3d0c358efd20b0a720416de4d07`; installed executable: `757346c8cebc2a00d4e5f28c2abd02eb25ba7c7006f9fcc799d49497c9a334b8`.

Environment: Apple Silicon, macOS 26.5.1, Xcode 26.6, Swift 6.3.3. Results below distinguish protocol/library tests from native UI and release checks.

## Executed checks

- Swift package tests cover bounded parsing, raw-info hashing, SIMD/scalar equivalence, resource-budget cancellation, framing, TCP/UDP loopback transport, tracker parsing, DHT discovery, metadata/PEX, safe disk I/O, selective-file boundaries, SQLite atomicity/migration, resume, and tree behavior.
- Final optimized package test run passed: 12 XCTest cases and a Swift Testing run reporting 89 tests, with the public-network DHT check deliberately skipped. The opt-in public check was run separately as described below.
- Independent qBittorrent 5.2.3 interoperability used a separate temporary profile and a local tracker. A deterministic **16 MiB** fixture downloaded into Torrenza, resolved/downloaded through a magnet, and was seeded back to qBittorrent. All outputs match SHA-256 `341aacac661ccb210720bedaa9ead5d668fe5ea41a73532fc147c71e34040df1`.
- The debug engine probe completed the fixture download in **1.50 s**, magnet resolution/download in **1.41 s**, and uploaded all 16 MiB during the reverse test. These are short loopback checks, not internet throughput benchmarks. Observed maximum resident size was about **16–17 MiB for the command-line probe**, not the GUI application.
- The final release probe downloaded the same fixture in **1.24 s**. SQLite integrity checking passed, journal mode was DELETE, and its state directory contained only `Torrenza.sqlite`. The completed session and lifetime counters both recorded exactly **16,777,216 downloaded bytes** and zero uploaded bytes for this download-only probe run.
- An opt-in public DHT lookup for the official Ubuntu 24.04.5.1 torrent returned **128 peer endpoints and eight responsive contacts** in approximately **17.4 s**. No payload was downloaded and the test did not announce a peer.
- Release SIMD assembly contains arm64 vector loads/stores and NEON `and`, `orr`, and `bic` operations. Fair microbenchmarks are approximately equivalent to the compiler-vectorized scalar reference; see `scripts/simd-benchmark.md`.
- Native Debug app builds and launches. Populated outline tables were rendered and inspected in light and dark appearance, including real path grouping, nested files, unavailable volumes, transfer status and connected/reported swarm counts.
- The final Release app builds and passes strict code-signature verification with local ad-hoc signing. Native layout inspection at a 1,000-point window width confirms all five connected filter buttons fit in the titlebar; the group uses its intrinsic width rather than expanding into a dropdown.
- Signed Debug entitlements were read back: App Sandbox, client/server networking, user-selected file access, and app-scoped bookmarks are present. Bundle document and magnet registrations are present. XcodeGen preserves the hand-maintained plists.

## Header checks

- Native toolbar geometry was checked at 1,000, 1,150, and 2,000 points in light/dark fixtures. Title/profile, all five filter segments, Add, Start/Pause, the 220-point search field, and the rightmost Inspector remain visible without overflow. An 80-character profile name truncates within the fixed title area.
- Search diagnostics passed for native action-to-model updates, the Command-F focus request, clearing, and model-to-field updates. These exercise the actual toolbar search coordinator; screenshots retain the Liquid Glass capture limitation noted below.
- Reproduce with the Debug app's `--ui-fixture --ui-dark --ui-narrow --ui-search-check --ui-exit` arguments. Use `--ui-wide --ui-long-profile` for the long-name case. Reports are written under `Torrenza-UI` in the app container's temporary directory.

## Profile checks

- Profile-store tests cover independent database contents, preserving the existing Default database, create/rename/reopen, duplicate-name serialization, symlink handling, and discovery when another profile is corrupt.
- Engine tests cover independent torrents/settings/UI/statistics, restoring desired-running transfers, draining in-flight work before final statistics are saved, invalid profile preflight without mutation, and retrying a failed shutdown checkpoint.
- A Debug app smoke check uses isolated temporary databases and preference storage. It exercises actual AppModel creation, switching, rename, settings/UI restoration, separate session histories, duplicate names, rejection of invalid target UI state, and restoring the selected profile on relaunch, and idempotent shutdown. All checks passed. Native filter geometry at 1,000-point width still fits all five connected buttons.
- Run the isolated app-model check with `open -n build/Build/Products/Debug/Torrenza.app --args --profile-smoke`. It exits after writing `Torrenza-Profile-Smoke/result.txt` in the app container's temporary directory. This checks persistence shutdown directly; it is not a full accessibility-driven click or normal Quit-menu test; the screenshot limitation below still applies.

## Release memory check — 2026-09-19

- Replaced per-piece `[Data]` allocations with contiguous `PieceHashes` storage. The saved base64-array JSON format remains compatible; malformed hash lengths are rejected during decoding. Library startup now reads individual metadata/ownership records instead of retaining all serialized metadata at once.
- Measured the installed, ad-hoc signed **Release GUI**, comparing baseline `67fc545` with this change on the same Default profile: **599 torrents, 34,543 files, 885,094 piece hashes**. Both window captures showed **six active transfers**, and downloads continued at approximately **2.2–2.3 MB/s**. Eleven torrents retained wanted-running intent. Settings were unchanged: eight download slots, five seed slots, 60-peer limit, 32 MiB payload budget.
- `vmmap`/`sample` physical footprint was **314.8–363.2 MiB before**, at roughly 23–28 minutes of uptime; after a normal quit/install/relaunch, `vmmap` measured **159.7 MiB at 2:03** and **160.0 MiB at 3:27**. These are post-startup live observations, not a matched-duration benchmark or an RSS comparison. TCP established sockets varied from four before to eleven after; these are socket counts, not independently verified engine peer counts. The profile uses internal and external SSD storage plus another USB volume whose medium type was not reported.
- Heap snapshots dropped from **2,505,703 allocations / 258.0 MiB allocated** to **504,923 / 134.7 MiB**. Before the change, **889,599 `__DataStorage` objects** accounted for **67.9 MiB**, and 599 hash arrays added **20.0 MiB**, excluding their separately allocated bytes. Live networking and allocator history varied; the observed approximately 50% footprint reduction is not a universal memory ceiling. Long-duration growth and the planned controlled workload below remain unverified.
- Full optimized tests passed: **29 XCTest cases and 106 Swift Testing tests**. After review found a fresh/closed-connection issue in the new keys API, the fix passed **two metadata persistence cases and seven SQLite tests**, including the added reopen regression. Focused Debug parsing/hash/storage tests also passed. Final Release build and strict signature checks passed; the installed bundle matched the build byte-for-byte.
- The normal Quit completed and the installed process ran from `/Applications/Torrenza.app`. Window inspection confirmed the profile overlay cleared and all 599 transfers returned. Database integrity, metadata bytes/identities, file-selection sets, destinations, seed ratios and wanted-running intent were preserved; transfer counters remained monotonic. A consistent profile snapshot and the previous app bundle were retained outside Git. No payload recheck was initiated.

## Boundaries and pending release checks

- The planned **30-minute, two × 10 GiB, 60-peer** memory/I/O benchmark has not run. Only about **9 GiB** was free on the development volume, so that workload would not fit. Short fixture measurements do not establish the GUI's 150 MiB acceptance target.
- No external HDD was available for physical seek/write measurements or a real cable-removal test. Filesystem identity, replacement, missing-data and corruption paths have automated coverage.
- Native screenshot capture can render the AppKit outline, but some layer-backed SwiftUI toolbar/footer surfaces are incomplete in the captured bitmap. User screenshots confirmed actual window rendering; a full keyboard/VoiceOver/accessibility-settings audit is still required before public release.
- DHT IPv4 uses a stable listening port. IPv6 discovery uses BEP 43 read-only queries because Network.framework cannot share the listener's IPv6 port with separate outgoing flows. IPv6 lookup and peer announcement are tested; full IPv6 routing-node participation is not claimed.
- Developer ID signing, notarization, and Gatekeeper installation checks require release credentials and have not been performed. The checked-in release script implements that workflow; local builds are ad-hoc signed.

## Reproduction

```sh
swift test
swift test -c release
./scripts/build.sh
```

Public discovery is deliberately excluded from ordinary tests:

```sh
TORRENZA_PUBLIC_DHT=1 swift test --filter publicUbuntuDiscovery
```

Use `scripts/interop_fixture.py` and `TorrentProbe` as described in the README for independent-client transfers. Run only generated fixtures in an isolated client profile.

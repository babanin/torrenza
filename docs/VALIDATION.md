# Validation

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

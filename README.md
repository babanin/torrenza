# Torrenza

A native macOS torrent client written entirely in Swift. Requires macOS 26 or later and Apple Silicon.

Torrenza organizes downloads by volume and destination folder, then expands into each torrent's folders and files. The main window uses a native AppKit outline table inside a SwiftUI shell. Five filters live in the window toolbar, leaving the full window width and height for the tree. Only managed content is shown; browsing does not scan your drives.

## Build and run

Prerequisites: Xcode 26.6 or a compatible newer Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
./scripts/build.sh
open build/Build/Products/Release/Torrenza.app
```

Alternatively open `Torrenza.xcodeproj`, select the Torrenza scheme, and run. Regenerate the project with `xcodegen generate` after adding app source files. The app links a local Swift package; there are no third-party runtime dependencies or bundled torrent engines.

```sh
swift test
swift test -c release
```

Network integration tests bind loopback TCP/UDP sockets. They need an execution environment that permits local sockets.

## Using Torrenza

- Open a `.torrent` file or magnet link with the toolbar, menu, Finder, or drag and drop.
- Choose a destination folder and the files to download. Existing files are preserved unless you explicitly choose to reuse and verify them.
- Expand volumes and folders to navigate. Folder pause/resume actions apply to their descendant torrents once each.
- Open the inspector for file selection, transfer information, trackers, seed limits, and destination storage profile. Individual peer details are intentionally omitted.
- Seeds and Peers show **connected / tracker-reported** counts. Peers includes seeds; unknown estimates display `—`. Stale estimates are dimmed and include their report time in a tooltip. Counts are never summed across trackers or torrents.
- Closing the window keeps transfers running. Quitting stops transfers and saves state. Normal system sleep is respected unless preventing idle sleep during downloads is enabled in Settings.
- Removing a torrent preserves its data. Deleting downloaded files is a separate confirmation. Relocating or renaming torrent content is not supported in this version.

## Supported protocols

BitTorrent v1 over TCP; HTTP, HTTPS and UDP trackers; magnet metadata exchange; DHT; PEX; IPv4/IPv6; downloading and seeding. Hybrid torrents use their v1 representation, including virtual padding.

Private torrents must be imported as `.torrent` files for tracker-only discovery. Magnets use public discovery before their private flag is known; a private result is rejected with instructions to use its `.torrent` file.

Pure v2 torrents, µTP, protocol encryption, web seeds, automatic port forwarding, torrent creation, remote control, and file relocation are not implemented. A TCP-only client cannot connect to peers that require unsupported transports or encryption.

## Resource design

Defaults are two active downloads, two seeds, 60 peer connections overall, and a shared 32 MiB payload budget. Default seeding stops at ratio 1.0; unlimited seeding and other limits are available per torrent. HDD/unknown-device scheduling is conservative; an explicit SSD profile permits the normal two-download concurrency on a volume.

The engine uses bounded block pipelines, streamed SHA-1 verification through CryptoKit, direct destination writes, virtual padding, and compact sidecars for skipped-file boundaries. It checkpoints durable state and verifies disk identity before trusting resumed content. Security-scoped bookmarks retain user-selected folder access.

Piece selection uses explicit Swift SIMD vectors. The benchmark confirms arm64 NEON instructions, but the optimized scalar reference is also auto-vectorized: current microbenchmarks demonstrate parity, not a whole-application speedup. See [SIMD measurements](scripts/simd-benchmark.md) and [validation](docs/VALIDATION.md) for measured results and remaining checks.

## Profiles: one database each

Use the **Profile** menu or the profile name beneath the app title to create, rename, and switch profiles. The current name appears below the window title. Only the selected profile runs transfers. Switching drains pending network and disk work, saves the old session, and opens the selected profile; previously running transfers resume when you return. New profiles start with an empty library and default settings.

Your existing database becomes **Default** in place. Additional profiles live in `Torrenza/Profiles/<UUID>/Torrenza.sqlite`, each with its name stored inside its database. Renaming changes the display name without moving the database or downloaded files. The app remembers the last selected profile using one macOS preference containing its identifier; torrent data and settings remain inside each profile database.

Each profile stores all of its metadata in **`Torrenza.sqlite`**: torrent metadata, destinations and security-scoped bookmarks, selected files, verified-piece state, settings, DHT contacts, saved interface state, and transfer statistics. Settings includes **Show Library Database in Finder**. In a sandboxed build the default location is:

```text
~/Library/Containers/dev.torrenza.app/Data/Library/Application Support/Torrenza/Torrenza.sqlite
```

The system SQLite library runs on a dedicated utility queue. Related changes commit atomically, unchanged records are not rewritten, and immutable torrent metadata is separate from frequently changing counters. DELETE journal mode means there is one persistent database file; a temporary rollback journal exists during writes or crash recovery. Quit Torrenza before copying the database as a simple backup. Folder bookmarks may require renewed permission on another Mac.

Each profile activation has a persistent session record with start/end times and downloaded/uploaded payload-byte totals. Lifetime counters are per profile and survive torrent removal. Accepted retransmissions and corrupt requested blocks count as transferred bytes; protocol overhead and unsolicited payloads do not. Session/lifetime totals appear in the footer and Settings. Checkpoints run during active work and on pause, profile switch, or quit; an abrupt termination may lose counters since the last checkpoint (normally at most 30 seconds), and the previous session is marked interrupted next launch.

A target profile is validated before the current one is stopped. An unreadable profile remains on disk, and other profiles remain accessible. Profile switching is unavailable while an import, file picker, or transfer edit is in progress.

Legacy JSON state and app-owned preferences migrate only after successful database writes. Downloaded payload files and selective-download boundary sidecars remain in their destination folders; they are not library metadata.

## Structure

| Target | Responsibility |
| --- | --- |
| TorrentCore | Types, bounded parsing, bitsets, resource reservations |
| TorrentWire | Peer TCP framing, trackers, DHT, metadata exchange, PEX |
| TorrentStorage | Safe asynchronous disk operations and durable checkpoints |
| TorrentEngine | Scheduling, lifecycle, resume, rate limits, tree presentation |
| Torrenza app | SwiftUI shell and native multicolumn outline table |
| TorrentProbe | Development-only command-line interoperability harness |

The app runs in App Sandbox with user-selected read/write access and incoming/outgoing networking. HTTP tracker support requires an App Transport Security exception because torrent metadata supplies arbitrary tracker hosts. The app does not silently opt into login/background services or continue after quit.

## Independent-client tests

`scripts/interop_fixture.py` generates deterministic local data and provides a loopback-only tracker. Use a separate client profile and the generated fixtures; never point the harness at personal downloads.

```sh
python3 scripts/interop_fixture.py prepare /tmp/torrenza-fixture --mib 16
python3 scripts/interop_fixture.py tracker --port 18765
# Seed private.torrent from /tmp/torrenza-fixture/seed using another client.
swift run TorrentProbe download /tmp/torrenza-fixture/private.torrent \
  /tmp/torrenza-fixture/download /tmp/torrenza-fixture/state 120
```

For seeding in the opposite direction use `TorrentProbe seed TORRENT EXISTING_DATA STATE_DIRECTORY SECONDS`. The harness disables public DHT bootstrap nodes and is not included in the GUI application.

## Distribution

Local builds are ad-hoc signed. Developer ID signing and notarization require your own Apple Developer credentials:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM \
SIGNING_IDENTITY='Developer ID Application: Your Name (YOUR_TEAM)' \
NOTARY_PROFILE=your-keychain-profile \
./scripts/release.sh
```

The release script validates the signature, submits the archive for notarization, staples the ticket, and produces `artifacts/Torrenza.zip` with a SHA-256 checksum. Credentials remain in the system keychain; no secrets are stored in this repository.

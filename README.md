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
- Use **File → Import from qBittorrent…** (also in the **+** menu) to choose a `BT_backup` folder, search its torrents, and select which ones to import. The usual macOS location is `~/Library/Application Support/qBittorrent/BT_backup`. Pause those torrents in qBittorrent first, then grant access to their saved download folders when prompted.
- qBittorrent imports reuse files in place, preserve saved file selections and per-torrent upload/download totals, and start paused. **Verify existing data** is checked by default; uncheck it to skip reading and hashing file contents and use qBittorrent’s saved piece progress instead. Paths and file sizes are still checked. This assumes the files have not changed since qBittorrent saved its progress; missing or invalid saved piece data requires verification. Explicit ratio limits are preserved; inherited limits use Torrenza’s default. Imported history does not count as traffic in the current Torrenza session. Backup files are only read. Duplicate torrents are disabled, and each import reports its result. **Stop After Current** finishes the current torrent before stopping the batch.
- Migration currently requires original torrent paths and selected files with their full expected logical size; missing, renamed, or shortened partial files are reported for attention. Separate unfinished-download folders, altered multi-file layouts, pure v2 torrents, and SQLite qBittorrent session backups are not supported. Categories, tags, queue order, file-priority levels, and time-based seeding limits are not migrated. qBittorrent’s partfile is not reused, so skipped-file boundary pieces may need downloading after you start a transfer.
- Choose a destination folder and the files to download. Existing files are preserved unless you explicitly choose to reuse and verify them.
- Expand volumes and folders to navigate. Folder pause/resume actions apply to their descendant torrents once each.
- Use Command-click to select multiple rows, Shift-click to select a range, or Command-A to select all visible rows. Start, Pause, Recheck, and Remove apply to the selected torrents, including folder descendants, once each. Selecting individual files does not apply transfer actions to their parent torrent. Reveal in Finder reveals all selected paths.
- Single-file torrents show their native file icon with a transfer-status badge; files inside multi-file torrents have plain file icons. Double-click a file to open it in its default app.
- Choose System, Light, or Dark appearance in Settings. The choice applies immediately and is saved with the current profile.
- Open the inspector for file selection, transfer information, trackers, seed limits, and destination storage profile. Individual peer details are intentionally omitted.
- Seeds and Peers show **connected / tracker-reported** counts. Peers includes seeds; unknown estimates display `—`. Stale estimates are dimmed and include their report time in a tooltip. Counts are never summed across trackers or torrents.
- Closing the window keeps transfers running. Quitting stops transfers and saves state. Normal system sleep is respected unless preventing idle sleep during downloads is enabled in Settings.
- Removing a torrent preserves its data. Deleting downloaded files is a separate confirmation. Relocating or renaming torrent content is not supported in this version.

## Supported protocols

BitTorrent v1 over TCP; HTTP, HTTPS and UDP trackers; magnet metadata exchange; DHT; PEX; IPv4/IPv6; downloading and seeding. Hybrid torrents use their v1 representation, including virtual padding.

Private torrents must be imported as `.torrent` files for tracker-only discovery. Magnets use public discovery before their private flag is known; a private result is rejected with instructions to use its `.torrent` file.

Pure v2 torrents, µTP, protocol encryption, web seeds, automatic port forwarding, torrent creation, remote control, and file relocation are not implemented. A TCP-only client cannot connect to peers that require unsupported transports or encryption.

## Network identity and privacy

Torrenza advertises a qBittorrent 5.1.0 compatibility identity in its peer ID, extension handshake, and HTTP tracker User-Agent. The random part of the peer ID is regenerated for each engine session. DHT uses the optional binary `qB` version marker; it has no human-readable application-name field. This changes advertised branding only: Torrenza still uses its own Swift engine and can be distinguished by protocol behavior.

**Your IP address is still visible to peers, trackers, and DHT nodes.** Client naming and randomized IDs do not hide it. Torrenza currently follows system routing and does not provide a proxy, VPN-interface binding, or a kill switch. To conceal your home IP, configure a VPN that carries all torrent traffic, including UDP, DNS, and IPv6, and blocks traffic when its tunnel disconnects. A browser proxy or a split tunnel that excludes Torrenza is insufficient. IP concealment has not been verified with a live VPN.

## Resource design

Defaults are two active downloads, two seeds, 60 peer connections overall, and a shared 32 MiB payload budget. Default seeding stops at ratio 1.0; unlimited seeding and other limits are available per torrent. HDD/unknown-device scheduling is conservative; an explicit SSD profile permits the normal two-download concurrency on a volume.

The engine uses bounded block pipelines, streamed SHA-1 verification through CryptoKit, direct destination writes, virtual padding, and compact sidecars for skipped-file boundaries. Startup optimistically restores saved piece progress without reading or hashing downloaded content, including after an interrupted session. Use **Recheck** to verify existing content explicitly. A torrent that encounters a storage error stops and retains its error across launches; after fixing the problem, choose **Resume** or **Recheck** to retry. Other torrents can continue. Security-scoped bookmarks retain user-selected folder access.

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

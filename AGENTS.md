# Torrenza Agent Guide

## Product and architecture

- Native macOS app, entirely Swift; do not introduce a C/C++ torrent engine. Target Apple Silicon and macOS 26+; keep memory use low and storage behavior suitable for SSDs and HDDs.
- `App/`: SwiftUI shell, AppKit `NSOutlineView`, Settings, import UI, and Debug diagnostics.
- `Sources/TorrentCore`: models, parsing, bitsets, resource budgets, qBittorrent import parsing.
- `Sources/TorrentWire`: peer protocol, trackers, DHT, and PEX.
- `Sources/TorrentStorage`: asynchronous filesystem work, SQLite, profiles, and ownership checks.
- `Sources/TorrentEngine`: transfer lifecycle, scheduling, progress, and persistence.
- `Sources/TorrentProbe`: development-only command-line interoperability harness.
- Tests mirror the package targets under `Tests/`. The GUI is built by Xcode, not `swift build`.
- `project.yml` is the XcodeGen source of truth. Regenerate the project after adding app files or changing build settings; preserve `App/Info.plist` and entitlements.
- Show only managed torrent content in the tree; do not scan unrelated files or add detailed peer panels.

## Session workflow

1. Read `git status` and relevant source before editing. Preserve unrelated work. Delegate bounded investigations when useful and return concise findings to the main thread.
2. Make the change and run checks appropriate to it, using the workflows below. Do not repeat unchanged checks without a reason. Documentation-only edits do not require running the complete test suite.
3. At the end of every session, build **Release**, verify its signature, and install it at `/Applications/Torrenza.app`. Do not finish with only a Debug build or an uninstalled Release. If the installed bundle already matches the successful build byte-for-byte, verify the signature and report that it is current; avoid restarting transfers unnecessarily.
4. Commit completed session changes and push the current branch to its configured remote. Stage only intended files, inspect the staged diff, keep unrelated work intact, and never force-push unless explicitly requested.
5. Report what changed, checks actually run, installed-app verification, and the pushed commit. If building, installing, committing, or pushing is blocked, state what remains unfinished. Respect any explicit user override of these steps.

## Build

Run commands from the repository root. Prerequisites: Xcode 26.6 or a compatible newer Xcode selected with `xcode-select`, and XcodeGen. `Package.swift` declares Swift tools 6.2; inspect the local toolchain when diagnosing compiler differences.

```sh
./scripts/build.sh
codesign --verify --deep --strict build/Build/Products/Release/Torrenza.app
```

`scripts/build.sh` regenerates the project and defaults to an ad-hoc signed Release build. For Debug:

```sh
CONFIGURATION=Debug ./scripts/build.sh
```

For an incremental build when project inputs are unchanged:

```sh
xcodebuild -project Torrenza.xcodeproj -scheme Torrenza \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

Keep logs under ignored `artifacts/` or `/private/tmp`. Check command exit status and `BUILD SUCCEEDED`, not only the final output line.

## Automated tests

```sh
swift test
swift test -c release
# Example focused engine/storage regression run:
swift test --filter 'TorrentEngineTests|TorrentStorageTests'
```

Use `swift test --filter <test-name>` for a narrower regression. Run the full suite for changes spanning targets; use optimized tests when behavior or performance depends on Release compilation. Tests include both XCTest and Swift Testing; inspect both summaries. Do not hard-code historical test counts as current evidence.

Network integration tests bind loopback TCP/UDP sockets. A sandbox denial is an environment issue: rerun with the required permission rather than weakening assertions. Public discovery is excluded from ordinary tests; the explicit opt-in check is:

```sh
TORRENZA_PUBLIC_DHT=1 swift test --filter publicUbuntuDiscovery
```

For lifecycle/storage changes, cover saved progress, paused and running restores, explicit Recheck, missing/replaced files, per-torrent quarantine, persistence across relaunch, and isolation of unaffected torrents. Use temporary fixture directories, never personal downloads.

## Native UI and profile smoke checks

**Diagnostic flags are Debug-only. Release ignores them and opens the real user profile.** Never use Release diagnostic arguments as an isolation mechanism.

```sh
open -n build/Build/Products/Debug/Torrenza.app --args \
  --ui-fixture --ui-dark --ui-narrow --ui-search-check --ui-exit
```

`--ui-fixture` supplies synthetic transfers without starting or persisting the real engine. Choose relevant variations rather than running every combination:

| Area | Additional flags |
| --- | --- |
| Light appearance | Omit `--ui-dark` |
| Wide window / long profile title | `--ui-wide --ui-long-profile` instead of `--ui-narrow` |
| Native file icons and torrent badges | `--ui-file-badges` |
| Settings appearance | `--ui-appearance-check` |
| Native multiselection | `--ui-multiselect-check` |
| Column sorting within folders | `--ui-sort-check` |
| qBittorrent import selection | `--ui-qb-import` |
| Import without hashing | `--ui-qb-import --ui-qb-skip-verification` |

PNG and text reports are written to `Torrenza-UI` inside the sandbox's temporary directory, normally `~/Library/Containers/dev.torrenza.app/Data/tmp/Torrenza-UI`. Read the reports and inspect screenshots. Reports reuse filenames: check modification times against this launch or preserve the old reports separately so stale `PASS` output cannot count as new evidence. `open` returning successfully proves only that the launch request was accepted. Some layer-backed toolbar/footer content can be absent in diagnostic screenshots; distinguish capture artifacts from verified live UI issues.

The AppModel/profile lifecycle check uses separate temporary databases and a separate preferences suite:

```sh
open -n build/Build/Products/Debug/Torrenza.app --args --profile-smoke
```

Read `Torrenza-Profile-Smoke/result.txt` in the sandbox temporary directory; success ends with `PROFILE SMOKE PASSED`. It exercises profile operations and shutdown directly, not a full accessibility-driven Quit-menu test.

## User profiles and backups

Normal Debug and installed Release use the same bundle ID, `dev.torrenza.app`, and the same sandbox profile. Do not run both against the real library simultaneously or assume a missing list needs a debug-to-release migration.

- Default database: `~/Library/Containers/dev.torrenza.app/Data/Library/Application Support/Torrenza/Torrenza.sqlite`.
- Additional profiles: `Profiles/<UUID>/Torrenza.sqlite` beneath the same `Torrenza` directory.
- Unsandboxed engine tools can use a different Application Support location. Always pass an explicit temporary `stateDirectory` to test tools.
- Each database contains torrent metadata, bookmarks, settings, saved progress, UI state, and statistics. Payload and selective-download sidecars stay in download destinations.
- SQLite currently uses DELETE journaling. Do not copy only the main database during writes. Use SQLite's backup API for a consistent live snapshot, or quit all instances before a simple filesystem copy.

Example consistent backup of the Default profile (adjust `source` for another profile):

```sh
python3 - <<'PY'
from pathlib import Path
from datetime import datetime
import sqlite3

source = Path.home() / 'Library/Containers/dev.torrenza.app/Data/Library/Application Support/Torrenza/Torrenza.sqlite'
folder = Path.home() / 'Library/Application Support/Torrenza Backups' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
folder.mkdir(parents=True, mode=0o700)
backup = folder / 'Torrenza.sqlite'
with sqlite3.connect(source.as_uri() + '?mode=ro', uri=True) as original, sqlite3.connect(backup) as copy:
    original.backup(copy)
    assert copy.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
backup.chmod(0o600)
print(backup)
PY
```

Before restoring or editing a live profile, quit all app instances and preserve the current database and any journal/WAL/SHM files. Do not combine a restored database with stale journal files. Verify integrity and profile/torrent counts afterward. A profile backup does not back up downloads; bookmarks may need renewed permission on another Mac. Keep databases, tracker credentials, personal torrent metadata, and screenshots of the real library out of Git.

Startup deliberately trusts saved progress, even after an interrupted session. Do not reintroduce automatic payload hashing or scans of every saved destination. Defer payload access until needed. Storage errors stop and quarantine the affected torrent, persist its error, and require an explicit retry; they must not recreate missing payload or automatically resume after volume notifications. Recheck remains an explicit action.

Default seed ratio is 1.0. `Seeding` means available to upload; `Completed` means finished and stopped. Start still respects the configured ratio, so a torrent already over its limit stops again. Use that torrent's **Seed until → Unlimited** or a higher limit when requested; do not silently change the global default or fabricate transfer counters.

## CPU, memory, and I/O profiling

Measure the **Release GUI** for GUI performance claims. Record the build, profile/torrent count, active transfers, storage type, peer count, workload duration, and whether measurement covers startup or steady state. Use a synthetic profile where possible; do not initiate payload rechecks or destructive fault injection on the user's library.

Find and verify the intended process before attaching:

```sh
pgrep -fl 'Torrenza.app/Contents/MacOS/Torrenza'
TORRENZA_PID=12345 # Replace with the verified PID, not a shell/system variable.
mkdir -p artifacts
ps -p "$TORRENZA_PID" -o pid,etime,%cpu,rss,command
/usr/bin/sample "$TORRENZA_PID" 5 -file artifacts/torrenza-sample.txt
/usr/bin/vmmap -summary "$TORRENZA_PID" > artifacts/torrenza-vmmap.txt
xcrun xctrace list templates
xcrun xctrace record --template 'Time Profiler' \
  --attach "$TORRENZA_PID" --time-limit 30s \
  --output artifacts/torrenza-time.trace
```

Use a fresh trace filename for repeated measurements. Instruments' Allocations and File Activity tools can investigate memory growth and filesystem work when available. Attachment may require macOS permissions; report restrictions instead of claiming a measurement succeeded. `ps` RSS is in KiB and is not identical to Activity Monitor's memory footprint. Compare equivalent workloads before/after and distinguish a busy hashing stack from a deadlock. Inspect open files or samples before assuming a wrong-profile problem.

Probe measurements are engine-only, not GUI memory evidence. SIMD instructions alone are not evidence of a speedup; see `scripts/simd-benchmark.md` for reproducible commands. `docs/VALIDATION.md` contains historical results and explicitly uncompleted large-workload/HDD checks; do not present them as newly executed tests.

## Independent-client interoperability

Use generated fixtures and a separate qBittorrent profile. Never point the harness at personal download directories. Example (choose a fresh directory on each run):

```sh
python3 scripts/interop_fixture.py prepare /private/tmp/torrenza-fixture --mib 16
python3 scripts/interop_fixture.py tracker --port 18765
```

Run the tracker in a separate terminal. Seed the generated `private.torrent` from the fixture's `seed` directory with the independent client, then run:

```sh
swift run TorrentProbe download /private/tmp/torrenza-fixture/private.torrent \
  /private/tmp/torrenza-fixture/download /private/tmp/torrenza-fixture/state 120
```

The probe accepts `download|magnet|seed TORRENT_OR_MAGNET DESTINATION STATE_DIRECTORY [SECONDS=120]` and disables public DHT bootstrap. For optimized measurements use `swift run -c release TorrentProbe ...`. Check the resulting data against `manifest.json` SHA-256 and distinguish loopback interoperability from real-swarm coverage.

## Install and verify Release

After a successful Release build and signature check, compare it with the installed bundle:

```sh
diff -qr build/Build/Products/Release/Torrenza.app /Applications/Torrenza.app
```

If identical, verify the installed signature and leave the running app undisturbed. Otherwise, request normal quit, wait for the process to exit and checkpoint, preserve the existing app bundle, and install into a fresh destination. Do not routinely force-quit or delete a profile to fix startup.

```sh
if pgrep -x Torrenza >/dev/null; then
  osascript -e 'tell application id "dev.torrenza.app" to quit'
fi
pgrep -x Torrenza
```

Proceed only when no Torrenza process remains. If the app is unresponsive, diagnose it and create a consistent profile backup before considering forced termination. Preserve the old bundle when it exists:

```sh
mv /Applications/Torrenza.app "/private/tmp/Torrenza-before-install-$(date +%Y%m%d-%H%M%S).app"
ditto build/Build/Products/Release/Torrenza.app /Applications/Torrenza.app
codesign --verify --deep --strict /Applications/Torrenza.app
open -a /Applications/Torrenza.app
```

Skip `mv` for a first installation. If installation fails, restore the preserved bundle. Verify the launched process path is `/Applications/Torrenza.app/Contents/MacOS/Torrenza`, that the opening-profile overlay clears, and that the expected library appears. Launch success alone is not UI verification. Preserve the user's profile and downloads throughout.

Local installation uses ad-hoc signing. `scripts/release.sh` is the separate Developer ID/notarization distribution workflow; it requires `DEVELOPMENT_TEAM`, `SIGNING_IDENTITY`, and an existing `NOTARY_PROFILE` in the keychain. It produces `artifacts/Torrenza.zip` and a checksum. Do not invoke it for routine local installs or claim notarization from an ad-hoc signature.

## Commit and push

```sh
git diff --check
git status --short
git diff
git add AGENTS.md # Replace with the explicit files belonging to this session.
git diff --cached --check
git diff --cached --stat
git commit -m "Describe the completed change"
git push
git status --short
```

Check the branch, upstream, and remote before pushing. If no upstream exists, use an explicit remote/branch after confirming the intended destination. Verify push success and branch synchronization; a local commit alone is not completion. Never stage generated builds, private backups, diagnostics, or unrelated modifications. Leave no unexplained session changes behind.

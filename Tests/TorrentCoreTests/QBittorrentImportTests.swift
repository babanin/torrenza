import Foundation
import Testing
@testable import TorrentCore

struct QBittorrentImportTests {
    private func bytes(_ text: String) -> BencodeValue { .bytes(Data(text.utf8)) }
    private func fixture(multi: Bool = false, lengths: [Int64]? = nil, padding: Set<Int> = [],
                         resumeChanges: [String: BencodeValue] = [:],
                         body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = root.appendingPathComponent("BT_backup")
        let destination = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lengths = lengths ?? (multi ? [2, 2] : [4])
        let total = lengths.reduce(0, +)
        var info: [String: BencodeValue] = ["name": bytes("example"), "piece length": .integer(4), "pieces": .bytes(Data(repeating: 7, count: Int((total + 3) / 4) * 20))]
        if multi {
            info["files"] = .list(lengths.enumerated().map { index, length in
                .dictionary(["path": .list([bytes(index == 0 ? "first" : index == 1 ? "second" : "file\(index)")]),
                    "length": .integer(length), "attr": bytes(padding.contains(index) ? "p" : "")])
            })
        } else { info["length"] = .integer(total) }
        let encoded = Bencode.encode(.dictionary(["info": .dictionary(info)]))
        let meta = try MetainfoParser.parse(encoded)
        try encoded.write(to: backup.appendingPathComponent(meta.id + ".torrent"))
        var resume: [String: BencodeValue] = ["info-hash": .bytes(meta.infoHash), "save_path": bytes(destination.path),
            "qBt-contentLayout": bytes("Original"), "file_priority": .list(Array(repeating: .integer(1), count: multi ? lengths.count : 1)),
            "qBt-ratioLimit": .integer(-2000), "total_downloaded": .integer(12), "total_uploaded": .integer(24)]
        resume.merge(resumeChanges) { _, new in new }
        try Bencode.encode(.dictionary(resume)).write(to: backup.appendingPathComponent(meta.id + ".fastresume"))
        try body(backup, destination)
    }

    @Test func scansCompactCandidatesAndReloadsSelection() throws {
        try fixture(multi: true, resumeChanges: ["file_priority": .list([.integer(0), .integer(7)]), "qBt-ratioLimit": .integer(1500)]) { backup, destination in
            let candidates = try QBittorrentImport.scan(directory: backup)
            #expect(candidates.count == 1)
            let row = try #require(candidates.first)
            #expect(row.issue == nil)
            #expect(row.name == "example" && row.destination?.path == destination.path)
            #expect(row.selectedFiles == [1])
            #expect(row.totalBytes == 4 && row.fileCount == 2)
            #expect(row.downloadedBytes == 12 && row.uploadedBytes == 24)
            #expect(row.seedRatio == 1.5 && !row.usesDefaultSeedRatio)
            let payload = try QBittorrentImport.load(candidate: row)
            #expect(payload.savedVerifiedPieces == nil)
            #expect(payload.metainfo.id == row.id)
            #expect(payload.metainfo.files.count == 2)
        }
    }

    @Test func importsSavedCompleteAndPartialPiecesWithoutInventingCompletion() throws {
        for (flags, expected) in [([UInt8](arrayLiteral: 1, 1, 1), 3), ([1, 0, 3], 2), ([2, 0, 0], 0)] {
            for seedMode: Int64 in [0, 1] {
                try fixture(lengths: [12], resumeChanges: ["file-format": bytes("libtorrent resume file"),
                    "file-version": .integer(1), "pieces": .bytes(Data(flags)), "seed_mode": .integer(seedMode)]) { backup, _ in
                    let candidate = try #require(QBittorrentImport.scan(directory: backup).first)
                    let payload = try QBittorrentImport.load(candidate: candidate, useSavedPieceStatus: true)
                    #expect(payload.savedVerifiedPieces?.count == 3)
                    #expect(payload.savedVerifiedPieces?.setCount == expected)
                    #expect(payload.savedVerifiedPieces?[0] == (flags[0] & 1 != 0))
                }
            }
        }
    }

    @Test func readsVersionTwoMSBPieceBits() throws {
        try fixture(lengths: [36], resumeChanges: ["file-format": bytes("libtorrent resume file"),
            "file-version": .integer(2), "pieces": .bytes(Data([0x81, 0x80])),
            "verified": .bytes(Data([0, 0])), "seed_mode": .integer(1)]) { backup, _ in
            let candidate = try #require(QBittorrentImport.scan(directory: backup).first)
            let bits = try #require(QBittorrentImport.load(candidate: candidate, useSavedPieceStatus: true).savedVerifiedPieces)
            #expect(bits.count == 9 && bits.setCount == 3)
            #expect(bits[0] && bits[7] && bits[8] && !bits[1])
        }
    }

    @Test func rejectsMissingUnknownAndMalformedSavedPieceMapsOnlyForUncheckedImport() throws {
        let valid: [String: BencodeValue] = ["file-format": bytes("libtorrent resume file"),
            "file-version": .integer(1), "pieces": .bytes(Data([1]))]
        let invalid: [[String: BencodeValue]] = [
            ["file-format": bytes("unknown")], ["file-version": .integer(3)], ["file-version": bytes("1")],
            ["pieces": .bytes(Data())], ["pieces": .bytes(Data([1, 1]))], ["pieces": .integer(1)],
            ["pieces": .bytes(Data([4]))], ["seed_mode": .integer(2)], ["seed_mode": bytes("1")],
            ["verified": .bytes(Data([0x81]))], ["verified": .integer(1)],
            ["file-version": .integer(2), "pieces": .bytes(Data([1]))],
            ["file-version": .integer(2), "pieces": .bytes(Data([0x80, 0]))]
        ]
        for change in invalid {
            try fixture(resumeChanges: valid.merging(change) { _, new in new }) { backup, _ in
                let candidate = try #require(QBittorrentImport.scan(directory: backup).first)
                #expect(candidate.issue == nil)
                #expect(try QBittorrentImport.load(candidate: candidate).savedVerifiedPieces == nil)
                #expect(throws: TorrentError.self) { try QBittorrentImport.load(candidate: candidate, useSavedPieceStatus: true) }
            }
        }
        try fixture(resumeChanges: ["seed_mode": .integer(1)]) { backup, _ in
            let candidate = try #require(QBittorrentImport.scan(directory: backup).first)
            do {
                _ = try QBittorrentImport.load(candidate: candidate, useSavedPieceStatus: true)
                Issue.record("Missing piece map should require verification")
            } catch {
                #expect(error.localizedDescription.contains("Enable Verify existing data"))
            }
        }
    }

    @Test func excludesSkippedFileBoundariesButKeepsPaddingBackedPieces() throws {
        for padding: Set<Int> in [[], [1]] {
            try fixture(multi: true, lengths: [6, 2, 4], padding: padding,
                resumeChanges: ["file-format": bytes("libtorrent resume file"), "file-version": .integer(1),
                    "pieces": .bytes(Data([1, 1, 1])), "file_priority": .list([.integer(1), .integer(0), .integer(1)])]) { backup, _ in
                let candidate = try #require(QBittorrentImport.scan(directory: backup).first)
                let bits = try #require(QBittorrentImport.load(candidate: candidate, useSavedPieceStatus: true).savedVerifiedPieces)
                #expect(bits[0] && bits[2])
                #expect(bits[1] == padding.contains(1))
            }
        }
    }

    @Test func reloadUsesCurrentPieceMapFromSameResumeRead() throws {
        try fixture(resumeChanges: ["file-format": bytes("libtorrent resume file"), "file-version": .integer(1),
            "pieces": .bytes(Data([0]))]) { backup, _ in
            let candidate = try #require(QBittorrentImport.scan(directory: backup).first)
            var resume = try #require(Bencode.decode(Data(contentsOf: candidate.resumeURL)).dictionaryValue)
            resume["pieces"] = .bytes(Data([1]))
            try Bencode.encode(.dictionary(resume)).write(to: candidate.resumeURL)
            #expect(try QBittorrentImport.load(candidate: candidate, useSavedPieceStatus: true).savedVerifiedPieces?.isComplete == true)
        }
    }

    @Test func ratioPolicies() throws {
        for (value, expected, inherited) in [(BencodeValue.integer(-2000), nil as Double?, true), (.integer(-1000), nil, false), (bytes("2.5"), 2.5, false)] {
            try fixture(resumeChanges: ["qBt-ratioLimit": value]) { backup, _ in
                let row = try #require(QBittorrentImport.scan(directory: backup).first)
                #expect(row.issue == nil && row.seedRatio == expected && row.usesDefaultSeedRatio == inherited)
            }
        }
    }

    @Test func rejectsIncompatibleOrUnsafeResumeFields() throws {
        let changes: [[String: BencodeValue]] = [
            ["info-hash": .bytes(Data(repeating: 0, count: 20))],
            ["save_path": bytes("relative/path")], ["save_path": bytes("/tmp/../outside")],
            ["qBt-contentLayout": bytes("NoSubfolder")], ["qBt-contentLayout": bytes("Subfolder")],
            ["mapped_files": .list([bytes("renamed"), bytes("")])],
            ["qBt-downloadPath": bytes("/tmp/elsewhere")],
            ["file_priority": .list([.integer(1)])], ["file_priority": .list([.integer(0), .integer(0)])],
            ["qBt-ratioLimit": bytes("nan")]
        ]
        for change in changes {
            try fixture(multi: true, resumeChanges: change) { backup, _ in
                let row = try #require(QBittorrentImport.scan(directory: backup).first)
                #expect(row.issue != nil)
                #expect(throws: TorrentError.self) { try QBittorrentImport.load(candidate: row) }
            }
        }
    }

    @Test func missingOrCorruptPairsRemainVisible() throws {
        try fixture { backup, _ in
            let original = try #require(QBittorrentImport.scan(directory: backup).first)
            try FileManager.default.removeItem(at: original.resumeURL)
            let missing = try #require(QBittorrentImport.scan(directory: backup).first)
            #expect(missing.name == "example" && missing.issue != nil)
            try Data("broken".utf8).write(to: backup.appendingPathComponent("broken.torrent"))
            let rows = try QBittorrentImport.scan(directory: backup)
            #expect(rows.count == 2 && rows.allSatisfy { $0.issue != nil })
        }
    }

    @Test func reloadingRejectsChangesSinceScan() throws {
        try fixture { backup, _ in
            let row = try #require(QBittorrentImport.scan(directory: backup).first)
            var resume = try #require(Bencode.decode(Data(contentsOf: row.resumeURL)).dictionaryValue)
            resume["save_path"] = bytes("/tmp/changed")
            try Bencode.encode(.dictionary(resume)).write(to: row.resumeURL)
            #expect(throws: TorrentError.self) { try QBittorrentImport.load(candidate: row) }
        }
    }

    @Test func preflightRequiresOnlySelectedExistingFiles() throws {
        try fixture(multi: true, resumeChanges: ["file_priority": .list([.integer(0), .integer(1)])]) { backup, destination in
            let folder = destination.appendingPathComponent("example")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("second")
            try Data([1, 2]).write(to: file)
            let payload = try QBittorrentImport.load(candidate: #require(QBittorrentImport.scan(directory: backup).first))
            try QBittorrentImport.preflight(payload: payload)
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("first").path))
            try Data([1]).write(to: file)
            #expect(throws: TorrentError.self) { try QBittorrentImport.preflight(payload: payload) }
            #expect(try Data(contentsOf: file) == Data([1]))
            try FileManager.default.removeItem(at: file)
            #expect(throws: TorrentError.self) { try QBittorrentImport.preflight(payload: payload) }
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func preflightRejectsSymlinkFilesAndFolders() throws {
        try fixture(multi: true) { backup, destination in
            let payload = try QBittorrentImport.load(candidate: #require(QBittorrentImport.scan(directory: backup).first))
            let folder = destination.appendingPathComponent("example")
            let realFolder = destination.appendingPathComponent("real")
            try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
            try Data([1, 2]).write(to: realFolder.appendingPathComponent("first"))
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: realFolder)
            #expect(throws: TorrentError.self) { try QBittorrentImport.preflight(payload: payload) }
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("first"), withDestinationURL: realFolder.appendingPathComponent("first"))
            #expect(throws: TorrentError.self) { try QBittorrentImport.preflight(payload: payload) }
        }
    }
}

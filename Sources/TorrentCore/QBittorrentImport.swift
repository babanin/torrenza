import Foundation
import Darwin

/// A compact row for an import chooser. Piece hashes and resume bitfields are not retained.
public struct QBittorrentImportCandidate: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var torrentURL: URL
    public var resumeURL: URL
    public var destination: URL?
    public var selectedFiles: Set<Int>
    public var downloadedBytes: Int64
    public var uploadedBytes: Int64
    public var seedRatio: Double?
    public var usesDefaultSeedRatio: Bool
    public var totalBytes: Int64?
    public var fileCount: Int?
    public var issue: String?

    public init(id: String, name: String, torrentURL: URL, resumeURL: URL, destination: URL? = nil,
                selectedFiles: Set<Int> = [], downloadedBytes: Int64 = 0, uploadedBytes: Int64 = 0,
                seedRatio: Double? = nil, usesDefaultSeedRatio: Bool = true,
                totalBytes: Int64? = nil, fileCount: Int? = nil, issue: String? = nil) {
        self.id = id; self.name = name; self.torrentURL = torrentURL; self.resumeURL = resumeURL
        self.destination = destination; self.selectedFiles = selectedFiles
        self.downloadedBytes = downloadedBytes; self.uploadedBytes = uploadedBytes
        self.seedRatio = seedRatio; self.usesDefaultSeedRatio = usesDefaultSeedRatio
        self.totalBytes = totalBytes; self.fileCount = fileCount; self.issue = issue
    }
}

public struct QBittorrentImportPayload: Sendable {
    public let candidate: QBittorrentImportCandidate
    public let metainfo: TorrentMetainfo
    /// qBittorrent's saved complete pieces, populated only when explicitly requested.
    public let savedVerifiedPieces: PieceBitset?
}

public enum QBittorrentImport {
    /// Reads only the chosen backup directory, never the downloaded content.
    /// Call off the main actor; cancelling its Task stops between candidates.
    public static func scan(directory: URL) throws -> [QBittorrentImportCandidate] {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "torrent" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var candidates: [QBittorrentImportCandidate] = []
        var identities = Set<String>()
        for url in files {
            try Task.checkCancellation()
            var candidate = inspect(torrentURL: url).candidate
            if !identities.insert(candidate.id).inserted {
                candidate.issue = "Duplicate torrent in this backup folder."
                candidate.id += ":" + url.lastPathComponent
            }
            candidates.append(candidate)
        }
        return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Re-reads the selected pair so changes made after the chooser opened cannot silently
    /// redirect an import. Destination access must be granted before calling preflight.
    public static func load(candidate: QBittorrentImportCandidate, useSavedPieceStatus: Bool = false) throws -> QBittorrentImportPayload {
        try Task.checkCancellation()
        let result = inspect(torrentURL: candidate.torrentURL, useSavedPieceStatus: useSavedPieceStatus)
        if let issue = result.candidate.issue { throw TorrentError.unsupported(issue) }
        guard result.candidate == candidate, let metainfo = result.metainfo else {
            throw TorrentError.storage("qBittorrent data changed. Refresh the import list and try again.")
        }
        return QBittorrentImportPayload(candidate: result.candidate, metainfo: metainfo,
            savedVerifiedPieces: result.savedVerifiedPieces)
    }

    /// Read-only inspection of precisely the selected paths. Missing, shortened or renamed
    /// files need to be repaired in qBittorrent before migrating; nothing is created here.
    public static func preflight(payload: QBittorrentImportPayload) throws {
        guard let destination = payload.candidate.destination else { throw TorrentError.storage("Missing download location.") }
        try preflight(metainfo: payload.metainfo, destination: destination, selectedFiles: payload.candidate.selectedFiles)
    }

    public static func preflight(metainfo: TorrentMetainfo, destination: URL, selectedFiles: Set<Int>) throws {
        let root = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw TorrentError.storage("Cannot access the download folder: \(destination.path)") }
        defer { Darwin.close(root) }
        for file in metainfo.files where selectedFiles.contains(file.index) && !file.isPadding {
            try Task.checkCancellation()
            var parent = dup(root)
            guard parent >= 0 else { throw TorrentError.storage("Cannot inspect download folder.") }
            defer { Darwin.close(parent) }
            for component in file.path.dropLast() {
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw TorrentError.storage("Missing or inaccessible folder for \(file.path.joined(separator: "/")).") }
                Darwin.close(parent); parent = next
            }
            var attributes = stat()
            guard let name = file.path.last,
                  fstatat(parent, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
                  attributes.st_mode & S_IFMT == S_IFREG else {
                throw TorrentError.storage("Missing or unsupported file: \(file.path.joined(separator: "/")).")
            }
            guard attributes.st_size == file.length else {
                throw TorrentError.storage("File size does not match: \(file.path.joined(separator: "/")). Finish or repair this torrent in qBittorrent first.")
            }
        }
    }

    private static func inspect(torrentURL: URL, useSavedPieceStatus: Bool = false)
        -> (candidate: QBittorrentImportCandidate, metainfo: TorrentMetainfo?, savedVerifiedPieces: PieceBitset?) {
        let resumeURL = torrentURL.deletingPathExtension().appendingPathExtension("fastresume")
        var candidate = QBittorrentImportCandidate(id: torrentURL.lastPathComponent, name: torrentURL.deletingPathExtension().lastPathComponent,
            torrentURL: torrentURL, resumeURL: resumeURL)
        do {
            let metainfo = try MetainfoParser.parse(readBounded(torrentURL))
            candidate.id = metainfo.id; candidate.name = metainfo.name
            candidate.totalBytes = metainfo.totalLength
            candidate.fileCount = metainfo.files.filter { !$0.isPadding }.count
            guard let resume = try Bencode.decode(readBounded(resumeURL)).dictionaryValue else {
                throw TorrentError.invalidMetainfo("Invalid qBittorrent resume data.")
            }
            guard resume["info-hash"]?.dataValue == metainfo.infoHash else {
                throw TorrentError.invalidMetainfo("The torrent and resume data have different info hashes.")
            }
            let activePath = resume["save_path"]?.stringValue
            let savedPath = resume["qBt-savePath"]?.stringValue
            candidate.destination = try absoluteDirectory(nonempty(activePath) ?? nonempty(savedPath))
            if let alternate = nonempty(resume["qBt-downloadPath"]?.stringValue),
               try absoluteDirectory(alternate) != candidate.destination {
                throw TorrentError.unsupported("A separate unfinished-download folder is not supported. Finish or move this torrent in qBittorrent first.")
            }
            if let savedPath = nonempty(savedPath), try absoluteDirectory(savedPath) != candidate.destination {
                throw TorrentError.unsupported("This torrent is in a temporary download location. Move it to its final location in qBittorrent first.")
            }
            if let mapped = resume["mapped_files"] {
                guard let paths = mapped.listValue, paths.allSatisfy({ $0.stringValue == "" }) else {
                    throw TorrentError.unsupported("Renamed or remapped files are not supported. Restore their original names in qBittorrent first.")
                }
            }
            if let layout = resume["qBt-contentLayout"]?.stringValue {
                guard layout == "Original" || (!metainfo.isMultiFile && layout == "NoSubfolder") else {
                    throw TorrentError.unsupported("The qBittorrent content layout is not supported. Use the original torrent layout.")
                }
            } else if resume["qBt-hasRootFolder"]?.intValue == 0 && metainfo.isMultiFile {
                throw TorrentError.unsupported("Torrents with their root folder removed are not supported.")
            }
            if let priorities = resume["file_priority"] {
                guard let values = priorities.listValue, values.count == metainfo.files.count,
                      values.allSatisfy({ value in value.intValue.map { (0...7).contains($0) } ?? false }) else {
                    throw TorrentError.invalidMetainfo("Invalid saved file selection.")
                }
                candidate.selectedFiles = Set(metainfo.files.filter { !$0.isPadding && values[$0.index].intValue! > 0 }.map(\.index))
            } else { candidate.selectedFiles = Set(metainfo.files.filter { !$0.isPadding }.map(\.index)) }
            guard !candidate.selectedFiles.isEmpty else { throw TorrentError.unsupported("No files are selected in qBittorrent.") }
            candidate.downloadedBytes = max(0, resume["total_downloaded"]?.intValue ?? 0)
            candidate.uploadedBytes = max(0, resume["total_uploaded"]?.intValue ?? 0)
            let ratio: Double
            if let value = resume["qBt-ratioLimit"] {
                if let integer = value.intValue { ratio = Double(integer) / 1000 }
                else if let text = value.stringValue, let value = Double(text) { ratio = value }
                else { throw TorrentError.invalidMetainfo("Invalid saved seeding ratio.") }
            } else { ratio = -2 }
            guard ratio.isFinite, ratio >= 0 || ratio == -1 || ratio == -2 else { throw TorrentError.invalidMetainfo("Invalid saved seeding ratio.") }
            candidate.usesDefaultSeedRatio = ratio == -2
            candidate.seedRatio = ratio >= 0 ? ratio : nil
            let savedPieces = useSavedPieceStatus
                ? try savedPieceStatus(resume: resume, metainfo: metainfo, selectedFiles: candidate.selectedFiles) : nil
            return (candidate, metainfo, savedPieces)
        } catch {
            candidate.issue = error.localizedDescription
            return (candidate, nil, nil)
        }
    }

    /// libtorrent resume v1 stores flags per piece; v2 stores MSB-first bitmaps.
    /// https://www.libtorrent.org/manual-ref.html#fast-resume
    private static func savedPieceStatus(resume: [String: BencodeValue], metainfo: TorrentMetainfo,
                                         selectedFiles: Set<Int>) throws -> PieceBitset {
        func invalid() -> TorrentError {
            .unsupported("qBittorrent's saved piece status is missing or unsupported. Enable Verify existing data to import this torrent.")
        }
        guard resume["file-format"]?.stringValue == "libtorrent resume file",
              let version = resume["file-version"]?.intValue, version == 1 || version == 2,
              let pieces = resume["pieces"]?.dataValue else { throw invalid() }
        if let value = resume["seed_mode"] {
            guard let flag = value.intValue, flag == 0 || flag == 1 else { throw invalid() }
        }
        let count = metainfo.pieceHashes.count
        var have = PieceBitset(count: count)
        if version == 1 {
            guard pieces.count == count else { throw invalid() }
            for (index, flags) in pieces.enumerated() {
                guard flags & ~UInt8(3) == 0 else { throw invalid() }
                have[index] = flags & 1 != 0
            }
        } else {
            guard let parsed = try? PieceBitset(count: count, bytes: pieces) else { throw invalid() }
            have = parsed
        }
        // libtorrent also accepts a separate verified bitmap in either format.
        if let value = resume["verified"] {
            guard let bytes = value.dataValue,
                  (try? PieceBitset(count: count, bytes: bytes)) != nil else { throw invalid() }
        }
        // Opting out of verification explicitly trusts qBittorrent's HAVE bits,
        // including seed mode's assumed completion. VERIFIED alone is not HAVE;
        // seed_mode without a valid piece map never implies complete data.
        // Skipped file bytes may exist only in qBittorrent's partfile, which is not
        // migrated. A piece spanning one of those bytes cannot be claimed complete.
        for file in metainfo.files where !file.isPadding && !selectedFiles.contains(file.index) && file.length > 0 {
            let first = Int(file.offset / Int64(metainfo.pieceLength))
            let last = Int((file.offset + file.length - 1) / Int64(metainfo.pieceLength))
            for index in first...last { have[index] = false }
        }
        return have
    }

    private static func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    private static func absoluteDirectory(_ path: String?) throws -> URL {
        guard let path, path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/").contains("..") else {
            throw TorrentError.invalidMetainfo("The saved download location is missing or is not a safe absolute path.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    private static func readBounded(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw TorrentError.storage("Cannot read \(url.lastPathComponent): \(String(cString: strerror(errno))).") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= Bencode.maximumBytes else {
            throw TorrentError.invalidMetainfo("\(url.lastPathComponent) must be a regular file of at most 16 MiB.")
        }
        guard let data = try handle.read(upToCount: Bencode.maximumBytes + 1), !data.isEmpty, data.count <= Bencode.maximumBytes else {
            throw TorrentError.invalidMetainfo("\(url.lastPathComponent) is empty or exceeds 16 MiB.")
        }
        return data
    }
}

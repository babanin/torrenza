import Foundation
import TorrentCore

/// Counts only partial peers: complete seeds contribute the same rarity to every
/// piece and need neither a full count update nor a scan on each picker call.
struct PiecePickerState {
    var availability: [UInt32]
    var seedCount = 0
    var inFlight: PieceBitset
    var openIndices: [Int] = []
    var cursor: Int
    var randomState: UInt64

    init(count: Int) {
        availability = Array(repeating: 0, count: count)
        inFlight = PieceBitset(count: count)
        cursor = count > 0 ? Int.random(in: 0..<count) : 0
        randomState = UInt64.random(in: 1...UInt64.max)
    }

    mutating func chooseTie(_ count: Int) -> Bool {
        // A small per-torrent generator avoids asking the system RNG for every
        // equal-rarity candidate. This only spreads requests, never secrets.
        randomState ^= randomState << 13
        randomState ^= randomState >> 7
        randomState ^= randomState << 17
        return randomState % UInt64(count) == 0
    }

    mutating func adjust(_ bits: PieceBitset, adding: Bool) {
        var next = bits.firstSetIndex()
        while let index = next {
            if adding { availability[index] += 1 }
            else { availability[index] -= 1 }
            next = bits.firstSetIndex(from: index + 1)
        }
    }
}

extension EngineSession {
    func replacePeerAvailability(key: UUID, availability: PieceBitset) {
        guard var peer = peers[key] else { return }
        removePeerAvailability(peer)
        peer.availability = availability
        peer.availablePieceCount = availability.setCount
        peers[key] = peer
        if peer.isSeed { picker.seedCount += 1 }
        else { picker.adjust(availability, adding: true) }
    }

    func recordPeerHave(key: UUID, index: Int) {
        guard var peer = peers[key], !peer.availability[index] else { return }
        peer.availability[index] = true
        peer.availablePieceCount += 1
        peers[key] = peer
        if peer.isSeed {
            // The final HAVE promotes a partial peer; undo its previously
            // counted pieces, while the final piece was never added.
            var previous = peer.availability
            previous[index] = false
            picker.adjust(previous, adding: false)
            picker.seedCount += 1
        } else { picker.availability[index] += 1 }
    }

    func removePeerAvailability(_ peer: ActivePeer) {
        if peer.isSeed { picker.seedCount -= 1 }
        else { picker.adjust(peer.availability, adding: false) }
    }

    func openPieceWork(_ index: Int, nextBlockBegin: Int) {
        pieceWork[index] = PieceWork(nextBlockBegin: nextBlockBegin)
        picker.inFlight[index] = true
        var low = 0, high = picker.openIndices.count
        while low < high {
            let middle = (low + high) / 2
            if picker.openIndices[middle] < index { low = middle + 1 }
            else { high = middle }
        }
        picker.openIndices.insert(index, at: low)
    }

    func removePieceWork(_ index: Int) {
        pieceWork.removeValue(forKey: index)
        picker.inFlight[index] = false
        if let position = picker.openIndices.firstIndex(of: index) { picker.openIndices.remove(at: position) }
    }

    func clearPieceWork() {
        pieceWork.removeAll()
        picker.inFlight = PieceBitset(count: wanted.count)
        picker.openIndices.removeAll(keepingCapacity: true)
    }
}

extension TorrentEngine {
    func nextBlock(_ session: EngineSession, peer: ActivePeer) -> BlockRequest? {
        let meta = session.record.metainfo
        // Keep this ordered collection incrementally, instead of sorting every
        // outstanding piece again for each of thousands of peer requests.
        for index in session.picker.openIndices where peer.availability[index] {
            guard let work = session.pieceWork[index], !work.verifying else { continue }
            let pieceLength = meta.lengthOfPiece(index)
            let blockCount = (pieceLength + 16_383) / 16_384
            guard work.received.count + work.requested.count < blockCount else { continue }
            var begin = work.nextBlockBegin
            for _ in 0..<blockCount {
                let next = begin + 16_384 < pieceLength ? begin + 16_384 : 0
                if !work.received.contains(begin) && !work.requested.contains(begin) {
                    session.pieceWork[index]?.nextBlockBegin = next
                    return BlockRequest(piece: index, begin: begin, length: min(16_384, pieceLength - begin))
                }
                begin = next
            }
        }
        // Every open piece may complete at once. Keeping at most sixteen
        // bounds verification backlog, including tiny single-block pieces.
        guard session.pieceWork.count < 16 else { return nil }
        let storage = profile(for: session)
        let local = storage == .hdd || (storage == .automatic && session.automaticHDD)
        let start = local ? 0 : session.picker.cursor
        var best: Int?, rarity = UInt32.max, ties = 0, inspected = 0
        var last = start
        // Sampling rotates through the whole torrent; the byte filter searches
        // directly in the existing bitmaps without allocating a candidate map.
        for range in [start..<session.wanted.count, 0..<start] {
            var offset = range.lowerBound
            while inspected < 256, let index = candidateIndex(session, peer: peer, from: offset, before: range.upperBound) {
                let available = session.picker.availability[index]
                if available < rarity { best = index; rarity = available; ties = 1 }
                else if available == rarity {
                    ties += 1
                    if session.picker.chooseTie(ties) { best = index }
                }
                last = index
                inspected += 1
                if local { break }
                offset = index + 1
            }
            if local || inspected == 256 { break }
        }
        guard let index = best else { return nil }
        session.picker.cursor = (last + 1) % session.wanted.count
        session.openPieceWork(index, nextBlockBegin: meta.lengthOfPiece(index) > 16_384 ? 16_384 : 0)
        return BlockRequest(piece: index, begin: 0, length: min(16_384, meta.lengthOfPiece(index)))
    }

    private func candidateIndex(_ session: EngineSession, peer: ActivePeer, from offset: Int, before end: Int) -> Int? {
        guard offset < end else { return nil }
        let a = peer.availability.bytes, w = session.wanted.bytes
        let v = session.record.verified.bytes, f = session.picker.inFlight.bytes
        var byteIndex = offset / 8
        var mask = UInt8.max >> (offset % 8)
        while byteIndex * 8 < end {
            let byte = a[byteIndex] & w[byteIndex] & ~(v[byteIndex] | f[byteIndex]) & mask
            if byte != 0 {
                let index = byteIndex * 8 + byte.leadingZeroBitCount
                return index < end ? index : nil
            }
            byteIndex += 1
            mask = UInt8.max
        }
        return nil
    }
}

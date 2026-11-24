// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

// Review r3, item 26: the matcher looks up candidates instead of comparing every pair.

@Suite struct BackupMatcherIndexTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// The rules as they were written before the index: every resource against every candidate.
    static func naiveMatch(_ resource: LocalResource, candidates: [RemoteCandidate], localSiblings: [LocalResource]) -> (
        RemoteCandidate, MatchReason
    )? {
        typealias M = BackupMatcher
        let localIsRaw = M.isRaw(resource)
        let sameKind = candidates.filter { $0.kind == resource.kind && M.isRawName($0.name) == localIsRaw }
        let byName = !M.isAmbiguousName(resource, among: localSiblings)
        if let size = resource.byteSize, size > 0,
            let exact = sameKind.first(where: { $0.size == size && M.sameSecond($0, resource.createdAt) })
        {
            return (exact, .serverTimeSize)
        }
        let compatible = sameKind.filter { M.isCompatible(resource, candidateName: $0.name) }
        let atSameSecond = compatible.filter { M.sameSecond($0, resource.createdAt) }
        if byName, let named = atSameSecond.first(where: { M.namesAgree(local: resource.originalName, server: $0.name) }) {
            return (named, .serverTimeName)
        }
        if let width = resource.pixelWidth, let height = resource.pixelHeight {
            let sameSize = atSameSecond.filter { candidate in
                guard let w = candidate.width, let h = candidate.height else { return false }
                return (w == width && h == height) || (w == height && h == width)
            }
            let localAtSameSecond = localSiblings.filter {
                $0.kind == resource.kind && $0.rendition == resource.rendition && M.isRaw($0) == localIsRaw
                    && abs($0.createdAt.timeIntervalSince(resource.createdAt)) < M.tolerance
            }
            if sameSize.count == 1, atSameSecond.count == 1, localAtSameSecond.count <= 1 { return (sameSize[0], .serverTimeSize) }
        }
        if byName {
            for candidate in compatible {
                guard let captured = candidate.capturedAt, M.namesAgree(local: resource.originalName, server: candidate.name) else {
                    continue
                }
                let difference = captured.timeIntervalSince(resource.createdAt)
                let hours = (difference / 3600).rounded()
                if hours != 0, abs(hours) <= 14, abs(difference - hours * 3600) < M.tolerance { return (candidate, .serverTimeName) }
            }
        }
        return nil
    }

    /// A small deterministic random source, so a failure can be repeated.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Device resources and server files crowded into a few minutes and whole hours around them: bursts, renditions,
    /// RAW files, shifted EXIF times, names that agree and names that do not.
    func crowd(_ count: Int, seed: UInt64) -> (locals: [LocalResource], candidates: [RemoteCandidate]) {
        var random = SplitMix(state: seed)
        let fractions: [TimeInterval] = [0, 0.4, 0.9, 1.4, 1.6]
        func time() -> TimeInterval { TimeInterval(Int.random(in: 0..<240, using: &random)) + fractions.randomElement(using: &random)! }
        func number() -> Int { 1000 + Int.random(in: 0..<40, using: &random) }
        let sizes: [Int64?] = [nil, 100, 200, 300]
        let dimensions: [(Int?, Int?)] = [(nil, nil), (4032, 3024), (3024, 4032), (1920, 1080)]
        var locals: [LocalResource] = []
        for index in 0..<count {
            let rendition: LocalResource.Rendition = [.original, .original, .edited, .raw].randomElement(using: &random)!
            let n = number()
            let name =
                switch rendition {
                case .original: ["IMG_\(n).HEIC", "PXL_20240501_\(n)45.jpg", "Holiday.jpg"].randomElement(using: &random)!
                case .edited: "IMG_E\(n).HEIC"
                case .raw: "IMG_\(n).DNG"
                }
            let (w, h) = dimensions.randomElement(using: &random)!
            locals.append(
                LocalResource(
                    localIdentifier: "L\(index % (count / 2 + 1))", kind: Bool.random(using: &random) ? .image : .video,
                    createdAt: t0 + time(), originalName: name, byteSize: sizes.randomElement(using: &random)!, pixelWidth: w,
                    pixelHeight: h, rendition: rendition))
        }
        var candidates: [RemoteCandidate] = []
        for index in 0..<count {
            let n = number()
            let name = [
                "IMG_\(n).HEIC", "IMG_E\(n).HEIC", "IMG_\(n) (edited).HEIC", "IMG_\(n).DNG", "24-05-01 12-30-45 \(n).jpg",
                "PXL_20240501_\(n)45.jpg", "holiday.JPG", "other.png",
            ].randomElement(using: &random)!
            let hours = TimeInterval([0, 0, 0, 2, -5, 14, 15].randomElement(using: &random)!) * 3600
            let (w, h) = dimensions.randomElement(using: &random)!
            candidates.append(
                RemoteCandidate(
                    fileId: Int64(index), path: "/Photos/\(name)", kind: Bool.random(using: &random) ? .image : .video,
                    size: sizes.randomElement(using: &random)! ?? 1, capturedAt: Bool.random(using: &random) ? t0 + time() + hours : nil,
                    modifiedAt: t0 + time(), width: w, height: h))
        }
        return (locals, candidates)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func theIndexDecidesLikeComparingEveryPair(seed: UInt64) {
        let (locals, candidates) = crowd(400, seed: seed)
        var index = BackupMatcher.Index(candidates: candidates, locals: locals)
        var matched = 0
        for resource in locals {
            let expected = Self.naiveMatch(resource, candidates: candidates, localSiblings: locals)
            let found = index.match(resource)
            #expect(found?.0 == expected?.0 && found?.1 == expected?.1, "\(resource.originalName) at \(resource.createdAt)")
            if expected != nil { matched += 1 }
        }
        // The data exercises the rules: some match, some do not.
        #expect(matched > 20)
        #expect(matched < locals.count)
    }

    /// One photo every 10 seconds over hours. Each has a server file of another photo in the same second, and its own
    /// copy on the server either 5 seconds away (no match: every rule is tried) or with its capture time read 2 hours off
    /// (rule 4 matches).
    func spread(_ count: Int, shifted: Bool) -> (locals: [LocalResource], candidates: [RemoteCandidate]) {
        let locals = (0..<count).map { index in
            LocalResource(
                localIdentifier: "\(index)", kind: .image, createdAt: t0 + TimeInterval(index * 10), originalName: "IMG_\(index).HEIC",
                byteSize: 100, pixelWidth: 4032, pixelHeight: 3024)
        }
        var candidates: [RemoteCandidate] = []
        for index in 0..<count {
            let second = t0 + TimeInterval(index * 10)
            candidates.append(
                RemoteCandidate(
                    fileId: Int64(2 * index), path: "/Photos/burst-\(index + 1_000_000).HEIC", kind: .image, size: 999, capturedAt: nil,
                    modifiedAt: second))
            let copy = shifted ? second + 2 * 3600 : second + 5
            candidates.append(
                RemoteCandidate(
                    fileId: Int64(2 * index + 1), path: "/Photos/\(shifted ? "IMG_\(index)" : "other-\(index)").HEIC", kind: .image,
                    size: 200, capturedAt: copy, modifiedAt: copy))
        }
        return (locals, candidates)
    }

    func examined(_ count: Int, shifted: Bool) -> Int {
        let (locals, candidates) = spread(count, shifted: shifted)
        var index = BackupMatcher.Index(candidates: candidates, locals: locals)
        for resource in locals {
            let result = index.match(resource)
            #expect((result != nil) == shifted)
        }
        return index.examined
    }

    /// Each lookup looks at the candidates within 2 seconds of the resource's second and of its 28 whole-hour shifts (at
    /// most one each here), not at every candidate of the batch.
    @Test(arguments: [false, true])
    func theWorkGrowsWithTheBatchNotWithItsSquare(shifted: Bool) {
        let small = examined(1000, shifted: shifted)
        let large = examined(4000, shifted: shifted)
        // A bounded number per resource, whatever the number of candidates: its sibling, the other photo's file in its
        // second, and with shifted times its own copy and those of the photos whole hours away.
        let bound = shifted ? 32 : 2
        #expect(small <= 1000 * bound)
        #expect(large <= 4000 * bound)
        if !shifted {
            // Four times the resources and candidates is four times the work, not sixteen.
            #expect(large == 4 * small)
        }
        // Comparing every resource with every candidate would be 32 million.
        #expect(large <= 4000 * 8000 / 60)
    }
}

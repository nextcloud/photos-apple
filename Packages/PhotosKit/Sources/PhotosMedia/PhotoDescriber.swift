// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import PhotosStore
import Vision

#if canImport(FoundationModels) && !os(tvOS)
    import FoundationModels
#endif

/// Writes a short description of a photo on this device (SPEC §16.2): Vision finds what is in the picture (labels,
/// faces, text); Apple Intelligence's language model, where it is available, writes the sentence from the picture itself
/// and those facts, in the user's language; elsewhere `PhotoDescription.compose` writes it in English from the facts.
/// Nothing leaves the device.
public enum PhotoDescriber {
    /// Previews looked for, smallest useful first.
    public static let buckets = [1024, 256]
    /// Vision and the model scale their input down to a few hundred pixels anyway.
    public static let decodeSize = 512

    /// What Vision finds in a picture.
    public static func facts(in image: CGImage) async throws -> PhotoDescription.Facts {
        #if targetEnvironment(simulator)
            // Vision's models do not run in the simulator (docs/TESTING.md): nothing is described there.
            throw SimulatorUnsupported()
        #else
            let classifications = try await ClassifyImageRequest().perform(on: image)
            let labels = classifications.filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }.prefix(12).map {
                (identifier: $0.identifier, confidence: $0.confidence)
            }
            let faces = (try? await DetectFaceRectanglesRequest().perform(on: image)) ?? []
            var textRequest = RecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            let observations = (try? await textRequest.perform(on: image)) ?? []
            // Large text first (a sign, a title), not the small print.
            let lines =
                observations
                .sorted { $0.boundingBox.height > $1.boundingBox.height }
                .compactMap { $0.topCandidates(1).first.map { ($0.string, $0.confidence) } }
                .filter { $0.1 >= 0.5 }
                .map(\.0)
                .prefix(3)
            // Faces too small to be anyone in particular are not counted.
            let counted = faces.filter { $0.boundingBox.width * $0.boundingBox.height >= 0.002 }.count
            return PhotoDescription.Facts(labels: Array(labels), faceCount: counted, text: Array(lines))
        #endif
    }

    struct SimulatorUnsupported: Error {}

    /// The language the language model writes in, nil when there is no model on this device.
    public static var modelLanguage: String? {
        #if canImport(FoundationModels) && !os(tvOS)
            let model = SystemLanguageModel(useCase: .general)
            guard case .available = model.availability else { return nil }
            let locale = Locale.current
            guard model.supportsLocale(locale) else { return nil }
            return locale.language.languageCode?.identifier
        #else
            return nil
        #endif
    }

    /// Describes a picture: the language model when there is one, else the sentence composed from Vision's facts.
    public static func describe(_ image: CGImage) async throws -> PhotoDescriptionStore.Result {
        let facts = try await facts(in: image)
        #if canImport(FoundationModels) && !os(tvOS)
            if let language = modelLanguage, let text = try? await LanguageModelDescriber.describe(image, facts: facts) {
                return PhotoDescriptionStore.Result(text: text, language: language, source: .languageModel)
            }
        #endif
        guard let text = PhotoDescription.compose(facts) else { return .failed }
        return PhotoDescriptionStore.Result(text: text, language: "en", source: .vision)
    }
}

#if canImport(FoundationModels) && !os(tvOS)
    /// The sentence from Apple Intelligence's on-device language model.
    enum LanguageModelDescriber {
        static let instructions = """
            You write short alt text for photos in a personal photo library, for people who use a screen reader. \
            Answer with one plain sentence of at most 15 words, in the language of the user. Say what the photo shows: \
            the main subject, what it is doing and where. Do not guess names, ages, feelings or brands. Do not start with \
            "This image" or "A photo of".
            """

        static func describe(_ image: CGImage, facts: PhotoDescription.Facts) async throws -> String? {
            let model = SystemLanguageModel(useCase: .general)
            let session = LanguageModelSession(model: model, instructions: instructions)
            let hints = hintText(facts)
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 60)
            let response: LanguageModelSession.Response<String>
            if model.capabilities.contains(.vision) {
                response = try await session.respond(options: options) {
                    "Describe this photo. Vision found: \(hints)."
                    Attachment(image)
                }
            } else {
                // A model without sight writes from the facts alone.
                guard !facts.isEmpty else { return nil }
                response = try await session.respond(
                    to: "Describe a photo in which an image classifier found: \(hints). Mention only what is likely visible.",
                    options: options)
            }
            return PhotoDescription.cleaned(response.content)
        }

        static func hintText(_ facts: PhotoDescription.Facts) -> String {
            var parts: [String] = []
            if !facts.words.isEmpty { parts.append(facts.words.prefix(8).joined(separator: ", ")) }
            if facts.faceCount > 0 { parts.append("\(facts.faceCount) face\(facts.faceCount == 1 ? "" : "s")") }
            if let line = facts.text.first { parts.append("text “\(line.prefix(40))”") }
            return parts.isEmpty ? "nothing in particular" : parts.joined(separator: "; ")
        }
    }
#endif

/// Describes the photos whose previews are cached, a batch at a time (see `PhotoDescriber`). Incremental: only photos
/// without a description of their current version are looked at.
public struct PhotoDescriptionIndexer: Sendable {
    let store: PhotoDescriptionStore
    let cache: PreviewCache
    let lookup: PhotoDescriptionLookup?
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "descriptions")

    public init(database: AccountDatabase, cache: PreviewCache, lookup: PhotoDescriptionLookup? = nil) {
        store = PhotoDescriptionStore(database: database)
        self.cache = cache
        self.lookup = lookup
    }

    /// Describes cached photos until none are left or `shouldContinue` says stop. Returns how many were looked at.
    @discardableResult
    public func run(
        batchSize: Int = 16, pause: Duration = .zero, shouldContinue: @escaping @Sendable () -> Bool = { true },
        describe: @escaping @Sendable (CGImage) async throws -> PhotoDescriptionStore.Result = PhotoDescriber.describe
    ) async throws -> Int {
        var cursor: FileID?
        var described = 0
        var failures = 0
        while shouldContinue(), !Task.isCancelled, failures < 3 {
            let batch = try store.candidates(limit: batchSize, before: cursor)
            guard let last = batch.last else { break }
            cursor = last.fileId
            var results: [(candidate: PhotoDescriptionStore.Candidate, result: PhotoDescriptionStore.Result)] = []
            for candidate in batch {
                guard shouldContinue(), !Task.isCancelled, failures < 3 else { break }
                // Not cached: left for a later run, after the photo has been on screen.
                guard
                    let url = cache.cachedPreviewURL(fileId: candidate.fileId, etag: candidate.etag, buckets: PhotoDescriber.buckets)
                else { continue }
                guard let image = ImageDecoding.decode(url: url, maxPixelSize: PhotoDescriber.decodeSize) else {
                    results.append((candidate, .failed))
                    continue
                }
                do {
                    results.append((candidate, try await describe(image)))
                } catch {
                    // Not stored: tried again by a later run. Repeated failures end this one.
                    logger.error("describing \(candidate.fileId) failed: \(error.localizedDescription, privacy: .public)")
                    failures += 1
                }
            }
            try store.save(results)
            lookup?.invalidate(results.map(\.candidate.fileId))
            described += results.count
            if pause > .zero, !results.isEmpty { try? await Task.sleep(for: pause) } else { await Task.yield() }
        }
        if described > 0 { logger.info("described \(described) photos on this device") }
        return described
    }
}

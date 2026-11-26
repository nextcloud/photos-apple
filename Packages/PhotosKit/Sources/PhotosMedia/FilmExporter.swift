// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PhotosDomain

/// The pictures, clips and overlays a film is made of, prepared by the app (previews loaded, clips downloaded, titles
/// rendered), keyed like the plan: shots by their index in `FilmPlan.shots`, overlays and maps by segment index.
public struct FilmMaterial: Sendable {
    public var stills: [Int: CGImage] = [:]
    public var focus: [Int: FilmCrop] = [:]
    /// Local files: a video shot's video, a Live Photo's motion.
    public var clips: [Int: URL] = [:]
    /// Full-frame transparent pictures drawn over a segment (the title, a flight's caption).
    public var overlays: [Int: CGImage] = [:]
    /// The year in review's cards, frame-sized.
    public var cards: [CGImage] = []
    public var maps: [Int: FilmMapPicture] = [:]

    public init() {}
}

/// A map picture of a flight and where the two stops are on it (0…1, top left).
public struct FilmMapPicture: Sendable {
    public var image: CGImage
    public var from: CGPoint
    public var to: CGPoint

    public init(image: CGImage, from: CGPoint, to: CGPoint) {
        self.image = image
        self.from = from
        self.to = to
    }
}

/// Writes a memory film as a video file (SPEC §15.1): frames rendered with Core Image exactly as the player shows them,
/// encoded as H.264 or HEVC, then the music (a file the user chose; Apple Music songs are protected and cannot be put
/// into a video) or, without music, the clips' own sound, faded in and out. Everything happens in a private temporary
/// folder; the folder is removed on failure and cancellation, and the caller removes the finished file's folder when done.
public struct FilmExporter: Sendable {
    public enum Codec: String, Sendable, CaseIterable {
        /// Plays everywhere.
        case h264
        /// About half the size; plays on current Apple devices and most others.
        case hevc
    }

    public var plan: FilmPlan
    public var material: FilmMaterial
    public var size: CGSize
    public var codec: Codec
    public var frameRate: Int32 = 30
    /// A readable audio file (not a protected song).
    public var music: URL?
    /// No camera moves (Reduce Motion).
    public var still: Bool
    public var fileName: String

    /// Where exports are made; anything left there from an earlier run that did not finish is removed at the next export.
    public static var workFolder: URL { FileManager.default.temporaryDirectory.appending(path: "MemoryFilms", directoryHint: .isDirectory) }

    public init(
        plan: FilmPlan, material: FilmMaterial, size: CGSize, codec: Codec, music: URL?, still: Bool = false, fileName: String
    ) {
        self.plan = plan
        self.material = material
        self.size = size
        self.codec = codec
        self.music = music
        self.still = still
        self.fileName = fileName
    }

    /// Removes the exports of earlier runs (older than an hour; a running export's folder is newer).
    public static func removeLeftovers(now: Date = Date()) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: workFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if now.timeIntervalSince(created) > 3600 { try? FileManager.default.removeItem(at: folder) }
        }
    }

    /// Writes the film and returns the file (in its own folder below `workFolder`). `progress` gets 0…1.
    public func export(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        Self.removeLeftovers()
        let folder = Self.workFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let video = folder.appending(path: "video.mp4")
            try await writeVideo(to: video) { progress($0 * 0.92) }
            let target = folder.appending(path: Self.safeName(fileName) + ".mp4")
            let audio = try await writeAudio(in: folder)
            progress(0.96)
            if let audio {
                try await mux(video: video, audio: audio, to: target)
                try? FileManager.default.removeItem(at: video)
                try? FileManager.default.removeItem(at: audio)
            } else {
                try FileManager.default.moveItem(at: video, to: target)
            }
            try Task.checkCancellation()
            progress(1)
            return target
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Memory" : String(cleaned.prefix(80))
    }

    // MARK: Video

    func writeVideo(to url: URL, progress: @Sendable (Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pixels = Int(size.width * size.height)
        let settings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: codec == .hevc ? pixels * 4 : pixels * 6,
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        let receiver = writer.inputPixelBufferReceiver(
            for: input, pixelBufferAttributes: VideoFrames.attributes(width: Int(size.width), height: Int(size.height)))
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        let renderer = FilmFrameRenderer(plan: plan, material: material, size: size, still: still)
        let frames = Int((plan.duration * Double(frameRate)).rounded(.up))
        do {
            for frame in 0..<frames {
                try Task.checkCancellation()
                guard let pool = receiver.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                let buffer = try pool.makeMutablePixelBuffer()
                let time = Double(frame) / Double(frameRate)
                try await renderer.render(at: time, into: buffer)
                // Waits while the encoder is busy (what `isReadyForMoreMediaData` was polled for).
                try await receiver.append(
                    CVReadOnlyPixelBuffer(buffer), with: CMTime(value: CMTimeValue(frame), timescale: frameRate))
                if frame % 15 == 0 { progress(Double(frame) / Double(max(frames, 1))) }
            }
        } catch {
            writer.cancelWriting()
            renderer.close()
            throw error
        }
        renderer.close()
        receiver.finish()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    // MARK: Sound

    /// The film's sound as an M4A file: the music looped over the film, faded in and out; without music the clips' own
    /// sound at their places. Nil when the film is silent.
    func writeAudio(in folder: URL) async throws -> URL? {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let total = CMTime(seconds: plan.duration, preferredTimescale: 600)
        var hasSound = false
        if let music {
            let asset = AVURLAsset(url: music)
            if let source = try? await asset.loadTracks(withMediaType: .audio).first,
                let length = try? await asset.load(.duration), length.seconds > 0.5
            {
                var position = CMTime.zero
                while position < total {
                    let piece = CMTimeMinimum(length, total - position)
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: source, at: position)
                    position = position + piece
                }
                hasSound = true
            }
        } else {
            for segment in plan.segments {
                guard case .shot(let shot) = segment.content, plan.shots[shot].isVideo, let clip = material.clips[shot] else { continue }
                let asset = AVURLAsset(url: clip)
                guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                    let length = try? await asset.load(.duration)
                else { continue }
                let piece = CMTimeMinimum(length, CMTime(seconds: segment.duration, preferredTimescale: 600))
                try? track.insertTimeRange(
                    CMTimeRange(start: .zero, duration: piece), of: source, at: CMTime(seconds: segment.start, preferredTimescale: 600))
                hasSound = true
            }
        }
        guard hasSound else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let fadeIn = CMTime(seconds: 1, preferredTimescale: 600)
        let fadeOut = CMTime(seconds: min(2.5, plan.duration / 3), preferredTimescale: 600)
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: fadeIn))
        parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: total - fadeOut, duration: fadeOut))
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        session.audioMix = mix
        session.timeRange = CMTimeRange(start: .zero, duration: total)
        let url = folder.appending(path: "audio.m4a")
        try await session.export(to: url, as: .m4a)
        return url
    }

    /// The video and the sound in one file, without encoding the video again.
    func mux(video: URL, audio: URL, to target: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let duration = try await videoAsset.load(.duration)
        if let source = try await videoAsset.loadTracks(withMediaType: .video).first,
            let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        if let source = try await audioAsset.loadTracks(withMediaType: .audio).first,
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
            let length = CMTimeMinimum(try await audioAsset.load(.duration), duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await session.export(to: target, as: .mp4)
    }
}

/// Renders one frame of a film with Core Image: the same layers, camera moves, fades and map flights as the player.
final class FilmFrameRenderer {
    let plan: FilmPlan
    let material: FilmMaterial
    let size: CGSize
    let still: Bool
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Prepared pictures (the still and its blurred fill), by shot index.
    var pictures: [Int: Picture] = [:]
    /// Open clip readers, by shot index.
    var clips: [Int: ClipReader] = [:]

    /// Pictures that stay the same from frame to frame (overlays, cards, maps), wrapped once.
    var wrapped: [String: CIImage] = [:]

    func cached(_ key: String, _ image: CGImage) -> CIImage {
        if let known = wrapped[key] { return known }
        let made = CIImage(cgImage: image)
        wrapped[key] = made
        return made
    }

    struct Picture {
        var image: CIImage
        var fill: CIImage
    }

    init(plan: FilmPlan, material: FilmMaterial, size: CGSize, still: Bool) {
        self.plan = plan
        self.material = material
        self.size = size
        self.still = still
    }

    var frame: CGRect { CGRect(origin: .zero, size: size) }
    var aspect: Double { size.width / size.height }

    func render(at time: Double, into buffer: borrowing CVMutablePixelBuffer) async throws {
        var image = CIImage(color: .black).cropped(to: frame)
        let layers = plan.layers(at: time)
        let onScreen = Set(layers.map(\.segment))
        let look = plan.style.look
        for layer in layers {
            // The style's colours on the pictures, not on the titles drawn over them (as in the player).
            var content = FilmLookFilter.graded(try await layerImage(layer).cropped(to: frame), look: look)
            if let overlay = material.overlays[layer.segment] {
                content = cached("overlay-\(layer.segment)", overlay).composited(over: content)
            }
            image = Self.faded(content.cropped(to: frame), layer.opacity).composited(over: image)
        }
        if look.vignette > 0 || look.isAnimated { image = FilmLookFilter.frame(image, look: look, time: time, size: size) }
        let brightness = plan.brightness(at: time)
        if brightness < 1 { image = Self.dimmed(image, brightness) }
        buffer.withUnsafeBuffer { context.render(image, to: $0, bounds: frame, colorSpace: colorSpace) }
        // Clips of segments that are over are closed.
        for (shot, reader) in clips where !onScreen.contains(where: { plan.shotIndex(of: plan.segments[$0]) == shot }) {
            reader.close()
            clips[shot] = nil
        }
    }

    func close() {
        for reader in clips.values { reader.close() }
        clips = [:]
    }

    func layerImage(_ layer: FilmLayer) async throws -> CIImage {
        let segment = plan.segments[layer.segment]
        switch segment.content {
        case .card(let index):
            guard index < material.cards.count else { return CIImage(color: .black) }
            let card = cached("card-\(index)", material.cards[index])
            let crop = KenBurns.Motion(
                from: .full, to: still ? .full : FilmCrop(x: 0.02, y: 0.02, width: 0.96, height: 0.96), fits: false
            ).crop(at: layer.progress)
            return place(card, crop: crop)
        case .flight:
            guard let map = material.maps[layer.segment] else { return CIImage(color: CIColor(red: 0.1, green: 0.12, blue: 0.16)) }
            return flight(map, progress: layer.progress)
        case .title, .shot:
            guard let shot = plan.shotIndex(of: segment) else { return CIImage(color: .black) }
            let kind = plan.shots[shot].kind
            if case .shot = segment.content, let source = try await clipFrame(shot, kind: kind, elapsed: layer.elapsed) {
                // Videos are not moved; a Live Photo's motion moves with its still.
                let base = KenBurns.base(imageAspect: source.extent.width / source.extent.height, viewportAspect: aspect)
                if case .livePhoto = kind {
                    let motion = motion(shot, imageAspect: source.extent.width / source.extent.height, seed: segment.seed)
                    return compose(
                        source, fill: Self.blurredFill(source, size: size), crop: motion.crop(at: layer.progress), fits: motion.fits)
                }
                return compose(source, fill: Self.blurredFill(source, size: size), crop: base.crop, fits: base.fits)
            }
            guard let picture = picture(shot) else { return CIImage(color: .black) }
            let motion = motion(shot, imageAspect: picture.image.extent.width / picture.image.extent.height, seed: segment.seed)
            return compose(picture.image, fill: picture.fill, crop: motion.crop(at: layer.progress), fits: motion.fits)
        }
    }

    func motion(_ shot: Int, imageAspect: Double, seed: Int) -> KenBurns.Motion {
        KenBurns.motion(
            imageAspect: imageAspect, viewportAspect: aspect, focus: material.focus[shot], seed: seed, still: still,
            closeness: plan.style.zoom)
    }

    func picture(_ shot: Int) -> Picture? {
        if let picture = pictures[shot] { return picture }
        guard let still = material.stills[shot] else { return nil }
        let image = CIImage(cgImage: still)
        // The blur is worked out once per picture, not for every frame.
        let blurred = Self.blurredFill(image, size: size)
        let fill = context.createCGImage(blurred, from: frame).map { CIImage(cgImage: $0) } ?? blurred
        let picture = Picture(image: image, fill: fill)
        pictures[shot] = picture
        // Only the pictures around the current time are kept.
        if pictures.count > 6, let oldest = pictures.keys.min(by: { abs($0 - shot) > abs($1 - shot) }) { pictures[oldest] = nil }
        return picture
    }

    /// The frame of a clip at `elapsed`, or nil when the shot has no clip there (a Live Photo after its motion).
    func clipFrame(_ shot: Int, kind: FilmShot.Kind, elapsed: Double) async throws -> CIImage? {
        guard let url = material.clips[shot] else { return nil }
        if case .livePhoto(let motion) = kind, elapsed > motion { return nil }
        if case .photo = kind { return nil }
        if clips[shot] == nil { clips[shot] = try await ClipReader(url: url) }
        return await clips[shot]?.frame(at: max(0, elapsed))
    }

    /// The picture through the camera's window, over its blurred fill when it is shown whole.
    func compose(_ image: CIImage, fill: CIImage, crop: FilmCrop, fits: Bool) -> CIImage {
        let placed = place(image, crop: crop)
        return fits ? placed.composited(over: fill) : placed
    }

    /// Moves and scales `image` so the window `crop` fills the frame.
    func place(_ image: CIImage, crop: FilmCrop) -> CIImage {
        let extent = image.extent
        let scale = size.width / (crop.width * extent.width)
        let left = extent.minX + crop.x * extent.width
        // Core Image counts from the bottom.
        let bottom = extent.minY + (1 - crop.y - crop.height) * extent.height
        return image.transformed(
            by: CGAffineTransform(translationX: -left, y: -bottom).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
    }

    func flight(_ map: FilmMapPicture, progress: Double) -> CIImage {
        let from = (x: Double(map.from.x), y: Double(map.from.y))
        let to = (x: Double(map.to.x), y: Double(map.to.y))
        let crop = MapFlight.camera(at: progress, from: from, to: to, still: still)
        let base = place(cached("map-\(ObjectIdentifier(map.image))", map.image), crop: crop)
        guard let route = routeImage(from: from, to: to, crop: crop, travelled: MapFlight.travelled(at: progress)) else { return base }
        return CIImage(cgImage: route).composited(over: base)
    }

    /// The route so far and the two stops, drawn for the camera's window.
    func routeImage(from: (x: Double, y: Double), to: (x: Double, y: Double), crop: FilmCrop, travelled: Double) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Map picture coordinates to the frame (CG counts from the bottom).
        func point(_ p: (x: Double, y: Double)) -> CGPoint {
            CGPoint(x: (p.x - crop.x) / crop.width * size.width, y: size.height - (p.y - crop.y) / crop.height * size.height)
        }
        let line = max(4, size.height / 160)
        context.setLineCap(.round)
        context.setLineWidth(line)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        context.setShadow(offset: .zero, blur: line * 2, color: CGColor(gray: 0, alpha: 0.5))
        let steps = 48
        context.move(to: point(from))
        for step in 1...steps {
            let amount = Double(step) / Double(steps) * travelled
            context.addLine(to: point(MapFlight.point(at: amount, from: from, to: to)))
        }
        context.strokePath()
        for stop in [from, to] {
            let centre = point(stop)
            let radius = line * 2.2
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            context.setFillColor(CGColor(red: 0, green: 0.51, blue: 0.79, alpha: 1))
            context.fillEllipse(
                in: CGRect(x: centre.x - radius * 0.6, y: centre.y - radius * 0.6, width: radius * 1.2, height: radius * 1.2))
        }
        // The plane: a bright dot at the head of the route.
        let head = point(MapFlight.point(at: travelled, from: from, to: to))
        let dot = line * 1.6
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: head.x - dot, y: head.y - dot, width: dot * 2, height: dot * 2))
        return context.makeImage()
    }

    /// A blurred, darkened copy of the picture filling the frame: behind pictures that are shown whole.
    static func blurredFill(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = image.extent
        let scale = max(size.width / extent.width, size.height / extent.height) * 1.1
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centred = scaled.transformed(
            by: CGAffineTransform(
                translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = centred.clampedToExtent()
        blur.radius = Float(size.height / 22)
        return dimmed(blur.outputImage ?? centred, 0.55).cropped(to: CGRect(origin: .zero, size: size))
    }

    static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        // Premultiplied colours: everything is scaled.
        let value = CGFloat(max(0, opacity))
        matrix.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: value)
        return matrix.outputImage ?? image
    }

    static func dimmed(_ image: CIImage, _ brightness: Double) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        let value = CGFloat(max(0, brightness))
        matrix.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        return matrix.outputImage ?? image
    }
}

/// Reads a clip's frames in order (upright: the track's orientation applied), holding the last frame at its end.
final class ClipReader {
    let reader: AVAssetReader
    let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    let orientation: CGAffineTransform
    var current: CIImage?
    var pending: (time: Double, image: CIImage)?
    var finished = false

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        orientation = try await track.load(.preferredTransform)
        reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        provider = reader.outputProvider(for: output)
        try reader.start()
    }

    /// The latest frame at or before `time` (seconds from the clip's start).
    func frame(at time: Double) async -> CIImage? {
        while !finished {
            if let pending {
                guard pending.time <= time else { break }
                current = pending.image
                self.pending = nil
            }
            // A clip that cannot be read any further holds its last frame, as at its end.
            guard let sample = try? await provider.next() else {
                finished = true
                break
            }
            let orientation = orientation
            let upright = sample.withUnsafeSampleBuffer { sample -> CIImage? in
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
                let raw = CIImage(cvPixelBuffer: buffer).transformed(by: orientation)
                // The orientation may move the picture off the origin; put it back.
                return raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
            }
            guard let upright else { continue }
            pending = (sample.presentationTimeStamp.seconds, upright)
        }
        return current ?? pending?.image
    }

    func close() {
        if reader.status == .reading { reader.cancelReading() }
    }
}

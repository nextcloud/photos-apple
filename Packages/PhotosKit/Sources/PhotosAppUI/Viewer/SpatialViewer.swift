// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(visionOS)
    import ImageIO
    import PhotosCore
    import PhotosMedia
    import PhotosModel
    import RealityKit
    import SwiftUI

    // Vision Pro (SPEC §6.2 visionOS specifics, M5): spatial photos are shown spatially (RealityKit's
    // `ImagePresentationComponent` with the stereo pair), panoramas wrap around the viewer in an immersive space.

    /// The immersive space that shows a panorama (`PanoramaSpace`); the app declares it as a scene.
    public enum PanoramaImmersion {
        public static let spaceID = "panorama"

        /// What the space shows: a downloaded image file and its size.
        public struct Request: Codable, Hashable, Sendable {
            public var file: URL
            public var width: Int
            public var height: Int
        }
    }

    /// Whether the photo shown is a spatial photo is learnt from the original, which is read once per version.
    @MainActor enum SpatialDetection {
        static var known: [String: Bool] = [:]

        static func key(_ item: MediaItem) -> String { "\(item.fileId)-\(item.etag)" }
    }

    /// The viewer's button for a spatial photo ("Spatial") or a panorama ("Immersive"); nothing for other photos.
    struct SpatialViewerButton: View {
        let item: MediaItem
        @Environment(SessionModel.self) private var session
        @Environment(\.openImmersiveSpace) private var openImmersiveSpace
        @State private var spatialFile: URL?
        @State private var showingSpatial: SpatialFile?
        @State private var opening = false

        var body: some View {
            Group {
                if spatialFile != nil {
                    Button {
                        showingSpatial = spatialFile.map(SpatialFile.init)
                    } label: {
                        Label(
                            String(localized: "Spatial", bundle: .module, comment: "Vision Pro viewer: show the spatial photo in 3D."),
                            systemImage: "view.3d")
                    }
                    .help(String(localized: "Spatial", bundle: .module, comment: "Vision Pro viewer: show the spatial photo in 3D."))
                } else if SpatialMedia.isPanorama(item) {
                    Button {
                        Task { await openPanorama() }
                    } label: {
                        Label(
                            String(
                                localized: "Immersive", bundle: .module, comment: "Vision Pro viewer: show the photo all around the viewer."
                            ), systemImage: "pano")
                    }
                    .disabled(opening)
                    .help(
                        String(localized: "Immersive", bundle: .module, comment: "Vision Pro viewer: show the photo all around the viewer.")
                    )
                }
            }
            .task(id: SpatialDetection.key(item)) { await detectSpatial() }
            .sheet(item: $showingSpatial) { file in SpatialPhotoSheet(file: file.url) }
        }

        /// A HEIC may be a spatial photo: its original is read (from the cache when it is there) and its image
        /// properties looked at.
        func detectSpatial() async {
            spatialFile = nil
            guard SpatialMedia.maySpatial(item), let services = session.services else { return }
            let key = SpatialDetection.key(item)
            if SpatialDetection.known[key] == false { return }
            // A spatial photo from iPhone or Vision Pro is a few megabytes; anything far larger is not read for this.
            guard
                let file = try? await services.images.originals.original(
                    fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item), maxBytes: 64 * 1024 * 1024)
            else { return }
            let stereo = await Task.detached(priority: .utility) { SpatialMedia.isStereoPair(file: file) }.value
            SpatialDetection.known[key] = stereo
            if stereo, !Task.isCancelled { spatialFile = file }
        }

        /// Downloads the panorama (the original, else the largest preview) and opens the immersive space with it.
        func openPanorama() async {
            guard let services = session.services, let width = item.width, let height = item.height else { return }
            opening = true
            defer { opening = false }
            let file: URL
            if let original = try? await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item), maxBytes: 200 * 1024 * 1024)
            {
                file = original
            } else {
                let request = ImagePipeline.Request(
                    fileId: item.fileId, etag: item.etag, bucket: 4096, hasPreview: item.hasPreview, mimeType: item.mimeType,
                    originalURL: services.originalURL(for: item))
                guard let image = await services.images.preview(request), let written = Self.write(image, fileId: item.fileId) else {
                    return
                }
                file = written
            }
            _ = await openImmersiveSpace(
                id: PanoramaImmersion.spaceID, value: PanoramaImmersion.Request(file: file, width: width, height: height))
        }

        /// The preview as a file in the temporary folder, for the immersive space.
        static func write(_ image: CGImage, fileId: FileID) -> URL? {
            let url = FileManager.default.temporaryDirectory.appending(path: "panorama-\(fileId).heic")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? url : nil
        }
    }

    /// A spatial photo's file, for the sheet.
    struct SpatialFile: Identifiable {
        var id: URL { url }
        var url: URL
    }

    /// A spatial photo in its own sheet, shown with depth; "Immersive" lets it fill the view as Photos does.
    struct SpatialPhotoSheet: View {
        let file: URL
        @Environment(\.dismiss) private var dismiss
        @State private var immersive = false
        @State private var failed = false
        @State private var entity = Entity()

        var body: some View {
            NavigationStack {
                GeometryReader3D { proxy in
                    RealityView { content in
                        content.add(entity)
                    } update: { content in
                        guard var presentation = entity.components[ImagePresentationComponent.self] else { return }
                        presentation.desiredViewingMode = immersive ? .spatialStereoImmersive : .spatialStereo
                        entity.components.set(presentation)
                        Self.fit(entity, presentation, in: content.convert(proxy.frame(in: .local), from: .local, to: .scene))
                    }
                }
                .overlay {
                    if failed {
                        ContentUnavailableView(
                            String(localized: "This photo can't be shown spatially", bundle: .module), systemImage: "view.3d")
                    }
                }
                .task {
                    do {
                        var presentation = try await ImagePresentationComponent(contentsOf: file)
                        presentation.desiredViewingMode = .spatialStereo
                        entity.components.set(presentation)
                    } catch {
                        failed = true
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Done", bundle: .module)) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: $immersive) {
                            Label(
                                String(
                                    localized: "Immersive", bundle: .module,
                                    comment: "Vision Pro viewer: show the photo all around the viewer."),
                                systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .disabled(failed)
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 600)
        }

        /// Scales the photo's screen to the window, keeping its aspect.
        static func fit(_ entity: Entity, _ presentation: ImagePresentationComponent, in bounds: BoundingBox) {
            let size = presentation.presentationScreenSize
            guard size.x > 0, size.y > 0 else { return }
            let scale = min(bounds.extents.x / size.x, bounds.extents.y / size.y)
            entity.scale = SIMD3(repeating: scale)
            entity.position = bounds.center
        }
    }

    /// A panorama around the viewer: the inside of a cylinder segment, as wide as the photo reaches (`panoramaArc`), at
    /// eye height, centred in front.
    public struct PanoramaSpace: View {
        let request: PanoramaImmersion.Request
        @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

        public init(request: PanoramaImmersion.Request) {
            self.request = request
        }

        public var body: some View {
            RealityView { content in
                guard let entity = await Self.panorama(request) else { return }
                content.add(entity)
            }
            // A tap anywhere ends it, as in Photos.
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in Task { await dismissImmersiveSpace() } })
        }

        static let radius: Float = 5
        static let eyeHeight: Float = 1.5

        @MainActor static func panorama(_ request: PanoramaImmersion.Request) async -> Entity? {
            guard let source = CGImageSourceCreateWithURL(request.file as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(
                    source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                let texture = try? await TextureResource(image: image, options: .init(semantic: .color)),
                let mesh = try? MeshResource.generate(from: [cylinder(request)])
            else { return nil }
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = [0, eyeHeight, 0]
            entity.components.set(InputTargetComponent())
            entity.generateCollisionShapes(recursive: false)
            return entity
        }

        /// The inside of a cylinder segment facing the viewer (−z is in front), with the photo's aspect.
        static func cylinder(_ request: PanoramaImmersion.Request, segments: Int = 128) -> MeshDescriptor {
            let arc = Float(SpatialMedia.panoramaArc(width: request.width, height: request.height))
            let height = arc * radius * Float(request.height) / Float(max(request.width, 1))
            var positions: [SIMD3<Float>] = []
            var coordinates: [SIMD2<Float>] = []
            var indices: [UInt32] = []
            for step in 0...segments {
                let fraction = Float(step) / Float(segments)
                // From left to right as seen from the centre.
                let angle = -arc / 2 + arc * fraction
                let x = radius * sin(angle)
                let z = -radius * cos(angle)
                positions.append([x, -height / 2, z])
                positions.append([x, height / 2, z])
                coordinates.append([fraction, 0])
                coordinates.append([fraction, 1])
            }
            for step in 0..<UInt32(segments) {
                let bottom = step * 2
                // Wound so that the faces look inwards.
                indices += [bottom, bottom + 2, bottom + 1, bottom + 1, bottom + 2, bottom + 3]
            }
            var descriptor = MeshDescriptor(name: "panorama")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(coordinates)
            descriptor.primitives = .triangles(indices)
            return descriptor
        }
    }
#endif

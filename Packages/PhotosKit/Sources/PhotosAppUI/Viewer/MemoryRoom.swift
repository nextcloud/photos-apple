// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(visionOS)
    import PhotosCore
    import PhotosDomain
    import PhotosMedia
    import PhotosModel
    import RealityKit
    import SwiftUI

    // The memory room on Apple Vision Pro (SPEC §15.4): the photos of a memory float around the viewer as framed pictures;
    // looking at one and pinching brings it closer, and a spatial photo is then shown with its depth.

    /// The immersive space of the memory room; the app declares it as a scene.
    public enum MemoryRoom {
        public static let spaceID = "memoryRoom"

        /// What the room shows: the memory's title and photos.
        public struct Request: Codable, Hashable, Sendable {
            public var title: String
            public var fileIds: [FileID]
        }

        static var title: String {
            String(
                localized: "Memory Room", bundle: .module,
                comment: "Vision Pro: the memory's photos float around the viewer as framed pictures (an immersive space).")
        }

        static var leaveTitle: String {
            String(localized: "Leave Memory Room", bundle: .module, comment: "Vision Pro: closes the memory room.")
        }
    }

    /// Whether the room is open, for the memory's button.
    @MainActor @Observable final class MemoryRoomState {
        static let shared = MemoryRoomState()
        var openMemory: String?
    }

    /// The memory screen's button that opens (and closes) the room.
    struct MemoryRoomButton: View {
        let memory: Memory
        @Environment(\.openImmersiveSpace) private var openImmersiveSpace
        @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
        @State private var state = MemoryRoomState.shared
        @State private var busy = false

        var isOpen: Bool { state.openMemory == memory.id }

        var body: some View {
            Button {
                Task { await toggle() }
            } label: {
                Label(isOpen ? MemoryRoom.leaveTitle : MemoryRoom.title, systemImage: isOpen ? "xmark.circle" : "pano.badge.play")
            }
            .help(isOpen ? MemoryRoom.leaveTitle : MemoryRoom.title)
            .disabled(busy)
        }

        func toggle() async {
            busy = true
            defer { busy = false }
            if state.openMemory != nil {
                await dismissImmersiveSpace()
                if isOpen { return }
            }
            let request = MemoryRoom.Request(title: memory.title, fileIds: memory.items)
            if case .opened = await openImmersiveSpace(id: MemoryRoom.spaceID, value: request) {
                state.openMemory = memory.id
            }
        }
    }

    /// The room itself.
    public struct MemoryRoomSpace: View {
        let request: MemoryRoom.Request
        @Environment(AppModel.self) private var app
        @State private var room = MemoryRoomModel()

        public init(request: MemoryRoom.Request) {
            self.request = request
        }

        public var body: some View {
            RealityView { content in
                content.add(room.root)
            }
            .gesture(
                SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                    room.tapped(value.entity)
                }
            )
            .task {
                guard let services = app.session?.services else { return }
                await room.load(request, services: services)
            }
            .onDisappear {
                MemoryRoomState.shared.openMemory = nil
            }
        }
    }

    /// The entities of the room and what is brought close.
    @MainActor @Observable final class MemoryRoomModel {
        let root = Entity()
        @ObservationIgnored private var frames: [Entity.ID: Frame] = [:]
        @ObservationIgnored private var focused: Entity?
        @ObservationIgnored private var services: AccountServices?

        struct Frame {
            var entity: Entity
            var item: MediaItem
            var home: Transform
            var photo: Entity
            /// The spatial version, once it was loaded (nil: not a spatial photo, or not tried yet).
            var spatial: Entity?
            var triedSpatial = false
        }

        func load(_ request: MemoryRoom.Request, services: AccountServices) async {
            self.services = services
            let map = (try? await services.library.fetchItems(request.fileIds)) ?? [:]
            let items = MemoryRoomLayout.pick(
                request.fileIds.compactMap { map[$0] }.filter(AmbientPhotos.isEligible), isFavorite: \.isFavorite)
            if let title = Self.title(request.title) { root.addChild(title) }
            let placements = MemoryRoomLayout.placements(count: items.count)
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                for (index, item) in items.enumerated() {
                    group.addTask {
                        let request = ImagePipeline.Request(
                            fileId: item.fileId, etag: item.etag, bucket: 1024, hasPreview: item.hasPreview, mimeType: item.mimeType,
                            originalURL: services.originalURL(for: item))
                        return (index, await services.images.preview(request))
                    }
                }
                // Each frame appears as soon as its photo is there.
                for await (index, image) in group {
                    guard let image, !Task.isCancelled else { continue }
                    await add(items[index], image: image, at: placements[index])
                }
            }
            #if DEBUG
                // UI tests cannot look and pinch: PHOTOS_DEBUG_MEMORY_ROOM_FOCUS=1 brings the first frame close.
                if ProcessInfo.processInfo.environment["PHOTOS_DEBUG_MEMORY_ROOM_FOCUS"] != nil,
                    let first = frames.values.min(by: { $0.home.translation.x < $1.home.translation.x })?.entity
                {
                    try? await Task.sleep(for: .seconds(10))
                    tapped(first)
                }
            #endif
        }

        /// A framed picture: a dark frame, a light mat and the photo, looking at the centre of the room.
        private func add(_ item: MediaItem, image: CGImage, at placement: MemoryRoomLayout.Placement) async {
            guard let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return }
            let extent = MemoryRoomLayout.photoExtent(width: image.width, height: image.height)
            let frame = Entity()
            let border = ModelEntity(
                mesh: .generateBox(width: extent.x + 0.08, height: extent.y + 0.08, depth: 0.03, cornerRadius: 0.006),
                materials: [SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), roughness: 0.6, isMetallic: false)])
            let mat = ModelEntity(
                mesh: .generatePlane(width: extent.x + 0.04, height: extent.y + 0.04),
                materials: [SimpleMaterial(color: UIColor(white: 0.95, alpha: 1), roughness: 0.9, isMetallic: false)])
            mat.position.z = 0.0155
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            let photo = ModelEntity(mesh: .generatePlane(width: extent.x, height: extent.y), materials: [material])
            photo.position.z = 0.016
            frame.addChild(border)
            frame.addChild(mat)
            frame.addChild(photo)
            // Look and pinch: the frame is a target, glows where the viewer looks, and is read out by VoiceOver.
            frame.components.set(InputTargetComponent())
            frame.components.set(
                CollisionComponent(shapes: [.generateBox(width: extent.x + 0.08, height: extent.y + 0.08, depth: 0.04)]))
            frame.components.set(HoverEffectComponent())
            var accessibility = AccessibilityComponent()
            accessibility.isAccessibilityElement = true
            accessibility.label = LocalizedStringResource(stringLiteral: AmbientPhotos.caption(item))
            accessibility.traits = [.button, .image]
            frame.components.set(accessibility)
            let home = Transform(
                scale: .one, rotation: simd_quatf(angle: placement.yaw, axis: [0, 1, 0]), translation: placement.position)
            // It appears small and grows to its place.
            frame.transform = home
            frame.scale = [0.01, 0.01, 0.01]
            root.addChild(frame)
            frames[frame.id] = Frame(entity: frame, item: item, home: home, photo: photo)
            frame.move(to: home, relativeTo: root, duration: 0.6, timingFunction: .easeOut)
            Task {
                try? await Task.sleep(for: .seconds(0.7))
                self.float(frame, home: home)
            }
        }

        /// A slow drift up and down, different for every frame.
        private func float(_ frame: Entity, home: Transform) {
            guard focused !== frame else { return }
            var up = home
            up.translation.y += 0.04
            let duration = 3.0 + Double(abs(frame.id.hashValue % 10)) / 10
            let animation = FromToByAnimation<Transform>(
                from: home, to: up, duration: duration, timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)
            if let resource = try? AnimationResource.generate(with: animation) {
                frame.playAnimation(resource)
            }
        }

        /// A pinch brings a frame close; another pinch (on it or another) sends it back.
        func tapped(_ entity: Entity) {
            guard let frame = frameEntity(of: entity) else { return }
            if let current = focused {
                sendBack(current)
                if current === frame { return }
            }
            bringClose(frame)
        }

        private func frameEntity(of entity: Entity) -> Entity? {
            var candidate: Entity? = entity
            while let current = candidate {
                if frames[current.id] != nil { return current }
                candidate = current.parent
            }
            return nil
        }

        private func bringClose(_ frame: Entity) {
            focused = frame
            frame.stopAllAnimations()
            let target = Transform(
                scale: SIMD3(repeating: MemoryRoomLayout.focusScale), rotation: simd_quatf(angle: 0, axis: [0, 1, 0]),
                translation: MemoryRoomLayout.focusPosition)
            frame.move(to: target, relativeTo: root, duration: 0.7, timingFunction: .easeInOut)
            Task { await showSpatial(frame) }
        }

        private func sendBack(_ frame: Entity) {
            focused = nil
            guard let info = frames[frame.id] else { return }
            frame.stopAllAnimations()
            // Back to the flat photo: depth is for the photo in front of the viewer.
            info.spatial?.isEnabled = false
            info.photo.isEnabled = true
            frame.move(to: info.home, relativeTo: root, duration: 0.7, timingFunction: .easeInOut)
            Task {
                try? await Task.sleep(for: .seconds(0.8))
                self.float(frame, home: info.home)
            }
        }

        /// A spatial photo (a HEIC with a stereo pair) is shown with its depth while it is close.
        private func showSpatial(_ frame: Entity) async {
            guard var info = frames[frame.id] else { return }
            if let spatial = info.spatial {
                spatial.isEnabled = true
                info.photo.isEnabled = false
                return
            }
            guard !info.triedSpatial, SpatialMedia.maySpatial(info.item), let services else { return }
            info.triedSpatial = true
            frames[frame.id] = info
            let item = info.item
            guard
                let file = try? await services.images.originals.original(
                    fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item), maxBytes: 64 * 1024 * 1024),
                await Task.detached(priority: .userInitiated, operation: { SpatialMedia.isStereoPair(file: file) }).value,
                var presentation = try? await ImagePresentationComponent(contentsOf: file)
            else { return }
            presentation.desiredViewingMode = .spatialStereo
            let spatial = Entity()
            spatial.components.set(presentation)
            let size = presentation.presentationScreenSize
            let extent = MemoryRoomLayout.photoExtent(width: item.width, height: item.height)
            if size.x > 0, size.y > 0 { spatial.scale = SIMD3(repeating: min(extent.x / size.x, extent.y / size.y)) }
            spatial.position.z = 0.017
            frame.addChild(spatial)
            info.spatial = spatial
            frames[frame.id] = info
            // Only while it is still the one in front.
            let isFront = focused === frame
            spatial.isEnabled = isFront
            info.photo.isEnabled = !isFront
        }

        /// The memory's title, high in front of the viewer.
        static func title(_ text: String) -> Entity? {
            let mesh = MeshResource.generateText(
                text, extrusionDepth: 0.004, font: .systemFont(ofSize: 0.12, weight: .semibold), containerFrame: .zero,
                alignment: .center, lineBreakMode: .byTruncatingTail)
            let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
            let bounds = entity.visualBounds(relativeTo: nil)
            entity.position = [-bounds.center.x, 2.35, -2.4]
            return entity
        }
    }
#endif

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import Foundation
    import Observation
    import OSLog
    import PhotosMedia
    import PhotosModel

    /// A rotation of desktop pictures (SPEC §15.4): which photos, how often, on which displays.
    public struct DesktopPictureSettings: Codable, Hashable, Sendable {
        public enum Interval: String, Codable, CaseIterable, Sendable {
            case fiveMinutes, fifteenMinutes, thirtyMinutes, hour, day

            public var seconds: TimeInterval {
                switch self {
                case .fiveMinutes: 5 * 60
                case .fifteenMinutes: 15 * 60
                case .thirtyMinutes: 30 * 60
                case .hour: 60 * 60
                case .day: 24 * 60 * 60
                }
            }
        }

        /// Every display gets a picture of its own, or only one display changes.
        public enum Displays: Codable, Hashable, Sendable {
            case all
            /// A display by its number (`CGDirectDisplayID`), with its name for the settings while it is not connected.
            case display(id: UInt32, name: String)
        }

        public var accountId: AccountID
        public var source: AmbientSource
        public var interval: Interval
        public var displays: Displays
        public var shuffle: Bool
        /// Where the rotation is in the order of the photos.
        public var position = 0
        public var lastChange: Date?

        public init(
            accountId: AccountID, source: AmbientSource, interval: Interval = .hour, displays: Displays = .all, shuffle: Bool = true
        ) {
            self.accountId = accountId
            self.source = source
            self.interval = interval
            self.displays = displays
            self.shuffle = shuffle
        }

        /// When the next picture is due.
        public func nextChange(now: Date) -> Date {
            guard let lastChange else { return now }
            return lastChange.addingTimeInterval(interval.seconds)
        }

        /// The seed of the shuffled order: per account and source, so a restart continues the same order.
        var seed: UInt64? { shuffle ? AmbientRotation.seed("\(accountId.rawValue)|\(source.key)") : nil }
    }

    /// A display the desktop pictures can go to.
    public struct DesktopScreen: Hashable, Sendable, Identifiable {
        public var id: UInt32
        public var name: String
        public var width: Int
        public var height: Int

        public init(id: UInt32, name: String, width: Int, height: Int) {
            self.id = id
            self.name = name
            self.width = width
            self.height = height
        }

        var orientation: AmbientRotation.Orientation { .init(width: width, height: height) }
    }

    /// Which photo goes to which display at the next change.
    public enum DesktopPicturePlan {
        /// One photo per target display, each suiting the display's orientation when the photos allow, every display a
        /// different photo while there are enough. Returns the assignments and the position to go on from.
        public static func assign(
            _ items: [MediaItem], to screens: [DesktopScreen], settings: DesktopPictureSettings
        ) -> (assignments: [(screen: DesktopScreen, item: MediaItem)], position: Int) {
            guard !items.isEmpty else { return ([], settings.position) }
            let order = settings.seed.map { AmbientRotation.shuffledOrder(count: items.count, seed: $0) } ?? Array(items.indices)
            let orientations = items.map { AmbientRotation.Orientation(width: $0.width, height: $0.height) }
            var position = settings.position
            var result: [(screen: DesktopScreen, item: MediaItem)] = []
            for screen in targets(screens, settings.displays) {
                guard
                    let found = AmbientRotation.next(
                        from: position, order: order, orientations: orientations, screen: screen.orientation)
                else { break }
                result.append((screen, items[order[found]]))
                // On from the photo after the one taken. Photos skipped for their orientation wait for a display they suit.
                position = found + 1
            }
            return (result, position % max(items.count, 1))
        }

        /// The displays a rotation changes.
        public static func targets(_ screens: [DesktopScreen], _ displays: DesktopPictureSettings.Displays) -> [DesktopScreen] {
            switch displays {
            case .all: screens
            case .display(let id, _): screens.filter { $0.id == id }
            }
        }

        /// A file name for a photo's picture: its id and version, so a new version is fetched again.
        public static func fileName(_ item: MediaItem, fileExtension: String) -> String {
            let version = String(AmbientRotation.seed(item.etag), radix: 36)
            return "\(item.fileId)-\(version).\(fileExtension)"
        }

        /// The original is used when the desktop can show it as it is and it is not huge; otherwise the largest preview.
        public static func usesOriginal(_ item: MediaItem) -> Bool {
            let types: Set<String> = ["image/jpeg", "image/heic", "image/heif", "image/png"]
            return types.contains(item.mimeType.lowercased()) && item.size > 0 && item.size <= 40 * 1024 * 1024
        }
    }

    /// The desktop pictures of the Mac (SPEC §15.4): "Use as Desktop Picture" for one photo and a rotation through an
    /// album, the favourites or the memories, on all displays or one.
    ///
    /// The rotation runs while Nextcloud Photos runs — in the background and without a window too — and continues where it
    /// was when the app is opened again. The pictures are files in the app's caches (`folder`); only those on a display are
    /// kept. `NSWorkspace` sets the picture of the display's current Space: other Spaces keep theirs.
    @MainActor @Observable public final class DesktopPictures {
        public static let shared = DesktopPictures()

        /// The rotation, nil when none runs.
        public private(set) var settings: DesktopPictureSettings?
        /// A picture is being fetched.
        public private(set) var isWorking = false
        /// Why the last change did not work, for Settings.
        public private(set) var problem: String?

        @ObservationIgnored weak var app: AppModel?
        @ObservationIgnored private var loop: Task<Void, Never>?
        @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
        @ObservationIgnored let defaults: UserDefaults
        @ObservationIgnored let folder: URL
        @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "desktop")
        /// The system's displays and the call that sets a picture; tests replace them.
        @ObservationIgnored var screens: @MainActor () -> [DesktopScreen] = DesktopPictures.systemScreens
        @ObservationIgnored var apply: @MainActor (URL, DesktopScreen) throws -> Void = DesktopPictures.systemApply
        @ObservationIgnored var now: () -> Date = { Date() }

        static let settingsKey = "desktopPictures.rotation"
        static let filesKey = "desktopPictures.files"

        init(defaults: UserDefaults = .standard, folder: URL = DesktopPictures.defaultFolder) {
            self.defaults = defaults
            self.folder = folder
            if let data = defaults.data(forKey: Self.settingsKey) {
                settings = try? JSONDecoder().decode(DesktopPictureSettings.self, from: data)
            }
        }

        /// In the app's caches: the desktop shows the files from there.
        nonisolated static var defaultFolder: URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "DesktopPictures")
        }

        /// Called once at launch: a rotation that was running goes on.
        public func attach(_ app: AppModel) {
            self.app = app
            guard screenObserver == nil else { return }
            // A display that is connected later gets a picture at the next change; one that was there keeps its own.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            }
            schedule()
        }

        // MARK: Rotation

        /// Starts (or changes) a rotation; the first picture changes at once.
        public func start(_ settings: DesktopPictureSettings) {
            var settings = settings
            if let old = self.settings, old.source == settings.source, old.accountId == settings.accountId {
                settings.position = old.position
            }
            settings.lastChange = nil
            save(settings)
            problem = nil
            schedule()
        }

        public func stop() {
            loop?.cancel()
            loop = nil
            save(nil)
            problem = nil
        }

        /// "Next Picture": changes now and starts the interval again.
        public func next() async {
            guard settings != nil else { return }
            await change()
            schedule()
        }

        private func save(_ settings: DesktopPictureSettings?) {
            self.settings = settings
            if let settings, let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: Self.settingsKey)
            } else {
                defaults.removeObject(forKey: Self.settingsKey)
            }
        }

        /// Waits for the next change in steps of at most five minutes, so that a Mac that slept changes soon after it wakes.
        private func schedule() {
            loop?.cancel()
            guard settings != nil else { return }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let settings = self.settings else { return }
                    let wait = settings.nextChange(now: self.now()).timeIntervalSince(self.now())
                    if wait > 0 {
                        try? await Task.sleep(for: .seconds(min(wait, 300)))
                        continue
                    }
                    if await !self.change() {
                        // No session, no connection, no photos: try again a little later.
                        try? await Task.sleep(for: .seconds(300))
                    }
                }
            }
        }

        private func screensChanged() {
            guard let settings, case .all = settings.displays else { return }
            let known = Set(assignedFiles.keys)
            if screens().contains(where: { !known.contains(String($0.id)) }) {
                Task { await next() }
            }
        }

        /// Puts the next photos on the displays. False when nothing could be changed.
        @discardableResult
        func change() async -> Bool {
            guard var settings = settings else { return false }
            guard let session = app?.session, session.account.id == settings.accountId, let services = session.services else {
                problem = String(
                    localized: "The desktop pictures change while the account they come from is shown in Nextcloud Photos.",
                    bundle: .module, comment: "Settings › Desktop Picture: the rotation waits because another account is active.")
                return false
            }
            let items: [MediaItem]
            do {
                items = try await AmbientPhotos.items(settings.source, library: services.library, collections: services.collections)
            } catch {
                problem = error.localizedDescription
                return false
            }
            guard !items.isEmpty else {
                problem = String(
                    localized: "There are no photos to show. Open the album once, so that its photos are on this Mac.",
                    bundle: .module, comment: "Settings › Desktop Picture: the rotation's album or source has no photos (yet).")
                return false
            }
            let plan = DesktopPicturePlan.assign(items, to: screens(), settings: settings)
            guard !plan.assignments.isEmpty else { return false }
            isWorking = true
            defer { isWorking = false }
            var changed = false
            for (screen, item) in plan.assignments {
                do {
                    let file = try await picture(item, services: services)
                    try apply(file, screen)
                    assignedFiles[String(screen.id)] = file.lastPathComponent
                    changed = true
                } catch {
                    logger.notice("desktop: a picture could not be set: \(error.localizedDescription, privacy: .public)")
                    problem = error.localizedDescription
                }
            }
            // The rotation may have been stopped or changed meanwhile.
            guard let current = self.settings, current.source == settings.source, current.accountId == settings.accountId else {
                return changed
            }
            settings = current
            settings.position = plan.position
            settings.lastChange = now()
            save(settings)
            if changed { problem = nil }
            removeUnusedFiles()
            return changed
        }

        // MARK: One photo

        /// "Use as Desktop Picture": the photo on every display. A running rotation stops (it would replace the photo).
        public func use(_ item: MediaItem, services: AccountServices) async throws {
            isWorking = true
            defer { isWorking = false }
            let file = try await picture(item, services: services)
            stop()
            for screen in screens() {
                try apply(file, screen)
                assignedFiles[String(screen.id)] = file.lastPathComponent
            }
            removeUnusedFiles()
        }

        // MARK: Files

        /// The files on the displays, by display number.
        var assignedFiles: [String: String] {
            get { defaults.dictionary(forKey: Self.filesKey) as? [String: String] ?? [:] }
            set { defaults.set(newValue, forKey: Self.filesKey) }
        }

        /// Removes pictures no display shows any more.
        func removeUnusedFiles() {
            let used = Set(assignedFiles.values)
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            for file in files where !used.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        /// The photo as a file the desktop can show: the original when it is a JPEG, HEIC or PNG of reasonable size, else
        /// the largest preview the server makes (4096 pixels) as a JPEG.
        func picture(_ item: MediaItem, services: AccountServices) async throws -> URL {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if DesktopPicturePlan.usesOriginal(item) {
                let target = folder.appending(path: DesktopPicturePlan.fileName(item, fileExtension: (item.name as NSString).pathExtension))
                if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { return target }
                let original = try await services.images.originals.original(
                    fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item), maxBytes: 64 * 1024 * 1024)
                try FileManager.default.copyItem(at: original, to: target)
                return target
            }
            let target = folder.appending(path: DesktopPicturePlan.fileName(item, fileExtension: "jpg"))
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { return target }
            let request = ImagePipeline.Request(
                fileId: item.fileId, etag: item.etag, bucket: 4096, hasPreview: item.hasPreview, mimeType: item.mimeType,
                originalURL: services.originalURL(for: item))
            guard let image = await services.images.preview(request), let data = ImageDecoding.jpegData(image, quality: 0.92) else {
                throw DesktopPictureError.noPicture
            }
            try data.write(to: target, options: .atomic)
            return target
        }

        // MARK: System

        /// The connected displays.
        public static func systemScreens() -> [DesktopScreen] {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                let size = screen.frame.size
                let scale = screen.backingScaleFactor
                return DesktopScreen(
                    id: number.uint32Value, name: screen.localizedName, width: Int(size.width * scale), height: Int(size.height * scale))
            }
        }

        /// Fills the display with the photo (cropping what does not fit), as "Fill Screen" in System Settings.
        static func systemApply(_ file: URL, _ target: DesktopScreen) throws {
            guard
                let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.id
                })
            else { return }
            let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true,
            ]
            try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)
        }
    }

    enum DesktopPictureError: LocalizedError {
        case noPicture

        var errorDescription: String? {
            String(
                localized: "The photo could not be loaded from your Nextcloud.", bundle: .module,
                comment: "Use as Desktop Picture: the photo could not be downloaded.")
        }
    }
#endif

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if canImport(GroupActivities) && !os(watchOS)
    import AVFoundation
    import CoreMedia
    import Foundation
    import GroupActivities
    import OSLog
    import PhotosDomain

    #if !os(tvOS)
        import CoreTransferable
    #endif

    /// Watching a memory film or a slideshow together over SharePlay (SPEC §16.6). The activity carries only the shared
    /// film's description (`SharedFilm`: timeline, file ids, the Nextcloud's address); each participant loads the pictures
    /// from that Nextcloud with their own account. No preview picture is set on the activity: it would send a photo through
    /// Apple.
    public struct WatchTogetherActivity: GroupActivity, Sendable {
        public static let activityIdentifier = "com.nextcloud.photos.watch-together"

        public var film: SharedFilm

        public init(film: SharedFilm) {
            self.film = film
        }

        public var metadata: GroupActivityMetadata {
            var metadata = GroupActivityMetadata()
            metadata.type = .watchTogether
            metadata.title = film.title
            metadata.subtitle = film.subtitle
            // Apple TV can take over the film from an iPhone in the call (the TV app plays it from the same Nextcloud).
            metadata.supportsContinuationOnTV = true
            return metadata
        }
    }

    #if !os(tvOS)
        /// "SharePlay" in the share sheet (Messages, FaceTime) starts the activity.
        extension WatchTogetherActivity: Transferable {
            public static var transferRepresentation: some TransferRepresentation {
                GroupActivityTransferRepresentation { (activity: WatchTogetherActivity) in activity }
            }
        }
    #endif

    /// What a film player that can be watched together does when the group says so. Times are film seconds.
    @MainActor public protocol WatchTogetherPlayer: AnyObject {
        /// Play from `time`, after `delay` seconds (a start planned for everyone at the same moment).
        func groupPlay(at time: Double, delay: Double)
        func groupPause(at time: Double)
        func groupSeek(to time: Double)
    }

    /// The SharePlay session of the app (one at a time): joins sessions as they come, keeps the attached player in step
    /// through a playback coordinator (play, pause and seek from anyone, on everyone's clock), and passes the participants'
    /// reports of what they can see.
    @MainActor @Observable public final class WatchTogether {
        public static let shared = WatchTogether()
        static let logger = Logger(subsystem: "com.nextcloud.photos", category: "shareplay")

        /// The film being watched together, nil when there is no session.
        public private(set) var film: SharedFilm?
        /// People in the session, this device included.
        public private(set) var participantCount = 0
        /// What the others can see, by participant.
        public private(set) var reports: [UUID: SharedFilmReport] = [:]
        /// A FaceTime call (or a nearby session) is going on: starting SharePlay goes straight into it.
        public private(set) var isEligible = false
        /// This device started the session.
        public private(set) var startedHere = false
        /// The film whose player is in step with the group (`attach`).
        public private(set) var attachedFilm: String?

        @ObservationIgnored private var session: GroupSession<WatchTogetherActivity>?
        @ObservationIgnored private var messenger: GroupSessionMessenger?
        @ObservationIgnored private var coordinator: AVDelegatingPlaybackCoordinator?
        @ObservationIgnored private let bridge = CoordinatorBridge()
        @ObservationIgnored private var tasks: [Task<Void, Never>] = []
        @ObservationIgnored private weak var player: (any WatchTogetherPlayer)?
        @ObservationIgnored private var listening = false
        @ObservationIgnored private let observer = GroupStateObserver()
        @ObservationIgnored private var lastReport: SharedFilmReport?

        private init() {}

        /// The audience's view of the pictures, the others' reports summed up.
        public var audience: SharedFilmAudience { SharedFilmAudience(Array(reports.values)) }

        /// Starts waiting for sessions (once per launch): from this device or from others in a FaceTime call.
        public func listen() {
            guard !listening else { return }
            listening = true
            Task { [weak self] in
                for await session in WatchTogetherActivity.sessions() {
                    self?.configure(session)
                }
            }
            Task { [weak self] in
                guard let observer = self?.observer else { return }
                for await eligible in observer.$isEligibleForGroupSession.values {
                    self?.isEligible = eligible
                }
            }
        }

        public enum StartResult: Sendable {
            case started
            /// SharePlay is switched off, or there is no call: the share sheet offers to start one.
            case unavailable
            case cancelled
        }

        /// Shares `film` with the people in the call (or replaces what a running session shows).
        public func share(_ film: SharedFilm) async -> StartResult {
            let activity = WatchTogetherActivity(film: film)
            if let session, case .joined = session.state {
                session.activity = activity
                return .started
            }
            switch await activity.prepareForActivation() {
            case .activationPreferred:
                do {
                    return try await activity.activate() ? .started : .cancelled
                } catch {
                    Self.logger.error("SharePlay could not start: \(error.localizedDescription, privacy: .public)")
                    return .unavailable
                }
            case .activationDisabled: return .unavailable
            case .cancelled: return .cancelled
            @unknown default: return .cancelled
            }
        }

        private func configure(_ session: GroupSession<WatchTogetherActivity>) {
            end(leaving: true)
            self.session = session
            film = session.activity.film
            reports = [:]
            lastReport = nil
            startedHere = session.isLocallyInitiated
            let messenger = GroupSessionMessenger(session: session)
            self.messenger = messenger
            let coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: bridge)
            // Nobody waits for a participant who cannot load the pictures.
            coordinator.suspensionReasonsThatTriggerWaiting = []
            coordinator.coordinateWithSession(session)
            self.coordinator = coordinator
            tasks.append(
                Task { [weak self] in
                    for await state in session.$state.values {
                        guard let self else { return }
                        if case .invalidated = state {
                            Self.logger.info("SharePlay session ended")
                            self.end(leaving: false)
                            return
                        }
                    }
                })
            tasks.append(
                Task { [weak self] in
                    for await participants in session.$activeParticipants.values {
                        guard let self else { return }
                        self.participantCount = participants.count
                        let present = Set(participants.map(\.id))
                        self.reports = self.reports.filter { present.contains($0.key) }
                        // Newcomers hear what this device can see.
                        if let report = self.lastReport { self.send(report) }
                    }
                })
            tasks.append(
                Task { [weak self] in
                    for await activity in session.$activity.values {
                        guard let self, self.film != activity.film else { continue }
                        // Someone shared something else: the players follow `film`.
                        self.film = activity.film
                        self.reports = [:]
                        self.lastReport = nil
                    }
                })
            tasks.append(
                Task { [weak self] in
                    for await (report, context) in messenger.messages(of: SharedFilmReport.self) {
                        self?.reports[context.source.id] = report
                    }
                })
            session.join()
        }

        /// Leaves the session (the others go on watching).
        public func leave() {
            session?.leave()
            end(leaving: false)
        }

        private func end(leaving: Bool) {
            if leaving { session?.leave() }
            for task in tasks { task.cancel() }
            tasks = []
            session = nil
            messenger = nil
            coordinator = nil
            player = nil
            attachedFilm = nil
            film = nil
            participantCount = 0
            reports = [:]
            startedHere = false
        }

        // MARK: Playback

        /// The player showing `film` is ready (its pictures are loading): it joins the group's timing. `position` and
        /// `playing` are where this device is; the group's timing wins when there already is one.
        public func attach(_ player: any WatchTogetherPlayer, film: SharedFilm, position: Double, playing: Bool) {
            guard let coordinator, self.film?.id == film.id else { return }
            self.player = player
            attachedFilm = film.id
            var timebase: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
            if let timebase {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 600))
                CMTimebaseSetRate(timebase, rate: playing ? 1 : 0)
            }
            coordinator.transitionToItem(withIdentifier: film.id, proposingInitialTimingBasedOn: timebase)
        }

        public func detach(_ player: any WatchTogetherPlayer) {
            guard self.player === player else { return }
            self.player = nil
            attachedFilm = nil
            coordinator?.transitionToItem(withIdentifier: nil, proposingInitialTimingBasedOn: nil)
        }

        /// Whether `player` is in step with the group.
        public func isAttached(_ player: any WatchTogetherPlayer) -> Bool {
            attachedFilm != nil && self.player === player && coordinator != nil
        }

        public func play() { coordinator?.coordinateRateChange(to: 1, options: []) }
        public func pause() { coordinator?.coordinateRateChange(to: 0, options: []) }
        public func seek(to time: Double) {
            coordinator?.coordinateSeek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), options: [])
        }

        /// Tells the others what this device can see.
        public func report(_ report: SharedFilmReport) {
            guard report != lastReport else { return }
            lastReport = report
            send(report)
        }

        private func send(_ report: SharedFilmReport) {
            guard let messenger, let others = session?.activeParticipants.filter({ $0 != session?.localParticipant }), !others.isEmpty
            else { return }
            Task {
                do {
                    try await messenger.send(report, to: .only(others))
                } catch {
                    Self.logger.error("SharePlay report not sent: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        /// A command of the coordinator, for the film it is about.
        fileprivate func apply(_ command: CoordinatorBridge.Command, item: String) {
            guard let player, film?.id == item else { return }
            switch command {
            case .play(let itemTime, let hostTime):
                let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                let position = FilmSync.position(itemTime: itemTime, hostTime: hostTime, now: now)
                player.groupPlay(at: position.time, delay: position.delay)
            case .pause(let itemTime): player.groupPause(at: itemTime)
            case .seek(let itemTime): player.groupSeek(to: itemTime)
            }
        }
    }

    /// The coordinator's commands, handed to the main actor. The coordinator holds it weakly; `WatchTogether` keeps it.
    final class CoordinatorBridge: NSObject, AVPlaybackCoordinatorPlaybackControlDelegate, Sendable {
        enum Command: Sendable {
            case play(itemTime: Double, hostTime: Double?)
            case pause(itemTime: Double)
            case seek(itemTime: Double)
        }

        private func forward(_ command: Command, item: String, done: @escaping @Sendable () -> Void) {
            Task { @MainActor in
                WatchTogether.shared.apply(command, item: item)
                done()
            }
        }

        func playbackCoordinator(
            _ coordinator: AVDelegatingPlaybackCoordinator, didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand,
            completionHandler: @escaping @Sendable () -> Void
        ) {
            let host = playCommand.hostClockTime
            forward(
                .play(itemTime: playCommand.itemTime.seconds, hostTime: host.isValid && host.isNumeric ? host.seconds : nil),
                item: playCommand.expectedCurrentItemIdentifier, done: completionHandler)
        }

        func playbackCoordinator(
            _ coordinator: AVDelegatingPlaybackCoordinator, didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand,
            completionHandler: @escaping @Sendable () -> Void
        ) {
            let time = coordinator.expectedItemTime(atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
            forward(
                .pause(itemTime: time.isNumeric ? time.seconds : 0), item: pauseCommand.expectedCurrentItemIdentifier,
                done: completionHandler)
        }

        func playbackCoordinator(
            _ coordinator: AVDelegatingPlaybackCoordinator, didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand,
            completionHandler: @escaping @Sendable () -> Void
        ) {
            forward(.seek(itemTime: seekCommand.itemTime.seconds), item: seekCommand.expectedCurrentItemIdentifier, done: completionHandler)
        }

        func playbackCoordinator(
            _ coordinator: AVDelegatingPlaybackCoordinator, didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand,
            completionHandler: @escaping @Sendable () -> Void
        ) {
            // The pictures load while the film plays; nothing to wait for.
            completionHandler()
        }
    }
#endif

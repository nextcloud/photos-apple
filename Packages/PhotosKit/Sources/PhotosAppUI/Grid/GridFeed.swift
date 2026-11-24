// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosDomain
import PhotosModel
import PhotosStore

typealias GridStream = AsyncThrowingStream<[GridMedia], any Error>

/// Observes a grid query from the store and turns it into the model the grid shows.
///
/// The model (sections, index by id, what changed) is built off the main actor. Updates that arrive while one is
/// being built are coalesced: during the first sync the query fires once per 1000-item page, and only the newest
/// result is worth building.
@MainActor
@Observable
final class GridFeed {
    /// A model with the change that leads to it from the one before (`revision - 1`).
    struct Update: Sendable {
        var model = GridModel.empty
        var revision = 0
        var change = GridModel.Change.none
    }

    private(set) var update = Update()
    private(set) var loaded = false

    var model: GridModel { update.model }
    var items: [GridMedia] { update.model.items }

    /// Lists up to this size are sectioned right away; it takes well under a millisecond.
    static let inlineLimit = 2000
    /// Pause after an update before the next one is built, so a burst becomes a few updates.
    static let coalesceInterval = Duration.milliseconds(250)

    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pending: (items: [GridMedia], flat: Bool)?
    @ObservationIgnored private var granularity = TimelineGranularity.day
    /// Month counts that complete the timeline during the first sync (`TimelineSkeleton`); nil otherwise.
    @ObservationIgnored private var skeleton: TimelineSkeleton?
    @ObservationIgnored private var generation = 0

    func observe(_ observation: @escaping @Sendable () -> GridStream, flat: Bool) {
        self.observation?.cancel()
        self.observation = Task { [weak self] in
            do {
                for try await items in observation() {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(items, flat: flat)
                }
            } catch {}
        }
    }

    func apply(_ items: [GridMedia], flat: Bool) {
        if worker == nil, items.count <= Self.inlineLimit {
            let model = GridModel(items: items, sectioning: sectioning(flat: flat), skeleton: skeleton)
            publish(model, change: model.change(from: update.model))
            return
        }
        pending = (items, flat)
        guard worker == nil else { return }
        generation += 1
        let generation = generation
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let next = self.pending else { break }
                self.pending = nil
                let sectioning = self.sectioning(flat: next.flat)
                let skeleton = self.skeleton
                let base = self.update
                let built = await Task.detached(priority: .userInitiated) { () -> (GridModel, GridModel.Change) in
                    let model = GridModel(items: next.items, sectioning: sectioning, skeleton: skeleton)
                    return (model, model.change(from: base.model))
                }.value
                guard !Task.isCancelled else { break }
                if self.update.revision == base.revision {
                    self.publish(built.0, change: built.1)
                } else {
                    // The granularity or the skeleton changed while the model was built.
                    self.publish(built.0.resectioned(self.sectioning(flat: next.flat), skeleton: self.skeleton), change: .structure)
                }
                try? await Task.sleep(for: Self.coalesceInterval)
            }
            // A cancelled worker must not clear its successor.
            if let self, self.generation == generation { self.worker = nil }
        }
    }

    /// The zoom step the grid shows. It lives here, next to the model, so that a zoom change and the sections that go
    /// with it (days, months, years) reach the grid in one update.
    private(set) var zoomStep = GridColumns.default

    func setZoom(step: Int) {
        guard step != zoomStep || GridColumns.granularity(step: step) != granularity else { return }
        zoomStep = step
        setGranularity(GridColumns.granularity(step: step))
    }

    /// Days, months or years (follows the zoom). Cheap: the items stay, only the section ranges are rebuilt.
    func setGranularity(_ granularity: TimelineGranularity) {
        guard granularity != self.granularity else { return }
        self.granularity = granularity
        guard case .timeline = update.model.sectioning else { return }
        let model = update.model.resectioned(.timeline(granularity))
        publish(model, change: .structure)
    }

    /// Completes the timeline with placeholder tiles from the server's month counts while the first sync runs; nil when
    /// it is over or the server has no counts (stock servers). Cheap: only the sections are rebuilt.
    func setSkeleton(_ skeleton: TimelineSkeleton?) {
        guard skeleton != self.skeleton else { return }
        self.skeleton = skeleton
        guard case .timeline = update.model.sectioning else { return }
        let model = update.model.resectioned(update.model.sectioning, skeleton: skeleton)
        publish(model, change: model.change(from: update.model))
    }

    private func sectioning(flat: Bool) -> GridSectioning {
        flat ? .flat : .timeline(granularity)
    }

    private func publish(_ model: GridModel, change: GridModel.Change) {
        if change != .none || !loaded {
            update = Update(model: model, revision: update.revision + 1, change: change)
        }
        loaded = true
    }

    func cancel() {
        observation?.cancel()
        worker?.cancel()
        worker = nil
        pending = nil
    }
}

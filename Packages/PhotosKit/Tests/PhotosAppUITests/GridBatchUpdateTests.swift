// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import Foundation
    import PhotosModel
    import PhotosStore
    import Testing

    @testable import PhotosAppUI

    /// The section changes of `GridModel.change(from:)` applied as batch updates to a real collection view (with the
    /// grid's compositional layout), as the Mac grid does for uploads and sync pages: a change the collection view does
    /// not agree with would raise an inconsistency exception there.
    @MainActor
    @Suite struct GridBatchUpdateTests {
        @MainActor final class Probe: NSObject, NSCollectionViewDataSource {
            static let identifier = NSUserInterfaceItemIdentifier("probe")
            var model: GridModel
            let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
            var batches = 0
            var reloads = 0

            init(_ model: GridModel) {
                self.model = model
                super.init()
                let metrics = GridSectionMetrics(
                    geometry: GridColumns.geometry(width: 400, step: GridColumns.default), headerHeight: 0, wholePoints: true)
                collectionView.collectionViewLayout = NSCollectionViewCompositionalLayout { _, _ in
                    metrics.layoutSection(headerKind: NSCollectionView.elementKindSectionHeader)
                }
                collectionView.register(NSCollectionViewItem.self, forItemWithIdentifier: Self.identifier)
                collectionView.dataSource = self
                let scroll = NSScrollView(frame: collectionView.frame)
                scroll.documentView = collectionView
                window.contentView = scroll
                collectionView.reloadData()
                collectionView.layoutSubtreeIfNeeded()
            }

            func numberOfSections(in collectionView: NSCollectionView) -> Int { model.sections.count }

            func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
                model.numberOfItems(inSection: section)
            }

            func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
                -> NSCollectionViewItem
            {
                collectionView.makeItem(withIdentifier: Self.identifier, for: indexPath)
            }

            /// Tiles applied one by one (the animated batch of a delete, archive or undo, SPEC §17.2).
            var itemBatches = 0

            /// Applies the next model the way the grid does and returns whether the collection view then agrees with it.
            /// - Parameter itemLevel: section changes go as single tiles where `GridItemChanges` allows it.
            func apply(_ next: GridModel, itemLevel: Bool = false) -> Bool {
                let change = next.change(from: model)
                if itemLevel, case .sections(let changes) = change,
                    let items = GridItemChanges.make(old: model, new: next, changes: changes)
                {
                    _ = collectionView.numberOfSections
                    model = next
                    collectionView.performBatchUpdates {
                        collectionView.deleteSections(items.deletedSections)
                        collectionView.insertSections(items.insertedSections)
                        collectionView.deleteItems(at: Set(items.deletedItems))
                        collectionView.insertItems(at: Set(items.insertedItems))
                    }
                    itemBatches += 1
                } else if case .sections(let changes) = change {
                    _ = collectionView.numberOfSections
                    model = next
                    collectionView.performBatchUpdates {
                        collectionView.deleteSections(changes.deleted)
                        collectionView.insertSections(changes.inserted)
                        collectionView.reloadSections(changes.reloaded)
                    }
                    batches += 1
                } else {
                    model = next
                    if change == .structure {
                        collectionView.reloadData()
                        reloads += 1
                    }
                }
                collectionView.layoutSubtreeIfNeeded()
                guard collectionView.numberOfSections == model.sections.count else { return false }
                return (0..<model.sections.count).allSatisfy { section in
                    collectionView.numberOfItems(inSection: section) == model.numberOfItems(inSection: section)
                }
            }
        }

        var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
            return calendar
        }

        func media(_ id: FileID, _ time: Double, favorite: Bool = false) -> GridMedia {
            let date = Date(timeIntervalSince1970: time)
            return GridMedia(
                MediaItem(
                    fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)", modifiedAt: date, capturedAt: date,
                    isFavorite: favorite))
        }

        /// Uploads, deletes, favourites and edits in random order: every step is applied as a batch (or a reload when too
        /// much changed), and the collection view always agrees with the model.
        @Test func randomChangesKeepTheCollectionViewConsistent() {
            randomChanges(itemLevel: false)
        }

        /// The same with the tiles that leave and come applied one by one, as an animated delete or undo does.
        @Test func randomItemChangesKeepTheCollectionViewConsistent() {
            randomChanges(itemLevel: true)
        }

        func randomChanges(itemLevel: Bool) {
            var seed: UInt64 = 42
            func random(_ upper: Int) -> Int {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((seed >> 33) % UInt64(upper))
            }
            let start = 1_790_000_000.0
            var items: [FileID: GridMedia] = [:]
            var nextId: FileID = 1
            for _ in 0..<300 {
                items[nextId] = media(nextId, start - Double(random(90)) * 86_400 - Double(random(80_000)))
                nextId += 1
            }
            func model() -> GridModel {
                GridModel(
                    items: items.values.sorted { ($0.timestamp, $0.fileId) > ($1.timestamp, $1.fileId) }, sectioning: .timeline(.day),
                    calendar: calendar)
            }
            func anyId() -> FileID? { items.keys.sorted().dropFirst(random(max(items.count, 1))).first }
            let probe = Probe(model())
            for step in 0..<300 {
                switch random(5) {
                case 0:  // an upload of today or of an old photo
                    let time = random(2) == 0 ? start + Double(step) * 60 : start - Double(random(120)) * 86_400
                    items[nextId] = media(nextId, time)
                    nextId += 1
                case 1:  // a delete
                    if let id = anyId() { items[id] = nil }
                case 2:  // several deletes in different days (a reconciliation)
                    for _ in 0..<random(6) { if let id = anyId() { items[id] = nil } }
                case 3:  // a favourite
                    if let id = anyId() { items[id]?.isFavorite.toggle() }
                default:  // a new capture date (edited elsewhere): the photo moves to another day
                    if let id = anyId() {
                        items[id] = media(id, start - Double(random(90)) * 86_400)
                    }
                }
                #expect(probe.apply(model(), itemLevel: itemLevel), "step \(step)")
            }
            // Nearly all of it went as batches.
            #expect(probe.batches + probe.itemBatches > 200)
            #expect(probe.reloads < 10)
            if itemLevel { #expect(probe.itemBatches > 150) }
        }
    }
#endif

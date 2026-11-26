// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaViewer {
    #if os(iOS)
        /// The floating glass controls (SPEC §17.1); a tap on the photo hides and shows them.
        var stageControls: some View {
            ViewerStageControls(
                item: currentItem, isVisible: !chromeHidden, dismissProgress: dismissPose.progress,
                close: { dismiss() },
                toggleFavorite: { item in toggleFavorite(item) },
                toggleInfo: { toggleInfo() },
                edit: { item in editing = item },
                delete: { confirmDelete = true },
                more: { item in moreActions(item) }
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.safeAreaInsets.top
            } action: { inset in
                topInset = inset
            }
        }
    #endif

    #if !os(iOS)
        @ToolbarContentBuilder var toolbar: some ToolbarContent {
            toolbarItems
        }
    #endif

    /// The viewer's toolbar (Mac) and ornament (Vision Pro), calm as in Photos (SPEC §19.2): favourite, info, share, edit
    /// and More after the date. Delete is in More and on the ⌫ key (and Image ▸ Delete…); the window's search field
    /// steps aside while a photo is open.
    @ToolbarContentBuilder var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: viewerPlacement) {
            if let item = currentItem {
                Button {
                    toggleFavorite(item)
                } label: {
                    // Says what pressing it does; the filled heart shows the state.
                    Label(Self.favoriteTitle(remove: item.isFavorite), systemImage: item.isFavorite ? "heart.fill" : "heart")
                }
                .help(Self.favoriteTitle(remove: item.isFavorite))
                Button {
                    toggleInfo()
                } label: {
                    Label(String(localized: "Info", bundle: .module), systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help(String(localized: "Info", bundle: .module))
                ShareMediaButton(items: [item])
                    .help(String(localized: "Share", bundle: .module))
                #if os(visionOS)
                    // Spatial photos and panoramas (SPEC §6.2 visionOS specifics).
                    SpatialViewerButton(item: item)
                #endif
                if item.kind == .image {
                    Button {
                        editing = item
                    } label: {
                        Label(String(localized: "Edit", bundle: .module), systemImage: "slider.horizontal.3")
                    }
                    .help(String(localized: "Edit", bundle: .module))
                }
                Menu {
                    moreActions(item)
                    if item.permissions.canDelete {
                        Divider()
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label(Self.deleteMenuTitle, systemImage: "trash")
                        }
                    }
                } label: {
                    Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
                }
                .help(String(localized: "More", bundle: .module))
            }
        }
    }

    /// "Delete…" in the toolbar's More menu: it asks first.
    static var deleteMenuTitle: String { String(localized: "Delete…", bundle: .module) }

    /// The keys that are not paging or culling: ⌫ deletes the photo shown after asking (SPEC §19.2).
    func otherKey(_ key: KeyEquivalent) {
        if Self.deleteKeys.contains(key) {
            if currentItem?.permissions.canDelete == true { confirmDelete = true }
        } else {
            cullingKey(key)
        }
    }

    /// ⌫ and ⌦, as in Photos.
    static let deleteKeys: [KeyEquivalent] = [.delete, .deleteForward]

    /// The More menu: add to album, save · extract text, edit date and location · archive.
    @ViewBuilder func moreActions(_ item: MediaItem) -> some View {
        let albumTitle: String = PlatformWording.title(
            mac: LocalizedStringResource("Add to Album…", bundle: .module),
            other: LocalizedStringResource("Add to album…", bundle: .module))
        Button {
            addingToAlbum = item
        } label: {
            Label(albumTitle, systemImage: "rectangle.stack.badge.plus")
        }
        if session.features.has(.systemtags) {
            Button {
                tagging = item
            } label: {
                Label(TagWording.menuTitle, systemImage: "tag")
            }
        }
        Button {
            save(item)
        } label: {
            Label(PhotosCommands.exportTitle, systemImage: "square.and.arrow.down")
        }
        .disabled(saver.isRunning)
        EditedItemMenuItems(item: item, saver: saver)
        if item.permissions.canShare && session.services != nil {
            Button {
                nextcloudShare = SharingTarget(item: item)
            } label: {
                Label(String(localized: "Share via Nextcloud…", bundle: .module), systemImage: "person.badge.plus")
            }
        }
        AdvancedFeatureGate(.postcards) { PostcardMenuItem(item: item, start: $postcard) }
        Button {
            playSlideshow()
        } label: {
            Label(SlideshowRequest.menuTitle, systemImage: SlideshowRequest.systemImage)
        }
        #if os(macOS)
            if DesktopPictureAction.isOffered(item) {
                Button {
                    DesktopPictureAction.use(item, session: session)
                } label: {
                    Label(DesktopPictureAction.title, systemImage: DesktopPictureAction.systemImage)
                }
            }
        #endif
        ThenAndNowMenuItem(item: item, start: $thenAndNow)
        if showInFolder != nil {
            Button {
                showFolder(item)
            } label: {
                Label(ShowInFolderAction.title, systemImage: ShowInFolderAction.systemImage)
            }
        }
        if showInTimeline != nil, !fromLibrary, ShowInTimelineAction.isOffered(for: item) {
            Button {
                showTimeline(item)
            } label: {
                Label(ShowInTimelineAction.title, systemImage: ShowInTimelineAction.systemImage)
            }
        }
        if SimilarPhotosAction.isOffered(for: item.kind) {
            Button {
                similarTo = item
            } label: {
                Label(SimilarPhotosAction.title, systemImage: SimilarPhotosAction.systemImage)
            }
        }
        Divider()
        if item.kind == .image {
            Button {
                extractingText = item
            } label: {
                Label(String(localized: "Extract text", bundle: .module), systemImage: "text.viewfinder")
            }
            AdvancedFeatureGate(.stickers) {
                Button {
                    stickerItem = item
                } label: {
                    Label(StickerWording.menuTitle, systemImage: "face.smiling")
                }
            }
        }
        if canEditMetadata(item) {
            Button {
                editingMetadata = item
            } label: {
                Label(String(localized: "Edit date and location", bundle: .module), systemImage: "calendar.badge.clock")
            }
        }
        if session.features.has(.systemtags) {
            AdvancedFeatureGate(.culling) {
                Divider()
                CullingMenuItems { command in
                    culling.apply(command, ids: cullingIds, session: session, undoManager: undoManager)
                }
            }
        }
        #if !os(macOS)
            // The Mac has it in the Edit menu.
            Button {
                showingUndoHistory = true
            } label: {
                Label(ChangeWording.historyMenuTitle, systemImage: "clock.arrow.circlepath")
            }
        #endif
        if item.isOwnStorage && item.permissions.canDelete {
            Divider()
            Button {
                toggleArchive(item)
            } label: {
                Label(
                    item.isArchived
                        ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                    systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
        }
    }

    /// Opens the folder browser at the photo's folder; the viewer closes, as Back would leave it.
    func showFolder(_ item: MediaItem) {
        guard let showInFolder else { return }
        dismiss()
        showInFolder(item)
    }

    /// Opens the Library at the photo's day with the photo highlighted; the viewer closes.
    func showTimeline(_ item: MediaItem) {
        guard let showInTimeline else { return }
        dismiss()
        showInTimeline(item)
    }

    /// A slideshow of the viewer's photos, from the one shown on (SPEC VW-5).
    func playSlideshow() {
        let title: String = String(localized: "Slideshow", bundle: .module)
        slideshow = SlideshowRequest(title: title, ids: shownIds.map { fileId(ofPage: $0) }, startId: currentFileId)
    }

    /// After the slideshow the viewer shows the photo it ended on.
    func showAfterSlideshow(_ last: FileID) {
        let page: FileID = shownIds.contains(last) ? last : (ViewerStacks.tile(of: last, in: stacks) ?? last)
        guard shownIds.contains(page), page != current else { return }
        current = page
        realignments += 1
    }
}

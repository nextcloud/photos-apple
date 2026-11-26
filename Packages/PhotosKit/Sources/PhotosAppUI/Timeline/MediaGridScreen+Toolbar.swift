// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaGridScreen {
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        // A group, not one item holding a stack: every control is a toolbar item of its own, with its own accessibility
        // label and tooltip, and the toolbar can move single items to the overflow menu instead of clipping at the window edge.
        ToolbarItemGroup(placement: .primaryAction) {
            accessory()
            #if os(iOS)
                // The grid has no Info button of its own (the context menu's "Info" opens the panel): without this, an iPad
                // without a keyboard (⌘I) could not close the panel again.
                if showingInfo {
                    Button {
                        showingInfo = false
                    } label: {
                        Label(
                            String(localized: "Hide info", bundle: .module, comment: "Closes the info panel beside the grid (iPad)."),
                            systemImage: "info.circle.fill")
                    }
                }
            #endif
            #if !os(macOS)
                Button(isSelecting ? String(localized: "Done", bundle: .module) : String(localized: "Select", bundle: .module)) {
                    if isSelecting {
                        endSelection()
                    } else {
                        // The tab bar morphs into the selection's action bar (SPEC §17.3).
                        withAnimation(ChromeMotion.morph(reduceMotion: reduceMotion)) { isSelecting = true }
                    }
                }
                .disabled(feed.items.isEmpty)
            #endif
        }
        #if !os(macOS)
            if let trailingItem, !isSelecting {
                #if os(iOS)
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                #endif
                ToolbarItem(placement: .primaryAction) { trailingItem }
            }
        #endif
        #if !os(iOS)
            selectionGroup
        #endif
    }

    /// The selection's actions in the window toolbar (Mac, Vision Pro).
    @ToolbarContentBuilder var selectionGroup: some ToolbarContent {
        if isSelecting && !selection.isEmpty {
            ToolbarItemGroup(placement: selectionPlacement) {
                let info: GridSelectionInfo = selectionInfo
                let allFavorite: Bool = info.summary.allFavorite
                if let items = info.items {
                    ShareMediaButton(items: items)
                        .help(String(localized: "Share", bundle: .module))
                }
                Button {
                    withItems(withStacks(Array(selection))) { setFavorite($0, !allFavorite) }
                } label: {
                    Label(favoriteTitle(remove: allFavorite), systemImage: allFavorite ? "heart.slash" : "heart")
                        .favoriteBounce(favoriteToggles)
                }
                .help(favoriteTitle(remove: allFavorite))
                Menu {
                    // Without Delete and Share: both are buttons of their own in the toolbar.
                    ForEach(menuActions(info).filter { $0.id != "delete" && $0.share == nil }, id: \.id) { action in
                        if action.startsGroup { Divider() }
                        if action.children.isEmpty {
                            menuButton(action)
                        } else {
                            Menu {
                                ForEach(action.children, id: \.id) { child in
                                    if child.startsGroup { Divider() }
                                    menuButton(child)
                                }
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    }
                    #if !os(macOS)
                        // The Mac has it in the Edit menu.
                        Divider()
                        Button {
                            showingUndoHistory = true
                        } label: {
                            Label(ChangeWording.historyMenuTitle, systemImage: "clock.arrow.circlepath")
                        }
                    #endif
                } label: {
                    Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
                }
                .help(String(localized: "More", bundle: .module))
                Button(role: .destructive) {
                    requestDelete(Array(selection))
                } label: {
                    Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
                }
                .help(String(localized: "Delete", bundle: .module))
                .disabled(info.summary.deletable == 0)
            }
        }
    }

    #if os(iOS)
        /// The selection's action bar at the bottom, in place of the tab bar on iPhone, as in Photos (SPEC §17.3).
        var selectionActionBar: some View {
            let info: GridSelectionInfo = selectionInfo
            let allFavorite: Bool = info.summary.allFavorite
            let hasSelection: Bool = !selection.isEmpty
            let more: [GridMenuAction] =
                hasSelection ? menuActions(info).filter { !SelectionBarLayout.ownButtons.contains($0.id) && $0.share == nil } : []
            return SelectionActionBar(
                isShown: isSelecting, count: selection.count, title: selectionTitle, shareItems: info.items,
                allFavorite: allFavorite, favoriteTitle: favoriteTitle(remove: allFavorite), favoriteToggles: favoriteToggles,
                canDelete: info.summary.deletable > 0, addTo: albumMenuAction(title: addToAlbumTitle), more: more,
                historyTitle: ChangeWording.historyMenuTitle,
                toggleFavorite: { withItems(withStacks(Array(selection))) { setFavorite($0, !allFavorite) } },
                delete: { requestDelete(Array(selection)) },
                run: { (action: GridMenuAction) in action.handler(Array(selection)) },
                showHistory: { showingUndoHistory = true })
        }
    #endif

    var addToAlbumTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Add to Album", bundle: .module, comment: "Submenu with the recent albums and New Album…."),
            other: LocalizedStringResource("Add to album", bundle: .module, comment: "Submenu with the recent albums and New album…."))
    }

    func menuButton(_ action: GridMenuAction) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            action.handler(Array(selection))
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
    }

    var selectionPlacement: ToolbarItemPlacement {
        #if os(iOS)
            .bottomBar
        #elseif os(visionOS)
            // A glass ornament under the window, as the viewer's actions (SPEC §17.7).
            .bottomOrnament
        #else
            .automatic
        #endif
    }

    /// "3 selected" in the bar, its number rolling as tiles are selected (SPEC §17.2). The navigation title stays the
    /// same text for VoiceOver and the back button.
    @ToolbarContentBuilder var selectionCountTitle: some ToolbarContent {
        if isSelecting && !keepsTitleWhileSelecting {
            ToolbarItem(placement: .principal) {
                Text(selectionTitle)
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(selection.count)))
                    .animation(.snappy(duration: 0.25), value: selection.count)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// The confirmation of the last change ("Archived 3 items · Undo") above the account's status.
    var statusBanner: some View {
        VStack(spacing: 0) {
            ChangeNoticeToast()
            GridStatusBanner(hasItems: feed.model.hasTiles)
        }
        // Above a control floating at the bottom (the Library's zoom picker).
        .padding(.bottom, floatingBottomInset)
        .animation(.default, value: session.lastChange?.id)
    }
}

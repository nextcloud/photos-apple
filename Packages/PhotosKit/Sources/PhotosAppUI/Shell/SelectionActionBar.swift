// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosModel
import SwiftUI

#if os(iOS)
    /// The selection's action bar on iPhone and iPad (SPEC §17.3): Liquid Glass shapes in one `GlassEffectContainer`,
    /// in place of the tab bar while selecting. With nothing selected it is one capsule ("Select items"); the first
    /// selected photo splits it into Share · the count · Favorite, Add to album, Delete, More, and they melt back into
    /// it when the selection is emptied (`glassEffectID`). It materialises out of the glass when Select is tapped and
    /// goes on Done. With Reduce Motion the shapes cross-fade.
    struct SelectionActionBar: View {
        /// Selecting: the bar is there. Its glass materialises when this turns true and dissolves when it turns false.
        let isShown: Bool
        let count: Int
        let title: String
        /// The selection's items for the Share sheet, once loaded.
        let shareItems: [MediaItem]?
        let allFavorite: Bool
        let favoriteTitle: String
        /// Counts the favourite toggles: the heart bounces.
        let favoriteToggles: Int
        let canDelete: Bool
        /// "Add to album" with its submenu.
        let addTo: GridMenuAction
        /// The More menu.
        let more: [GridMenuAction]
        let historyTitle: String
        let toggleFavorite: () -> Void
        let delete: () -> Void
        let run: (GridMenuAction) -> Void
        let showHistory: () -> Void

        @Namespace private var glass
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        static let height: CGFloat = 48

        var hasSelection: Bool { count > 0 }

        var body: some View {
            GlassEffectContainer(spacing: 14) {
                if isShown { bar }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4), value: hasSelection)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: isShown)
        }

        var bar: some View {
            HStack(spacing: 10) {
                if hasSelection {
                    share
                        .frame(width: Self.height, height: Self.height)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("share", in: glass)
                    Spacer(minLength: 0)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .rollingNumber(count)
                    .padding(.horizontal, hasSelection ? 14 : 22)
                    .frame(height: Self.height)
                    // Glass under the text too: it stays readable over any photo.
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("count", in: glass)
                    .accessibilityAddTraits(.updatesFrequently)
                if hasSelection {
                    Spacer(minLength: 0)
                    actions
                        .padding(.horizontal, 4)
                        .frame(height: Self.height)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("actions", in: glass)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("selection-action-bar")
        }

        @ViewBuilder var share: some View {
            if let shareItems, !shareItems.isEmpty {
                ShareMediaButton(items: shareItems).labelStyle(.iconOnly)
            } else {
                // Still loading the selection's items.
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("Share", bundle: .module))
            }
        }

        var actions: some View {
            HStack(spacing: 0) {
                Button(action: toggleFavorite) {
                    Label(favoriteTitle, systemImage: allFavorite ? "heart.slash" : "heart")
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                        .favoriteBounce(favoriteToggles)
                        .frame(width: 40, height: 44)
                }
                Menu {
                    ForEach(addTo.children, id: \.id) { child in
                        if child.startsGroup { Divider() }
                        button(child)
                    }
                } label: {
                    Label(addTo.title, systemImage: addTo.systemImage).frame(width: 40, height: 44)
                }
                Button(role: .destructive, action: delete) {
                    Label(String(localized: "Delete", bundle: .module), systemImage: "trash").frame(width: 40, height: 44)
                }
                .disabled(!canDelete)
                Menu {
                    ForEach(more, id: \.id) { action in
                        if action.startsGroup { Divider() }
                        if action.children.isEmpty {
                            button(action)
                        } else {
                            Menu {
                                ForEach(action.children, id: \.id) { child in
                                    if child.startsGroup { Divider() }
                                    button(child)
                                }
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    }
                    Divider()
                    Button(action: showHistory) {
                        Label(historyTitle, systemImage: "clock.arrow.circlepath")
                    }
                } label: {
                    Label(String(localized: "More", bundle: .module), systemImage: "ellipsis").frame(width: 40, height: 44)
                }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }

        func button(_ action: GridMenuAction) -> some View {
            Button(role: action.isDestructive ? .destructive : nil) {
                run(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
#endif

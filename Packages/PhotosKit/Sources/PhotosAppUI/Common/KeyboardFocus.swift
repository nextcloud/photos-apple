// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

#if os(iOS)
    import UIKit
#endif

// MARK: - Hardware keys without the software keyboard (iPhone, iPad)
//
// Full-screen views that take keys (the viewer, slideshows, films, Guest Mode) were made focusable so that `onKeyPress`
// got the arrow keys. On iPhone and iPad a focused SwiftUI view takes key input like a text field: whenever it became
// first responder again — when a menu opened over it, or a sheet closed — the system showed the software keyboard with
// nothing to type into (round 6: the viewer's, the editor's and the film's menus; the editor is presented over the
// viewer). Neither `focusable(interactions: .activate)` nor focusing only while a keyboard is attached
// (`GCKeyboard.coalesced` is set in the simulator, where the software keyboard still shows) avoided it.
//
// So on iPhone and iPad these views are not focusable; their keys are key commands of a plain UIKit responder (no text
// input, so no software keyboard), as the grid does it. A text field in a sheet over the view takes the first responder
// and its keys while it is edited. (`keyboardShortcut` on hidden buttons got the arrows but not Escape.) The Mac and
// Vision Pro keep focus and `onKeyPress`.

#if os(iOS)
    /// The plain keys a full-screen view takes, as key commands of a responder that is not a text input.
    private struct KeyCommandResponder: UIViewRepresentable {
        let keys: [KeyEquivalent]
        let perform: (KeyEquivalent) -> Void

        func makeUIView(context: Context) -> ResponderView { ResponderView() }

        func updateUIView(_ view: ResponderView, context: Context) {
            view.keys = keys
            view.perform = perform
        }

        /// Takes the first responder when it appears (and back after a menu or sheet), so its key commands come first —
        /// also Escape, which a plain SwiftUI shortcut does not get over the system's own use of it.
        final class ResponderView: UIView {
            var keys: [KeyEquivalent] = []
            var perform: (KeyEquivalent) -> Void = { _ in }

            override var canBecomeFirstResponder: Bool { true }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                if window != nil { DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() } }
            }

            override var keyCommands: [UIKeyCommand]? {
                keys.compactMap { key in
                    guard let input = Self.input(for: key) else { return nil }
                    let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(pressed(_:)))
                    command.wantsPriorityOverSystemBehavior = true
                    return command
                }
            }

            @objc func pressed(_ command: UIKeyCommand) {
                guard let key = keys.first(where: { Self.input(for: $0) == command.input }) else { return }
                perform(key)
            }

            static func input(for key: KeyEquivalent) -> String? {
                switch key {
                case .leftArrow: UIKeyCommand.inputLeftArrow
                case .rightArrow: UIKeyCommand.inputRightArrow
                case .upArrow: UIKeyCommand.inputUpArrow
                case .downArrow: UIKeyCommand.inputDownArrow
                case .escape: UIKeyCommand.inputEscape
                case .space: " "
                default: String(key.character)
                }
            }
        }
    }
#endif

extension View {
    /// Focusable for keys on the Mac and Vision Pro; on iPhone and iPad not (see above), where `hardwareKeys` takes them.
    @ViewBuilder func keyFocusable() -> some View {
        #if os(iOS)
            self
        #else
            focusable()
        #endif
    }

    /// Plain keys (no ⌘, ⌃ or ⌥) for a full-screen view: key commands on iPhone and iPad, `onKeyPress` of the focused
    /// view elsewhere (use with `keyFocusable()`).
    @ViewBuilder func hardwareKeys(_ keys: [KeyEquivalent], perform: @escaping (KeyEquivalent) -> Void) -> some View {
        #if os(iOS)
            background {
                KeyCommandResponder(keys: keys, perform: perform)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        #else
            onKeyPress(keys: Set(keys)) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                perform(press.key)
                return .handled
            }
        #endif
    }
}

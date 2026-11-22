// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosAppUI
import SwiftUI

#if canImport(UIKit)
    import UIKit

    final class ShareViewController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            let host = UIHostingController(
                rootView: ShareExtensionView(
                    providers: providers,
                    complete: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
                    cancel: { [weak self] in
                        self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
                    }))
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }
#else
    import AppKit

    final class ShareViewController: NSViewController {
        override func loadView() {
            let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            let hosting = NSHostingView(
                rootView: ShareExtensionView(
                    providers: providers,
                    complete: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
                    cancel: { [weak self] in
                        self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
                    }))
            hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
            view = hosting
        }
    }
#endif

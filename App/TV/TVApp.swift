// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import SwiftUI

/// Nextcloud Photos for Apple TV (SPEC §15.3): memories and albums on the big screen, slideshows, a family slideshow and
/// the Top Shelf. The app signs in with Login Flow v2 on the user's phone (a QR code) and shares the account, sync engine
/// and store with the other platforms (`PhotosCore`); its screens are its own, made for the Siri Remote.
@main
struct NextcloudPhotosTVApp: App {
    @State private var app = AppModel()
    @State private var router = TVRouter()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(app)
                .environment(router)
                // The Top Shelf's memories (`nextcloudphotos://memories/<id>[/play]`) and the family slideshow.
                .onOpenURL { url in
                    if let route = TVRoute(url: url) { router.pending = route }
                }
                #if DEBUG
                    // UI checks: PHOTOS_DEBUG_TV_ROUTE=nextcloudphotos://… opens a Top Shelf link at launch (the system's
                    // "Open in…?" question of `simctl openurl` needs a remote).
                    .onAppear {
                        if let link = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_TV_ROUTE"], let url = URL(string: link) {
                            router.pending = TVRoute(url: url)
                        }
                    }
                #endif
        }
    }
}

/// A link from the Top Shelf, waiting for the home screen to open it (it may arrive before the library has loaded).
@MainActor
@Observable
final class TVRouter {
    var pending: TVRoute?
}

struct TVRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session = app.session, !app.needsLogin, !session.isSignedOut {
                TVHomeView(session: session)
                    .environment(session)
                    // Films shared over SharePlay from a FaceTime call (SPEC §16.6).
                    .tvWatchTogether(session: session)
                    .id(session.account.id)
            } else {
                TVLoginView(signedOutAccount: app.session?.isSignedOut == true ? app.session?.account : nil)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.session?.didBecomeActive() }
        }
    }
}

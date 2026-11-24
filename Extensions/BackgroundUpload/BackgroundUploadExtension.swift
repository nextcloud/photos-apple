// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import ExtensionFoundation
import Photos
import PhotosCore

/// PhotoKit's background-upload extension (`com.apple.photos.background-upload`, SPEC §7.18.6). The system starts it while
/// backup is on (`PHPhotoLibrary.enableUploadJobExtension`), also when the app is not running: it records the uploads
/// PhotoKit finished and creates jobs for photos that are not on the server yet; PhotoKit reads each resource from the
/// library (from iCloud when needed) and sends it. Files over 100 MB and converted files are left to the app.
@main
final class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension {
    required init() {}

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        await BackgroundUploadExtensionHost.processJobs()
    }

    func willTerminate() async {
        BackgroundUploadExtensionHost.willTerminate()
    }
}

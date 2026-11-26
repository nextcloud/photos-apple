// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(iOS)
    import BackgroundTasks
    import os

    extension BGTaskScheduler {
        /// Submits a request and logs it when the system refuses it. The 27 SDKs deprecate the synchronous `submit(_:)`,
        /// which missed some errors; as before, a refused request is not retried here (the next `schedule()` asks again).
        public func submitLoggingErrors(_ request: BGTaskRequest, logger: Logger) {
            let identifier = request.identifier
            submitTaskRequest(request) { error in
                guard let error else { return }
                logger.error(
                    "background task \(identifier, privacy: .public) not scheduled: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
#endif

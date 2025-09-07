import Foundation
import ComposableArchitecture
import XCTestDynamicOverlay

/// A client that centralizes persistence of cleared history and deletion of associated audio files.
struct HistoryStorageClient: Sendable {
    /// Persists the cleared history, then deletes all audio files associated with the provided transcripts.
    /// - Parameters:
    ///   - sharedHistory: The shared TranscriptionHistory storage to persist after clearing its contents.
    ///   - transcripts: The transcripts whose audio files should be deleted (if any).
    var persistClearedHistoryAndDeleteFiles: @Sendable (_ sharedHistory: Shared<TranscriptionHistory>, _ transcripts: [Transcript]) async throws -> Void

    /// Persists the current history, then deletes the provided files (if any).
    /// - Parameters:
    ///   - sharedHistory: The shared TranscriptionHistory storage to persist.
    ///   - files: The files to delete after a successful save.
    var persistHistoryAndDeleteFiles: @Sendable (_ sharedHistory: Shared<TranscriptionHistory>, _ files: [URL]) async throws -> Void
}

extension HistoryStorageClient: DependencyKey {
    static var liveValue: HistoryStorageClient {
        Self(
            persistClearedHistoryAndDeleteFiles: { sharedHistory, transcripts in
                // Save first; if this throws, do not delete any files.
                try await sharedHistory.save()

                // Delete associated audio files via helper.
                let urls = transcripts.compactMap(\.audioPath)
                await Self.deleteFiles(urls)
            },
            persistHistoryAndDeleteFiles: { sharedHistory, files in
                // Save first; if this throws, do not delete any files.
                try await sharedHistory.save()

                // Delete provided files after a successful save via helper.
                await Self.deleteFiles(files)
            }
        )
    }
}

extension HistoryStorageClient: TestDependencyKey {
    static var previewValue: HistoryStorageClient {
        Self(
            persistClearedHistoryAndDeleteFiles: { sharedHistory, _ in
                // Preview: persist only, do not delete files
                try await sharedHistory.save()
            },
            persistHistoryAndDeleteFiles: { sharedHistory, _ in
                // Preview: persist only, do not delete files
                try await sharedHistory.save()
            }
        )
    }

    static var testValue: HistoryStorageClient {
        Self(
            persistClearedHistoryAndDeleteFiles: { _, _ in
                XCTFail("Unimplemented: HistoryStorageClient.persistClearedHistoryAndDeleteFiles")
            },
            persistHistoryAndDeleteFiles: { _, _ in
                XCTFail("Unimplemented: HistoryStorageClient.persistHistoryAndDeleteFiles")
            }
        )
    }
}

private extension HistoryStorageClient {
    static func deleteFiles(_ urls: [URL]) async {
        @Dependency(\.fileClient) var fileClient
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    do {
                        try await fileClient.removeItem(url)
                    } catch {
                        // Ignore deletion errors to avoid surfacing non-critical cleanup failures.
                    }
                }
            }
            await group.waitForAll()
        }
    }
}

extension DependencyValues {
    var historyStorage: HistoryStorageClient {
        get { self[HistoryStorageClient.self] }
        set { self[HistoryStorageClient.self] = newValue }
    }
}

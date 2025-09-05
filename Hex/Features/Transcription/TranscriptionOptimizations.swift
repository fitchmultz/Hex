import Foundation
import WhisperKit

enum TranscriptionOptimizations {
    // Determine recommended concurrent workers with optional override (cap at 4)
    static func recommendedConcurrentWorkers(override: Int?) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let cap = 4
        if let override, override > 0 {
            return max(1, min(override, cap))
        }
        return max(1, min(cores, cap))
    }

    // Build DecodingOptions using only supported fields in the current WhisperKit API
    // - Uses ChunkingStrategy.vad when enabled; otherwise .none
    // - Sets language and detectLanguage appropriately
    // - Applies concurrentWorkerCount if enabled; no concurrentChunkCount/vadOptions usage
    static func buildOptimizedDecodeOptions(language: String?, settings: HexSettings) -> DecodingOptions {
        var options = DecodingOptions()

        if let lang = language, !lang.isEmpty {
            options.language = lang
            options.detectLanguage = false
        } else {
            options.language = nil
            options.detectLanguage = true
        }

        if settings.useLegacyDecodePath {
            // Phase 1 fallback
            options.chunkingStrategy = ChunkingStrategy.none
            options.concurrentWorkerCount = 1
            return options
        }

        // Phase 2 Milestone A: tuned VAD and bounded concurrency (supported API only)
        options.chunkingStrategy = settings.enableVADTuning ? ChunkingStrategy.vad : ChunkingStrategy.none

        let workers: Int
        if settings.enableConcurrentDecoding {
            workers = recommendedConcurrentWorkers(override: settings.concurrentWorkerOverride)
        } else {
            workers = 1
        }
        options.concurrentWorkerCount = max(1, workers)

        return options
    }

    // Backward-compatible overload (Phase 1 default behavior)
    static func buildOptimizedDecodeOptions(language: String?) -> DecodingOptions {
        var options = DecodingOptions()
        if let lang = language, !lang.isEmpty {
            options.language = lang
            options.detectLanguage = false
        } else {
            options.language = nil
            options.detectLanguage = true
        }
        options.chunkingStrategy = ChunkingStrategy.none
        options.concurrentWorkerCount = 1
        return options
    }
}

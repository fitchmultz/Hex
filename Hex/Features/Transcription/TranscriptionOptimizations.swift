import Foundation
import WhisperKit
import CoreML

enum TranscriptionOptimizations {
    static func buildComputeOptions(for _: String, settings: HexSettings) -> ModelComputeOptions? {
        // Respect legacy path or explicit disablement: do not override compute units
        if settings.useLegacyDecodePath || !settings.enableHardwareAcceleration {
            return nil
        }
        // Prefer all available accelerators (GPU + Neural Engine) on Apple Silicon; safe CPU fallback elsewhere.
        return ModelComputeOptions(
            melCompute: .all,
            audioEncoderCompute: .all,
            textDecoderCompute: .all,
            prefillCompute: .all
        )
    }
    // Determine recommended concurrent workers with optional override (cap at 4)
    static func recommendedConcurrentWorkers(override: Int?) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #if arch(arm64)
        let isAppleSilicon = true
        #else
        let isAppleSilicon = false
        #endif

        let cap: Int
        if isAppleSilicon && cores >= 8 {
            // Apple Silicon with 8+ cores (e.g., M1/M2 Pro/Max): allow up to 8 workers
            cap = 8
        } else {
            // Default cap for other architectures or smaller core-count devices
            cap = 4
        }

        if let override, override > 0 {
            return max(1, min(override, cap))
        }
        return max(1, min(cores, cap))
    }

    // Build DecodingOptions using only supported fields in the current WhisperKit API
    // - Uses ChunkingStrategy.vad when enabled; otherwise .none
    // - Sets language and detectLanguage appropriately
    // - Applies concurrentWorkerCount if enabled; no concurrentChunkCount/vadOptions usage
    // - Uses lower temperature (0.0) to reduce hallucinations like "Thank you"
    static func buildOptimizedDecodeOptions(language: String?, settings: HexSettings) -> DecodingOptions {
        var options = DecodingOptions(
            temperature: 0.0, // Lower temperature to reduce hallucinations
            temperatureIncrementOnFallback: 0.1, // Smaller increments
            temperatureFallbackCount: 3 // Fewer fallback attempts
        )

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
        var options = DecodingOptions(
            temperature: 0.0, // Lower temperature to reduce hallucinations
            temperatureIncrementOnFallback: 0.1, // Smaller increments
            temperatureFallbackCount: 3 // Fewer fallback attempts
        )
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

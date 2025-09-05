import Foundation
import WhisperKit

/// Centralized performance tuning utilities for transcription.
/// Provides consistent configuration for concurrency and VAD across the app.
enum TranscriptionOptimizations {
    /// Returns a recommended number of concurrent workers based on active CPU cores,
    /// capped at a safe upper bound to avoid oversubscription on smaller machines.
    static func recommendedConcurrentWorkers() -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // Cap at 4 to keep UI responsive while maintaining good throughput.
        return max(1, min(4, cores))
    }
    
    /// Default VAD tuning optimized for typical speech transcription.
    /// These values reduce latency and improve chunking without sacrificing accuracy.
    static func defaultVAD() -> VADOptions {
        VADOptions(
            minSilenceDurationMs: 100,
            maxSilenceDurationMs: 2000,
            speechPadMs: 200,
            minSpeechDurationMs: 50
        )
    }
    
    /// Builds optimized decoding options with tuned VAD and bounded concurrency.
    /// - Parameters:
    ///   - language: The desired output language, or nil to auto-detect.
    ///   - concurrentChunkCount: The number of chunks to process in parallel (default 2).
    /// - Returns: A configured DecodingOptions instance.
    static func buildOptimizedDecodeOptions(
        language: String?,
        concurrentChunkCount: Int = 2
    ) -> DecodingOptions {
        let workers = recommendedConcurrentWorkers()
        return DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            chunkingStrategy: .vad,
            vadOptions: defaultVAD(),
            concurrentWorkerCount: workers,
            concurrentChunkCount: concurrentChunkCount
        )
    }
}
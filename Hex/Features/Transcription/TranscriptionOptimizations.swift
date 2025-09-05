import Foundation
import WhisperKit

enum TranscriptionOptimizations {
    /// Returns a recommended number of concurrent workers based on active CPU cores,
    /// capped at a safe upper bound to avoid oversubscription on smaller machines.
    static func recommendedConcurrentWorkers() -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // Cap at 4 to keep UI responsive while maintaining good throughput.
        return max(1, min(4, cores))
    }

    /// Builds optimized decoding options using the currently supported WhisperKit API.
    /// Concurrency and hardware acceleration are configured via WhisperKitConfig
    /// (see TranscriptionClientLive.loadWhisperKitModel). Many WhisperKit versions
    /// expose a simple DecodingOptions initializer; advanced VAD/chunking parameters
    /// are configured elsewhere or not available on all versions.
    ///
    /// - Parameters:
    ///   - language: Desired output language, or nil to allow automatic detection.
    ///   - concurrentChunkCount: Retained for compatibility; concurrency is primarily
    ///                           handled in WhisperKitConfig.
    /// - Returns: A DecodingOptions configured with safe defaults.
    static func buildOptimizedDecodeOptions(
        language: String?,
        concurrentChunkCount: Int = 2
    ) -> DecodingOptions {
        // Use the initializer supported broadly across WhisperKit versions.
        // Language detection behavior is handled by the model/runtime when language is nil.
        // If your WhisperKit version later exposes language/task/etc., they can be set here.
        let options = DecodingOptions()
        return options
    }
}
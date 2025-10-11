//
//  TranscriptionClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import WhisperKit
import CoreML
import Metal
#if canImport(FluidAudio)
import FluidAudio
#endif
import ComposableArchitecture

/// A client that downloads and loads WhisperKit models, then transcribes audio files using the loaded model.
/// Exposes progress callbacks to report overall download-and-load percentage and transcription progress.
@DependencyClient
struct TranscriptionClient {
    /// Transcribes an audio file at the specified `URL` using the named `model`.
    /// Reports transcription progress via `progressCallback`.
    var transcribe: @Sendable (URL, String, DecodingOptions, @escaping (Progress) -> Void) async throws -> String

    /// Ensures a model is downloaded (if missing) and loaded into memory, reporting progress via `progressCallback`.
    var downloadModel: @Sendable (String, @escaping (Progress) -> Void) async throws -> Void

    /// Deletes a model from disk if it exists
    var deleteModel: @Sendable (String) async throws -> Void

    /// Checks if a named model is already downloaded on this system.
    var isModelDownloaded: @Sendable (String) async -> Bool = { _ in false }

    /// Fetches a recommended set of models for the user's hardware from Hugging Face's `argmaxinc/whisperkit-coreml`.
    var getRecommendedModels: @Sendable () async throws -> ModelSupport

    /// Lists all model variants found in `argmaxinc/whisperkit-coreml`.
    var getAvailableModels: @Sendable () async throws -> [String]
}

extension TranscriptionClient: DependencyKey {
    static var liveValue: Self {
        let live = TranscriptionClientLive()
        return Self(
            transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, progressCallback: $3) },
            downloadModel: { try await live.downloadAndLoadModel(variant: $0, progressCallback: $1) },
            deleteModel: { try await live.deleteModel(variant: $0) },
            isModelDownloaded: { await live.isModelDownloaded($0) },
            getRecommendedModels: { await live.getRecommendedModels() },
            getAvailableModels: { try await live.getAvailableModels() }
        )
    }
}

extension DependencyValues {
    var transcription: TranscriptionClient {
        get { self[TranscriptionClient.self] }
        set { self[TranscriptionClient.self] = newValue }
    }
}

/// An `actor` that manages WhisperKit models by downloading (from Hugging Face),
//  loading them into memory, and then performing transcriptions.

actor TranscriptionClientLive {
    // MARK: - Stored Properties

    /// The current in-memory `WhisperKit` instance, if any.
    private var whisperKit: WhisperKit?

    #if canImport(FluidAudio)
    /// Parakeet ASR manager (FluidAudio) when using Parakeet models.
    private var parakeetManager: AsrManager?
    #endif

    /// The name of the currently loaded model, if any.
    private var currentModelName: String?

    /// Small in-memory cache for model presence checks
    private var modelPresenceCache: [String: Bool] = [:]
    private var modelPresenceCacheTime: Date = .distantPast
    private let modelPresenceCacheTTL: TimeInterval = 30 // seconds

    /// Canary runtime (lazily initialized on first use).
    private var canaryRuntime: CanaryRuntime?
    private var activeCanaryVariant: String?

    /// The base folder under which we store model data (e.g., ~/Library/Application Support/...).
    private lazy var modelsBaseFolder: URL = {
        do {
            let appSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            // Typically: .../Application Support/com.kitlangton.Hex
            let ourAppFolder = appSupportURL.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
            // Inside there, store everything in /models
            let baseURL = ourAppFolder.appendingPathComponent("models", isDirectory: true)
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            return baseURL
        } catch {
            fatalError("Could not create Application Support folder: \(error)")
        }
    }()

    /// Base folder for runtime artifacts (Python environments, etc.).
    private lazy var runtimeBaseFolder: URL = {
        do {
            let appSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let ourAppFolder = appSupportURL.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
            let runtimeURL = ourAppFolder.appendingPathComponent("runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
            return runtimeURL
        } catch {
            fatalError("Could not create runtime folder: \(error)")
        }
    }()

    @Shared(.hexSettings) var hexSettings: HexSettings

    // MARK: - Public Methods

    /// Ensures the given `variant` model is downloaded and loaded, reporting
    /// overall progress (0%–50% for downloading, 50%–100% for loading).
    func downloadAndLoadModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
        // Special handling for corrupted or malformed variant names
        if variant.isEmpty {
            throw NSError(
                domain: "TranscriptionClient",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Cannot download model: Empty model name"
                ]
            )
        }

        let overallProgress = Progress(totalUnitCount: 100)
        overallProgress.completedUnitCount = 0
        progressCallback(overallProgress)

        print("[TranscriptionClientLive] Processing model: \(variant)")

        if isCanary(variant) {
            try await prepareCanaryModel(variant: variant, progressCallback: progressCallback)
            overallProgress.completedUnitCount = 100
            progressCallback(overallProgress)
            return
        }

        if isParakeet(variant) {
            // Parakeet path (uses FluidAudio when available). We treat download+load as a single phase.
            #if canImport(FluidAudio)
            overallProgress.completedUnitCount = 10
            progressCallback(overallProgress)
            try await loadParakeetModel(variant) { step in
                // Map coarse steps (0..1) to 10..100 range to keep UI moving.
                let fraction = max(0.1, min(1.0, step))
                overallProgress.completedUnitCount = Int64(fraction * 100)
                progressCallback(overallProgress)
            }
            #else
            throw NSError(
                domain: "TranscriptionClient",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Parakeet selected (\(variant)), but FluidAudio is not linked. Add the FluidAudio Swift package to build Parakeet support."]
            )
            #endif
        } else {
            // Whisper path
            // 1) Model download phase (0-50% progress)
            if !(await isModelDownloaded(variant)) {
                try await downloadModelIfNeeded(variant: variant) { downloadProgress in
                    let fraction = downloadProgress.fractionCompleted * 0.5
                    overallProgress.completedUnitCount = Int64(fraction * 100)
                    progressCallback(overallProgress)
                }
            } else {
                // Skip download phase if already downloaded
                overallProgress.completedUnitCount = 50
                progressCallback(overallProgress)
            }

            // 2) Model loading phase (50-100% progress)
            try await loadWhisperKitModel(variant) { loadingProgress in
                let fraction = 0.5 + (loadingProgress.fractionCompleted * 0.5)
                overallProgress.completedUnitCount = Int64(fraction * 100)
                progressCallback(overallProgress)
            }
        }

        // Final progress update
        overallProgress.completedUnitCount = 100
        progressCallback(overallProgress)
    }

    /// Deletes a model from disk if it exists
    func deleteModel(variant: String) async throws {
        let modelFolder = modelPath(for: variant)

        if isCanary(variant) {
            let fileURL = canaryModelFileURL(for: variant)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if currentModelName == variant { unloadCurrentModel() }
                try FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                print("[TranscriptionClientLive] Deleted Canary checkpoint: \(variant)")
            }
            return
        }

        // Check if the model exists
        guard FileManager.default.fileExists(atPath: modelFolder.path) else {
            // Model doesn't exist, nothing to delete
            return
        }

        // If this is the currently loaded model, unload it first
        if currentModelName == variant {
            unloadCurrentModel()
        }

        // Delete the model directory
        try FileManager.default.removeItem(at: modelFolder)

        print("[TranscriptionClientLive] Deleted model: \(variant)")
    }

    /// Returns `true` if the model is already downloaded to the local folder.
    /// Performs a thorough check to ensure the model files are actually present and usable.
    func isModelDownloaded(_ modelName: String) async -> Bool {
        // Use a short-lived cache to reduce repeated filesystem scans
        let now = Date()
        if now.timeIntervalSince(modelPresenceCacheTime) > modelPresenceCacheTTL {
            modelPresenceCache.removeAll()
            modelPresenceCacheTime = now
        }
        if let cached = modelPresenceCache[modelName] {
            return cached
        }

        if isCanary(modelName) {
            let fileURL = canaryModelFileURL(for: modelName)
            let present = FileManager.default.fileExists(atPath: fileURL.path)
            modelPresenceCache[modelName] = present
            return present
        }

        // Parakeet models may be managed by a different runtime; check for local presence first,
        // then allow runtime-managed models to report available when loaded once.
        if isParakeet(modelName) {
            // Check our conventional folder layout for Parakeet Core ML bundles
            let modelFolderPath = modelPath(for: modelName).path
            let fm = FileManager.default
            if fm.fileExists(atPath: modelFolderPath) {
                do {
                    let contents = try fm.contentsOfDirectory(atPath: modelFolderPath)
                    let hasParakeetCoreML =
                        contents.contains { $0.hasSuffix("ParakeetEncoder.mlmodelc") } &&
                        contents.contains { $0.hasSuffix("ParakeetDecoder.mlmodelc") } &&
                        contents.contains { $0.hasSuffix("RNNTJoint.mlmodelc") }
                    modelPresenceCache[modelName] = hasParakeetCoreML
                    return hasParakeetCoreML
                } catch {
                    modelPresenceCache[modelName] = false
                    return false
                }
            }
            // If not found locally, we conservatively report "not downloaded"; the Parakeet runtime
            // may fetch on first use.
            modelPresenceCache[modelName] = false
            return false
        }

        let modelFolderPath = modelPath(for: modelName).path
        let fileManager = FileManager.default

        // First, check if the basic model directory exists
        guard fileManager.fileExists(atPath: modelFolderPath) else {
            // Don't print logs that would spam the console
            return false
        }

        do {
            // Check if the directory has actual model files in it
            let contents = try fileManager.contentsOfDirectory(atPath: modelFolderPath)

            // Model should have multiple files and certain key components
            guard !contents.isEmpty else {
                return false
            }

            // Check for specific model structure - need both tokenizer and model files
            let hasModelFiles = contents.contains { $0.hasSuffix(".mlmodelc") || $0.contains("model") }
            let tokenizerFolderPath = tokenizerPath(for: modelName).path
            let hasTokenizer = fileManager.fileExists(atPath: tokenizerFolderPath)

            // Both conditions must be true for a model to be considered downloaded
            let present = hasModelFiles && hasTokenizer
            modelPresenceCache[modelName] = present
            return present
        } catch {
            modelPresenceCache[modelName] = false
            return false
        }
    }

    /// Returns a list of recommended models based on current device hardware.
    func getRecommendedModels() async -> ModelSupport {
        await WhisperKit.recommendedRemoteModels()
    }

    /// Lists all model variants available in the `argmaxinc/whisperkit-coreml` repository.
    func getAvailableModels() async throws -> [String] {
        var names = try await WhisperKit.fetchAvailableModels()
        // Also advertise Parakeet Core ML variants supported by our runtime.
        names.append(contentsOf: parakeetVariants)
        names.append(contentsOf: canaryVariants)
        return names
    }

    /// Transcribes the audio file at `url` using a `model` name.
    /// If the model is not yet loaded (or if it differs from the current model), it is downloaded and loaded first.
    /// Transcription progress can be monitored via `progressCallback`.
    func transcribe(
        url: URL,
        model: String,
        options: DecodingOptions,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        if isCanary(model) {
            if currentModelName != model {
                unloadCurrentModel()
                try await downloadAndLoadModel(variant: model) { progress in
                    progressCallback(progress)
                }
            }

            let runtime = try await canaryRuntimeInstance(for: model)
            let wavURL = try exportAudioForCanary(url: url)
            defer { try? FileManager.default.removeItem(at: wavURL) }
            let text = try await runtime.transcribe(wavURL)
            currentModelName = model
            return text
        }

        if isParakeet(model) {
            #if canImport(FluidAudio)
            // Reuse existing Parakeet engine if the same variant is already loaded.
            if currentModelName != model || parakeetManager == nil {
                try await downloadAndLoadModel(variant: model) { p in progressCallback(p) }
            }
            // Ensure engine exists
            guard let parakeetManager else {
                throw NSError(domain: "TranscriptionClient", code: -8, userInfo: [NSLocalizedDescriptionKey: "Parakeet manager not initialized"])
            }

            // Load audio and convert to 16 kHz mono float32 samples
            let norm = try loadAudioAs16kMonoFloats(url: url)
            let result = try await parakeetManager.transcribe(norm)
            // The result object contains the transcribed text.
            return result.text
            #else
            throw NSError(
                domain: "TranscriptionClient",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Parakeet selected (\(model)), but FluidAudio is not linked. Add the FluidAudio Swift package to enable Parakeet."]
            )
            #endif
        } else {
            // Whisper path
            // Load or switch to the required model if needed.
            if whisperKit == nil || model != currentModelName {
                unloadCurrentModel()
                try await downloadAndLoadModel(variant: model) { p in
                    // Debug logging, or scale as desired:
                    progressCallback(p)
                }
            }

            guard let whisperKit = whisperKit else {
                throw NSError(
                    domain: "TranscriptionClient",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to initialize WhisperKit for model: \(model)"
                    ]
                )
            }

            // Perform the transcription.
            let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)

            // Concatenate results from all segments.
            let text = results.map(\.text).joined(separator: " ")
            return text
        }
    }

    // MARK: - Private Helpers

    /// Creates or returns the local folder (on disk) for a given `variant` model.
    private func modelPath(for variant: String) -> URL {
        // Sanitize variant using a strict whitelist and unicode normalization
        let sanitizedVariant = sanitizeVariantName(variant)

        let base = modelsBaseFolder.resolvingSymlinksInPath()
        if isCanary(variant) {
            return base
                .appendingPathComponent("nvidia", isDirectory: true)
                .appendingPathComponent("canary", isDirectory: true)
                .appendingPathComponent(sanitizedVariant, isDirectory: true)
        } else if isParakeet(variant) {
            return base
                .appendingPathComponent("parakeet", isDirectory: true)
                .appendingPathComponent(sanitizedVariant, isDirectory: true)
        } else {
            return base
                .appendingPathComponent("argmaxinc")
                .appendingPathComponent("whisperkit-coreml")
                .appendingPathComponent(sanitizedVariant, isDirectory: true)
        }
    }

    /// Creates or returns the local folder for the tokenizer files of a given `variant`.
    private func tokenizerPath(for variant: String) -> URL {
        modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
    }

    private func canaryModelFileURL(for variant: String) -> URL {
        let sanitizedVariant = sanitizeVariantName(variant)
        return modelPath(for: variant).appendingPathComponent("\(sanitizedVariant).nemo", isDirectory: false)
    }

    private func prepareCanaryModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 0
        progressCallback(progress)

        try ensureMetalDeviceAvailable()
        progress.completedUnitCount = 10
        progressCallback(progress)

        try ensureCanaryEnvironment(for: variant)
        progress.completedUnitCount = 20
        progressCallback(progress)

        try await downloadCanaryModelIfNeeded(variant: variant, progress: progress, progressCallback: progressCallback)

        let runtime = try await canaryRuntimeInstance(for: variant)
        progress.completedUnitCount = 90
        progressCallback(progress)
        try await runtime.warmUp()
        currentModelName = variant
        activeCanaryVariant = variant
        progress.completedUnitCount = 100
        progressCallback(progress)
    }

    private func ensureMetalDeviceAvailable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw NSError(
                domain: "TranscriptionClient",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "No Metal device available for MPS backend"]
            )
        }
    }

    private func ensureCanaryEnvironment(for variant: String) throws {
        try ensureCanaryEnvironmentInstalled()
        _ = try canaryRuntimeConfiguration(for: variant)
    }

    private func downloadCanaryModelIfNeeded(
        variant: String,
        progress: Progress,
        progressCallback: @escaping (Progress) -> Void
    ) async throws {
        let fileURL = canaryModelFileURL(for: variant)
        let fm = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)

        if fm.fileExists(atPath: fileURL.path) {
            progress.completedUnitCount = 80
            progressCallback(progress)
            return
        }

        let downloadURL = URL(string: "https://huggingface.co/nvidia/canary-qwen-2.5b/resolve/main/canary-qwen-2.5b.nemo?download=true")!
        var request = URLRequest(url: downloadURL)
        request.setValue("Hex/CanaryRuntime", forHTTPHeaderField: "User-Agent")

        progress.completedUnitCount = 30
        progressCallback(progress)

        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        let expectedLength = response.expectedContentLength
        if expectedLength > 0 {
            progress.completedUnitCount = 70
            progressCallback(progress)
        }

        let tempURL = parent.appendingPathComponent(UUID().uuidString)
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }
        try fm.moveItem(at: downloadedURL, to: tempURL)

        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        try fm.moveItem(at: tempURL, to: fileURL)
        progress.completedUnitCount = 80
        progressCallback(progress)
    }

    private func canaryRuntimeConfiguration(for variant: String) throws -> CanaryRuntime.Configuration {
        let envRoot = canaryEnvironmentRoot()
        let python = envRoot
            .appendingPathComponent("bin")
            .appendingPathComponent("python3")

        guard FileManager.default.fileExists(atPath: python.path) else {
            throw NSError(domain: "TranscriptionClient", code: -24, userInfo: [NSLocalizedDescriptionKey: "Extracted Python runtime missing"])
        }

        guard let worker = Bundle.main.resourceURL?
            .appendingPathComponent("Canary")
            .appendingPathComponent("hex_canary_worker.py")
        else {
            throw NSError(domain: "TranscriptionClient", code: -25, userInfo: [NSLocalizedDescriptionKey: "Canary worker script missing from bundle"])
        }

        let model = canaryModelFileURL(for: variant)

        return CanaryRuntime.Configuration(
            pythonExecutable: python,
            workerScript: worker,
            modelCheckpoint: model
        )
    }

    private func canaryRuntimeInstance(for variant: String) async throws -> CanaryRuntime {
        if let runtime = canaryRuntime, activeCanaryVariant == variant {
            return runtime
        }

        if let runtime = canaryRuntime, activeCanaryVariant != variant {
            await runtime.shutdown()
            canaryRuntime = nil
        }

        let config = try canaryRuntimeConfiguration(for: variant)
        let runtime = CanaryRuntime(configuration: config)
        canaryRuntime = runtime
        activeCanaryVariant = variant
        return runtime
    }

    private func canaryEnvironmentRoot() -> URL {
        runtimeBaseFolder
            .appendingPathComponent("canary", isDirectory: true)
            .appendingPathComponent("python-env", isDirectory: true)
    }

    private func ensureCanaryEnvironmentInstalled() throws {
        let fm = FileManager.default
        let envRoot = canaryEnvironmentRoot()
        let pythonBinary = envRoot.appendingPathComponent("bin/python3")

        guard
            let archiveURL = (
                Bundle.main.url(forResource: "python-env", withExtension: "bin", subdirectory: "Canary") ??
                Bundle.main.url(forResource: "python-env", withExtension: "tar.gz.bin", subdirectory: "Canary") ??
                Bundle.main.url(forResource: "python-env", withExtension: "tar.gz", subdirectory: "Canary")
            ),
            let freezeURL = Bundle.main.url(forResource: "python-env-freeze", withExtension: "txt", subdirectory: "Canary")
        else {
            throw NSError(domain: "TranscriptionClient", code: -23, userInfo: [NSLocalizedDescriptionKey: "Canary runtime archive missing from bundle"])
        }

        let destinationFreeze = envRoot.appendingPathComponent("canary-freeze.txt")

        if fm.fileExists(atPath: pythonBinary.path),
           let bundledFreeze = try? Data(contentsOf: freezeURL),
           let installedFreeze = try? Data(contentsOf: destinationFreeze),
           bundledFreeze == installedFreeze {
            return
        }

        if fm.fileExists(atPath: envRoot.path) {
            try fm.removeItem(at: envRoot)
        }
        try fm.createDirectory(at: envRoot, withIntermediateDirectories: true, attributes: nil)

        try extractCanaryEnvironmentArchive(archiveURL, to: envRoot)

        if fm.fileExists(atPath: destinationFreeze.path) {
            try fm.removeItem(at: destinationFreeze)
        }
        try fm.copyItem(at: freezeURL, to: destinationFreeze)
    }

    private func extractCanaryEnvironmentArchive(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tar", "-xzf", archive.path, "-C", destination.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = nil

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown extraction error"
            throw NSError(
                domain: "TranscriptionClient",
                code: -26,
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract Canary runtime: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"]
            )
        }
    }

    // Unloads any currently loaded model (clears `whisperKit` and `currentModelName`).
    private func unloadCurrentModel() {
        whisperKit = nil
        currentModelName = nil
    }

    /// Strictly sanitize a model variant name to a safe directory component.
    /// - Uses Unicode compatibility normalization, lowercases, and allows only [a-z0-9._-].
    /// - Replaces other characters with `_`, collapses repeats, trims edges, and length-limits.
    /// - Falls back to a UUID if the result is empty.
    private func sanitizeVariantName(_ variant: String) -> String {
        // Normalize (compatibility composition) and lowercase
        let normalized = variant.precomposedStringWithCompatibilityMapping.lowercased()

        // Allowed characters
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")

        // Map scalars: keep allowed ASCII, replace the rest with '_'
        var interim = String(normalized.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })

        // Collapse multiple underscores
        while interim.contains("__") { interim = interim.replacingOccurrences(of: "__", with: "_") }

        // Trim underscores and dots from ends
        interim = interim.trimmingCharacters(in: CharacterSet(charactersIn: "_."))

        // Disallow special directory names after trimming
        if interim == "." || interim == ".." {
            interim = ""
        }

        // Limit length to a reasonable size
        if interim.count > 64 { interim = String(interim.prefix(64)) }

        // Ensure non-empty
        if interim.isEmpty { interim = "model-" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }

        return interim
    }

    /// Downloads the model to a temporary folder (if it isn't already on disk),
    /// then moves it into its final folder in `modelsBaseFolder`.
    private func downloadModelIfNeeded(
        variant: String,
        progressCallback: @escaping (Progress) -> Void
    ) async throws {
        if isParakeet(variant) {
            // Parakeet models are handled by the Parakeet runtime (FluidAudio) which downloads
            // artifacts as needed. We provide a best-effort attempt to initialize and let the
            // runtime fetch. This keeps the UI responsive without duplicating model hosting logic.
            #if canImport(FluidAudio)
            _ = try await loadParakeetModel(variant) { fraction in
                let p = Progress(totalUnitCount: 100)
                p.completedUnitCount = Int64(max(0.0, min(1.0, fraction)) * 100)
                progressCallback(p)
            }
            return
            #else
            throw NSError(
                domain: "TranscriptionClient",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Parakeet selected (\(variant)), but FluidAudio is not linked. Add the FluidAudio Swift package to enable Parakeet downloads."]
            )
            #endif
        }

        let modelFolder = modelPath(for: variant)

        // If the model folder exists but isn't a complete model, clean it up
        let isDownloaded = await isModelDownloaded(variant)
        if FileManager.default.fileExists(atPath: modelFolder.path) && !isDownloaded {
            try FileManager.default.removeItem(at: modelFolder)
        }

        // If model is already fully downloaded, we're done
        if isDownloaded {
            return
        }

        print("[TranscriptionClientLive] Downloading model: \(variant)")

        // Create parent directories
        let parentDir = modelFolder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        do {
            // Download directly using the exact variant name provided
            let tempFolder = try await WhisperKit.download(
                variant: variant,
                downloadBase: nil,
                useBackgroundSession: false,
                from: "argmaxinc/whisperkit-coreml",
                token: nil
            )                { progress in
                    progressCallback(progress)
                }

            // Ensure target folder exists
            try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)

            // Move the downloaded snapshot to the final location
            try moveContents(of: tempFolder, to: modelFolder)

            print("[TranscriptionClientLive] Downloaded model to: \(modelFolder.path)")
        } catch {
            // Clean up any partial download if an error occurred
            if FileManager.default.fileExists(atPath: modelFolder.path) {
                try? FileManager.default.removeItem(at: modelFolder)
            }

            // Rethrow the original error
            print("[TranscriptionClientLive] Error downloading model: \(error.localizedDescription)")
            throw error
        }
    }

    /// Loads a local model folder via `WhisperKitConfig`, optionally reporting load progress.
    private func loadWhisperKitModel(
        _ modelName: String,
        progressCallback: @escaping (Progress) -> Void
    ) async throws {
        let loadingProgress = Progress(totalUnitCount: 100)
        loadingProgress.completedUnitCount = 0
        progressCallback(loadingProgress)

        let modelFolder = modelPath(for: modelName)
        let tokenizerFolder = tokenizerPath(for: modelName)

        // Build compute options (nil => CPU-only / legacy fallback)
        let computeOptions = TranscriptionOptimizations.buildComputeOptions(for: modelName, settings: hexSettings)

        // Debug logging for hardware acceleration status
        let hwRequested = (hexSettings.enableHardwareAcceleration && !hexSettings.useLegacyDecodePath)
        print("[TranscriptionClientLive] Hardware acceleration \(hwRequested ? "requested" : "not requested"); computeOptions \(computeOptions == nil ? "nil (CPU/legacy path)" : "provided")")

        let config: WhisperKitConfig
        if let computeOptions {
            // Hardware acceleration path
            config = WhisperKitConfig(
                model: modelName,
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerFolder,
                computeOptions: computeOptions
            )
        } else {
            // Legacy/CPU-only path
            config = WhisperKitConfig(
                model: modelName,
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerFolder
            )
        }

        // The initializer automatically calls `loadModels`.
        whisperKit = try await WhisperKit(config)
        currentModelName = modelName

        // Finalize load progress
        loadingProgress.completedUnitCount = 100
        progressCallback(loadingProgress)

        print("[TranscriptionClientLive] Loaded WhisperKit model: \(modelName) (HWAccel: \(computeOptions != nil ? "ON" : "OFF"))")
    }

    /// Moves all items from `sourceFolder` into `destFolder` (shallow move of directory contents).
    private func moveContents(of sourceFolder: URL, to destFolder: URL) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(atPath: sourceFolder.path)
        for item in items {
            let src = sourceFolder.appendingPathComponent(item)
            let dst = destFolder.appendingPathComponent(item)
            try fileManager.moveItem(at: src, to: dst)
        }
    }
}

// MARK: - Parakeet helpers

private extension TranscriptionClientLive {
    func isCanary(_ name: String) -> Bool {
        name.lowercased().hasPrefix("canary-")
    }

    var canaryVariants: [String] {
        ["canary-qwen-2.5b-nemo"]
    }

    func isParakeet(_ name: String) -> Bool {
        name.lowercased().hasPrefix("parakeet-")
    }

    var parakeetVariants: [String] {
        [
            "parakeet-tdt-0.6b-v2-coreml", // English
            "parakeet-tdt-0.6b-v3-coreml" // Multilingual
        ]
    }

    #if canImport(FluidAudio)
    /// Load and initialize the selected Parakeet variant.
    ///
    /// Mapping:
    /// - v2 => English-only model (parakeet-tdt-0.6b-v2-coreml)
    /// - v3 => Multilingual model (parakeet-tdt-0.6b-v3-coreml)
    ///
    /// Notes:
    /// - We avoid re-initialization when the same variant is already loaded.
    /// - The FluidAudio API currently used here (AsrModels.downloadAndLoad + AsrManager.initialize)
    ///   does not expose an explicit per-flavor selection in this codebase. The mapping is documented
    ///   and ready to apply when/if the API provides a flavor-specific initializer.
    @discardableResult
    func loadParakeetModel(_ variant: String, progress: @escaping (Double) -> Void) async throws -> Bool {
        // Initialize manager once
        if parakeetManager == nil { parakeetManager = AsrManager() }

        // Early exit if the same Parakeet variant is already active
        if currentModelName == variant, parakeetManager != nil {
            progress(1.0)
            return true
        }

        // Determine the flavor from the variant name
        // Future: When the underlying Parakeet API exposes explicit flavor selection,
        // map variant strings to model flavors (e.g., v2 => English, v3 => Multilingual).

        progress(0.1)

        // Load (and download if necessary) Parakeet models using the FluidAudio runtime.
        // When the API supports explicit flavor choice, apply it here based on `parakeetFlavor(for:)`.
        let models = try await AsrModels.downloadAndLoad()
        progress(0.7)

        try await parakeetManager!.initialize(models: models)
        progress(1.0)

        // Track the active Parakeet variant
        currentModelName = variant
        return true
    }
    #endif

    /// Read an audio file and return 16 kHz mono Float32 samples suitable for Parakeet.
    func loadAudioAs16kMonoFloats(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "TranscriptionClient", code: -9, userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
        }

        // Fast path: already 16 kHz mono float32
        if inputFormat.sampleRate == 16_000,
           inputFormat.channelCount == 1,
           inputFormat.commonFormat == .pcmFormatFloat32 {
            let frameCount = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
                throw NSError(domain: "TranscriptionClient", code: -10, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffer"])
            }
            try file.read(into: buf)
            guard let ch = buf.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        }

        // Convert using AVAudioConverter
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "TranscriptionClient", code: -11, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio conversion path"])
        }

        var output: [Float] = []
        let inputCapacity: AVAudioFrameCount = 8192
        var inputDone = false

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: inputCapacity) else { break }

            let status = converter.convert(to: outBuf, error: nil) { _, outStatus in
                if inputDone {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    try file.read(into: inBuf, frameCount: inputCapacity)
                } catch {
                    outStatus.pointee = .endOfStream
                    inputDone = true
                    return nil
                }
                if inBuf.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    inputDone = true
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }

            if status == .haveData || outBuf.frameLength > 0 {
                let frames = Int(outBuf.frameLength)
                if let ch = outBuf.floatChannelData?[0] {
                    output.append(contentsOf: UnsafeBufferPointer(start: ch, count: frames))
                }
            }

            if status == .endOfStream || inputDone {
                break
            }
        }

        return output
    }

    func exportAudioForCanary(url: URL) throws -> URL {
        let samples = try loadAudioAs16kMonoFloats(url: url)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try writeWav(samples: samples, sampleRate: 16_000, to: tempURL)
        return tempURL
    }

    func writeWav(samples: [Float], sampleRate: Int, to url: URL) throws {
        let numChannels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        var chunkSize = UInt32(36 + samples.count * 2).littleEndian
        withUnsafeBytes(of: &chunkSize) { header.append(contentsOf: $0) }
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        var subChunk1Size: UInt32 = 16
        withUnsafeBytes(of: &subChunk1Size) { header.append(contentsOf: $0) }
        var audioFormat: UInt16 = 1
        withUnsafeBytes(of: &audioFormat) { header.append(contentsOf: $0) }
        var numChannelsLE = UInt16(numChannels)
        withUnsafeBytes(of: &numChannelsLE) { header.append(contentsOf: $0) }
        var sampleRateLE = UInt32(sampleRate)
        withUnsafeBytes(of: &sampleRateLE) { header.append(contentsOf: $0) }
        var byteRateLE = UInt32(byteRate)
        withUnsafeBytes(of: &byteRateLE) { header.append(contentsOf: $0) }
        var blockAlignLE = UInt16(blockAlign)
        withUnsafeBytes(of: &blockAlignLE) { header.append(contentsOf: $0) }
        var bitsPerSampleLE = UInt16(bitsPerSample)
        withUnsafeBytes(of: &bitsPerSampleLE) { header.append(contentsOf: $0) }
        header.append(contentsOf: "data".utf8)
        var dataSize = UInt32(samples.count * 2)
        withUnsafeBytes(of: &dataSize) { header.append(contentsOf: $0) }

        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            let clipped = max(-1.0, min(1.0, Double(sample)))
            var intSample = Int16(clipped * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &intSample) { pcmData.append(contentsOf: $0) }
        }

        var fileData = Data()
        fileData.append(header)
        fileData.append(pcmData)
        try fileData.write(to: url, options: .atomic)
    }

}

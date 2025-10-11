//
//  CanaryRuntime.swift
//  Hex
//
//  Created by Codex on 10/10/25.
//
//  Manages the embedded Python runtime that hosts NVIDIA's
//  Canary-Qwen-2.5B model via NeMo. This actor owns the process
//  lifecycle and provides a Swift-friendly API for synchronous
//  transcription requests.
//

import Foundation

actor CanaryRuntime {
    struct Configuration {
        let pythonExecutable: URL
        let workerScript: URL
        let modelCheckpoint: URL
    }

    enum RuntimeError: LocalizedError {
        case missingBundleResources
        case workerCrashed(message: String)
        case invalidReply
        case notReady
        case mpsUnavailable

        var errorDescription: String? {
            switch self {
            case .missingBundleResources:
                return "Canary resources are missing from the application bundle."
            case .workerCrashed(let message):
                return "Canary worker exited unexpectedly: \(message)"
            case .invalidReply:
                return "Received an invalid response from the Canary worker."
            case .notReady:
                return "Canary worker is not ready."
            case .mpsUnavailable:
                return "Metal Performance Shaders are not available on this machine."
            }
        }
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrPipe: Pipe?
    private var isReady = false

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func warmUp() async throws {
        if isReady, process?.isRunning == true { return }
        try launchProcess()
        try await waitForReady()
    }

    func shutdown() async {
        guard let process else { return }
        do {
            try sendMessage(["command": "shutdown"])
        } catch {
            // Ignored; process may already be gone.
        }
        process.terminate()
        self.process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrPipe = nil
        isReady = false
    }

    func transcribe(_ wavURL: URL) async throws -> String {
        try await warmUp()
        try sendMessage([
            "command": "transcribe",
            "path": wavURL.path
        ])

        let reply = try await readMessage()
        guard let type = reply["type"] as? String else {
            throw RuntimeError.invalidReply
        }

        switch type {
        case "result":
            guard let text = reply["text"] as? String else {
                throw RuntimeError.invalidReply
            }
            return text
        case "error":
            let message = reply["error"] as? String ?? "Unknown error"
            throw RuntimeError.workerCrashed(message: message)
        default:
            throw RuntimeError.invalidReply
        }
    }

    // MARK: - Private helpers

    private func launchProcess() throws {
        guard FileManager.default.fileExists(atPath: configuration.pythonExecutable.path)
        else { throw RuntimeError.missingBundleResources }
        guard FileManager.default.fileExists(atPath: configuration.workerScript.path)
        else { throw RuntimeError.missingBundleResources }
        guard FileManager.default.fileExists(atPath: configuration.modelCheckpoint.path)
        else { throw RuntimeError.missingBundleResources }

        let python = configuration.pythonExecutable.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        let stdout = Pipe()
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = stderr

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "0"
        env["MPS_NO_FALLBACK"] = "1"
        process.environment = env
        process.arguments = [
            configuration.workerScript.path,
            "--model", configuration.modelCheckpoint.path,
            "--device", "mps"
        ]

        try process.run()
        self.process = process
        stdinHandle = stdin.fileHandleForWriting
        stdoutHandle = stdout.fileHandleForReading
        stderrPipe = stderr
    }

    private func waitForReady() async throws {
        let reply = try await readMessage()
        guard let type = reply["type"] as? String else {
            throw RuntimeError.invalidReply
        }
        switch type {
        case "ready":
            isReady = true
        case "fatal":
            let message = reply["error"] as? String ?? "Unknown startup error"
            throw RuntimeError.workerCrashed(message: message)
        default:
            throw RuntimeError.invalidReply
        }
    }

    private func sendMessage(_ payload: [String: Any]) throws {
        guard let stdinHandle else { throw RuntimeError.notReady }
        let data = try JSONSerialization.data(withJSONObject: payload)
        var buffer = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
        buffer.append(data)
        stdinHandle.write(buffer)
    }

    private func readMessage() async throws -> [String: Any] {
        guard let stdoutHandle else { throw RuntimeError.notReady }
        let header = try await readExactly(4, from: stdoutHandle)
        let length = header.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        let payload = try await readExactly(Int(length), from: stdoutHandle)
        let object = try JSONSerialization.jsonObject(with: payload)
        guard let dict = object as? [String: Any] else {
            throw RuntimeError.invalidReply
        }
        return dict
    }

    private func readExactly(_ count: Int, from handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    var collected = Data()
                    while collected.count < count {
                        let chunk = try handle.read(upToCount: count - collected.count) ?? Data()
                        if chunk.isEmpty {
                            throw RuntimeError.workerCrashed(message: "Unexpected EOF")
                        }
                        collected.append(chunk)
                    }
                    continuation.resume(returning: collected)
                } catch {
                    if let error = error as? RuntimeError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: RuntimeError.workerCrashed(message: error.localizedDescription))
                    }
                }
            }
        }
    }
}

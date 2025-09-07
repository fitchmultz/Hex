//
//  RecordingClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit // For NSEvent media key simulation
import AVFoundation
import ComposableArchitecture
import CoreAudio
import Dependencies
import DependenciesMacros
import Foundation

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Equatable {
  var id: String
  var name: String
}

@DependencyClient
struct RecordingClient {
  var startRecording: @Sendable () async -> Void = {}
  var stopRecording: @Sendable () async -> URL = { URL(fileURLWithPath: "") }
  var requestMicrophoneAccess: @Sendable () async -> Bool = { false }
  var observeAudioLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
  var getAvailableInputDevices: @Sendable () async -> [AudioInputDevice] = { [] }
}

extension RecordingClient: DependencyKey {
  static var liveValue: Self {
    let live = RecordingClientLive()
    return Self(
      startRecording: { await live.startRecording() },
      stopRecording: { await live.stopRecording() },
      requestMicrophoneAccess: { await live.requestMicrophoneAccess() },
      observeAudioLevel: { await live.observeAudioLevel() },
      getAvailableInputDevices: { await live.getAvailableInputDevices() }
    )
  }
}

/// Simple structure representing audio metering values.
struct Meter: Equatable {
  let averagePower: Double
  let peakPower: Double
}

// Define function pointer types for the MediaRemote functions.
typealias MRNowPlayingIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

/// Wraps a few MediaRemote functions.
@Observable
class MediaRemoteController {
  private var mediaRemoteHandle: UnsafeMutableRawPointer?
  private var mrNowPlayingIsPlaying: MRNowPlayingIsPlayingFunc?

  init?() {
    // Open the private framework.
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) as UnsafeMutableRawPointer? else {
      print("Unable to open MediaRemote")
      return nil
    }
    mediaRemoteHandle = handle

    // Get pointer for the "is playing" function.
    guard let playingPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
      print("Unable to find MRMediaRemoteGetNowPlayingApplicationIsPlaying")
      return nil
    }
    mrNowPlayingIsPlaying = unsafeBitCast(playingPtr, to: MRNowPlayingIsPlayingFunc.self)
  }

  deinit {
    if let handle = mediaRemoteHandle {
      dlclose(handle)
    }
  }

  /// Asynchronously refreshes the "is playing" status.
  func isMediaPlaying() async -> Bool {
    await withCheckedContinuation { continuation in
      mrNowPlayingIsPlaying?(DispatchQueue.main) {  isPlaying in
        continuation.resume(returning: isPlaying)
      }
    }
  }
}

// Global instance of MediaRemoteController
private let mediaRemoteController = MediaRemoteController()

func isAudioPlayingOnDefaultOutput() async -> Bool {
  // Refresh the state before checking
  return await mediaRemoteController?.isMediaPlaying() ?? false
}

/// Check if an application is installed by looking for its bundle
private func isAppInstalled(bundleID: String) -> Bool {
  let workspace = NSWorkspace.shared
  return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
}

/// Get a list of installed media player apps we should control
private func getInstalledMediaPlayers() -> [String: String] {
  var result: [String: String] = [:]

  if isAppInstalled(bundleID: "com.apple.Music") {
    result["Music"] = "com.apple.Music"
  }

  if isAppInstalled(bundleID: "com.apple.iTunes") {
    result["iTunes"] = "com.apple.iTunes"
  }

  if isAppInstalled(bundleID: "com.spotify.client") {
    result["Spotify"] = "com.spotify.client"
  }

  if isAppInstalled(bundleID: "org.videolan.vlc") {
    result["VLC"] = "org.videolan.vlc"
  }

  return result
}

/// Check if an application is currently running by bundle identifier
private func isAppRunning(bundleID: String) -> Bool {
  NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
}

/// Get a list of installed media player apps that are currently running
private func getRunningMediaPlayers() -> [String: String] {
  getInstalledMediaPlayers().filter { isAppRunning(bundleID: $0.value) }
}

func pauseAllMediaApplications() async -> [String] {
  // Only target players that are currently running to avoid launching or prompting
  let runningPlayers = getRunningMediaPlayers()
  if runningPlayers.isEmpty {
    return []
  }

  print("Running media players: \(runningPlayers.keys.joined(separator: ", "))")

  // Create AppleScript that only targets installed players
  var scriptParts: [String] = ["set pausedPlayers to {}"]

  for (appName, _) in runningPlayers {
    if appName == "VLC" {
      // VLC: only pause if actually playing; wrap in inner try to avoid script errors
      scriptParts.append("""
      try
        tell application id "org.videolan.vlc"
          try
            if playing is true then
              pause
              set end of pausedPlayers to "VLC"
            end if
          end try
        end tell
      end try
      """)
    } else {
      // Music / iTunes / Spotify: only pause if actually playing
      scriptParts.append("""
      try
        tell application "\(appName)"
          try
            if player state is playing then
              pause
              set end of pausedPlayers to "\(appName)"
            end if
          end try
        end tell
      end try
      """)
    }
  }

  scriptParts.append("return pausedPlayers")
  let script = scriptParts.joined(separator: "\n\n")

  let appleScript = NSAppleScript(source: script)
  var error: NSDictionary?
  guard let resultDescriptor = appleScript?.executeAndReturnError(&error) else {
    if let error = error {
      print("Error pausing media applications: \(error)")
    }
    return []
  }

  // Convert AppleScript list to Swift array
  let pausedPlayers = (1...resultDescriptor.numberOfItems).compactMap {
    resultDescriptor.atIndex($0)?.stringValue
  }

  print("Paused media players: \(pausedPlayers.joined(separator: ", "))")

  return pausedPlayers
}

func resumeMediaApplications(_ players: [String]) async {
  guard !players.isEmpty else { return }

  // First check which media players are actually installed
  let installedPlayers = getInstalledMediaPlayers()

  // Only attempt to resume players that are installed
  let validPlayers = players.filter { installedPlayers.keys.contains($0) }
  if validPlayers.isEmpty {
    return
  }

  // Create specific resume script for each player
  var scriptParts: [String] = []

  for player in validPlayers {
    if player == "VLC" {
      // VLC has a different AppleScript interface
      scriptParts.append("""
      try
        tell application id "org.videolan.vlc"
          if it is running then
            tell application id "org.videolan.vlc" to play
          end if
        end tell
      end try
      """)
    } else {
      // Standard interface for Music/iTunes/Spotify
      scriptParts.append("""
      try
        if application "\(player)" is running then
          tell application "\(player)" to play
        end if
      end try
      """)
    }
  }

  let script = scriptParts.joined(separator: "\n\n")

  let appleScript = NSAppleScript(source: script)
  var error: NSDictionary?
  appleScript?.executeAndReturnError(&error)
  if let error = error {
    print("Error resuming media applications: \(error)")
  }
}

/// Simulates a media key press (the Play/Pause key) by posting a system-defined NSEvent.
/// This toggles the state of the active media app.
private func sendMediaKey() {
  let NX_KEYTYPE_PLAY: UInt32 = 16
  func postKeyEvent(down: Bool) {
    let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
    let data1 = Int((NX_KEYTYPE_PLAY << 16) | (down ? 0xA << 8 : 0xB << 8))
    if let event = NSEvent.otherEvent(with: .systemDefined,
                                      location: .zero,
                                      modifierFlags: flags,
                                      timestamp: 0,
                                      windowNumber: 0,
                                      context: nil,
                                      subtype: 8,
                                      data1: data1,
                                      data2: -1)
    {
      event.cgEvent?.post(tap: .cghidEventTap)
    }
  }
  postKeyEvent(down: true)
  postKeyEvent(down: false)
}

// MARK: - RecordingClientLive Implementation

actor RecordingClientLive {
  private var recorder: AVAudioRecorder?
  // Use a unique file per session to avoid races when a new recording starts
  // while a previous transcription is still reading the last file.
  private var currentRecordingURL: URL?
  private let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
  private var meterTask: Task<Void, Never>?

  @Shared(.hexSettings) var hexSettings: HexSettings

  // MARK: - Output audio mute/volume state while recording
  // Instead of pausing media apps (which can break with VLC),
  // we mute the default output device while recording and restore afterwards.
  private var outputDeviceAtStart: AudioDeviceID?
  private var previousOutputMute: Bool?
  private var previousOutputVolume: Float?
  private var didSetOutputMute = false
  private var didSetOutputVolume = false

  /// Stores the system's previous default input device so we can restore it after recording
  private var previousDefaultInputDevice: AudioDeviceID?

  // Cache to store already-processed device information
  private var deviceCache: [AudioDeviceID: (hasInput: Bool, name: String?)] = [:]
  private var lastDeviceCheck = Date(timeIntervalSince1970: 0)

  /// Gets all available input devices on the system
  func getAvailableInputDevices() async -> [AudioInputDevice] {
    // Reset cache if it's been more than 5 minutes since last full refresh
    let now = Date()
    if now.timeIntervalSince(lastDeviceCheck) > 300 {
      deviceCache.removeAll()
      lastDeviceCheck = now
    }

    // Get all available audio devices
    let devices = getAllAudioDevices()
    var inputDevices: [AudioInputDevice] = []

    // Filter to only input devices and convert to our model
    for device in devices {
      let hasInput: Bool
      let name: String?

      // Check cache first to avoid expensive Core Audio calls
      if let cached = deviceCache[device] {
        hasInput = cached.hasInput
        name = cached.name
      } else {
        hasInput = deviceHasInput(deviceID: device)
        name = hasInput ? getDeviceName(deviceID: device) : nil
        deviceCache[device] = (hasInput, name)
      }

      if hasInput, let deviceName = name {
        inputDevices.append(AudioInputDevice(id: String(device), name: deviceName))
      }
    }

    return inputDevices
  }

  // MARK: - Core Audio Helpers

  /// Get all available audio devices
  private func getAllAudioDevices() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    // Get the property data size
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize
    )

    if status != 0 {
      print("Error getting audio devices property size: \(status)")
      return []
    }

    // Calculate device count
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

    // Get the device IDs
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &deviceIDs
    )

    if status != 0 {
      print("Error getting audio devices: \(status)")
      return []
    }

    return deviceIDs
  }

  // MARK: - Output device helpers (mute/volume)

  /// Get the current default output device ID
  private func getDefaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      print("Error getting default output device: \(status)")
      return nil
    }
    return deviceID
  }

  /// Try to read the output mute state (master element). Returns nil if unsupported.
  private func getOutputMute(deviceID: AudioDeviceID) -> Bool? {
    var mute: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectHasProperty(deviceID, &address) else { return nil }
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mute)
    if status != 0 { return nil }
    return mute != 0
  }

  /// Try to set the output mute state. Falls back to channel 1/2 if master fails.
  private func setOutputMute(deviceID: AudioDeviceID, muted: Bool) -> Bool {
    var value: UInt32 = muted ? 1 : 0
    let size = UInt32(MemoryLayout<UInt32>.size)

    // Try master element first
    var masterAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(deviceID, &masterAddr) {
      let status = AudioObjectSetPropertyData(deviceID, &masterAddr, 0, nil, size, &value)
      if status == 0 { return true }
    }

    // Fall back to L/R channels (1 and 2)
    var success = false
    for ch in [UInt32(1), UInt32(2)] {
      var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: ch
      )
      if AudioObjectHasProperty(deviceID, &addr) {
        let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &value)
        success = success || (status == 0)
      }
    }
    return success
  }

  /// Read output volume (virtual master if available; otherwise channel 1)
  private func getOutputVolume(deviceID: AudioDeviceID) -> Float? {
    // Prefer virtual master volume
    var vol: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    var vmAddr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(deviceID, &vmAddr) {
      let status = AudioObjectGetPropertyData(deviceID, &vmAddr, 0, nil, &size, &vol)
      if status == 0 { return Float(vol) }
    }

    // Fall back to channel 1 scalar
    var ch1Addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: 1
    )
    if AudioObjectHasProperty(deviceID, &ch1Addr) {
      let status = AudioObjectGetPropertyData(deviceID, &ch1Addr, 0, nil, &size, &vol)
      if status == 0 { return Float(vol) }
    }

    return nil
  }

  /// Set output volume (virtual master if available; otherwise channel 1 and 2)
  private func setOutputVolume(deviceID: AudioDeviceID, volume: Float) -> Bool {
    var vol: Float32 = max(0, min(1, Float32(volume)))
    let size = UInt32(MemoryLayout<Float32>.size)
    var vmAddr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(deviceID, &vmAddr) {
      let status = AudioObjectSetPropertyData(deviceID, &vmAddr, 0, nil, size, &vol)
      if status == 0 { return true }
    }

    // Fall back to per-channel
    var success = false
    for ch in [UInt32(1), UInt32(2)] {
      var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: ch
      )
      if AudioObjectHasProperty(deviceID, &addr) {
        let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
        success = success || (status == 0)
      }
    }
    return success
  }

  /// Safely mute the default output, preserving previous state for restoration.
  private func muteDefaultOutputSafely() async {
    guard let outputID = getDefaultOutputDeviceID() else { return }
    outputDeviceAtStart = outputID

    // Remember existing states
    previousOutputMute = getOutputMute(deviceID: outputID)
    previousOutputVolume = getOutputVolume(deviceID: outputID)

    // Try mute first
    if setOutputMute(deviceID: outputID, muted: true) {
      didSetOutputMute = true
      didSetOutputVolume = false
      print("Muted default output for recording.")
      return
    }

    // Fallback: set volume to zero (only if it meaningfully changes)
    if let currentVol = previousOutputVolume, currentVol > 0.001 {
      if setOutputVolume(deviceID: outputID, volume: 0.0) {
        didSetOutputMute = false
        didSetOutputVolume = true
        print("Set default output volume to 0 for recording.")
      }
    }
  }

  /// Restore the default output's prior mute/volume state if we changed it.
  private func restoreDefaultOutputSafely() async {
    guard let outputID = outputDeviceAtStart else { resetOutputStateTracking(); return }

    defer { resetOutputStateTracking() }

    if didSetOutputMute {
      if let prev = previousOutputMute {
        _ = setOutputMute(deviceID: outputID, muted: prev)
        print("Restored output mute to previous state: \(prev)")
      } else {
        // If we couldn't read it before, unmute to be safe
        _ = setOutputMute(deviceID: outputID, muted: false)
        print("Restored output mute to unmuted (best effort)")
      }
    } else if didSetOutputVolume {
      if let prevVol = previousOutputVolume {
        _ = setOutputVolume(deviceID: outputID, volume: prevVol)
        print("Restored output volume to previous value: \(prevVol)")
      }
    }
  }

  private func resetOutputStateTracking() {
    outputDeviceAtStart = nil
    previousOutputMute = nil
    previousOutputVolume = nil
    didSetOutputMute = false
    didSetOutputVolume = false
  }

  /// Get device name for the given device ID
  private func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceNameCFString,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var deviceName: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let deviceNamePtr: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: MemoryLayout<CFString?>.alignment)
    defer { deviceNamePtr.deallocate() }

    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      deviceNamePtr
    )

    if status == 0 {
        deviceName = deviceNamePtr.load(as: CFString?.self)
    }

    if status != 0 {
      print("Error getting device name: \(status)")
      return nil
    }

    return deviceName as String?
  }

  /// Check if device has input capabilities
  private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )

    var propertySize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &propertySize
    )

    if status != 0 {
      return false
    }

    // Allocate raw memory based on the actual byte size needed
    let rawBufferList = UnsafeMutableRawPointer.allocate(
      byteCount: Int(propertySize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBufferList.deallocate() }
    let bufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)

    let getStatus = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      bufferList
    )

    if getStatus != 0 {
      return false
    }

    // Check if we have any input channels
    // Check if we have any input channels
    let buffersPointer = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffersPointer.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
  }

  /// Get the current default input device ID
  private func getDefaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      print("Error getting default input device: \(status)")
      return nil
    }

    return deviceID
  }

  /// Set device as the default input device
  private func setInputDevice(deviceID: AudioDeviceID) {
    var device = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &device
    )

    if status != 0 {
      print("Error setting default input device: \(status)")
    } else {
      print("Successfully set input device to: \(deviceID)")
    }
  }

  func requestMicrophoneAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  func startRecording() async {
    // Mute system output instead of pausing apps (safer; avoids VLC issues)
    if hexSettings.pauseMediaOnRecord {
      await muteDefaultOutputSafely()
    }

    // If user has selected a specific microphone, verify it exists and set it as the default input device
    if let selectedDeviceIDString = hexSettings.selectedMicrophoneID,
       let selectedDeviceID = AudioDeviceID(selectedDeviceIDString) {
      // Check if the selected device is still available
      let devices = getAllAudioDevices()
      if devices.contains(selectedDeviceID) && deviceHasInput(deviceID: selectedDeviceID) {
        let currentDefault = getDefaultInputDeviceID()
        // Only switch if different, and remember the previous default exactly once
        if currentDefault != selectedDeviceID {
          if previousDefaultInputDevice == nil, let currentDefault {
            previousDefaultInputDevice = currentDefault
          }
          print("Setting selected input device: \(selectedDeviceID)")
          setInputDevice(deviceID: selectedDeviceID)
        } else {
          print("Selected input device is already the default; no change needed.")
        }
      } else {
        // Device no longer available, fall back to system default
        print("Selected device \(selectedDeviceID) is no longer available, using system default")
      }
    } else {
      print("Using default system microphone")
    }

// Use 16-bit integer PCM for better performance while preserving transcription quality
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, // 16-bit
      AVLinearPCMIsFloatKey: false, // Signed integer PCM
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    do {
      // Create a unique temp file for this session
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hex-\(UUID().uuidString).wav")
      currentRecordingURL = url
      recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder?.isMeteringEnabled = true
      recorder?.record()
      startMeterTask()
      print("Recording started.")
    } catch {
      print("Could not start recording: \(error)")
    }
  }

  func stopRecording() async -> URL {
    recorder?.stop()
    recorder = nil
    stopMeterTask()
    print("Recording stopped.")

    // Restore system output state (mute/volume) if we changed it
    await restoreDefaultOutputSafely()

    // Restore the previous default input device if we changed it
    if let prevDevice = previousDefaultInputDevice {
      let currentDefault = getDefaultInputDeviceID()
      if currentDefault != prevDevice {
        print("Restoring previous default input device: \(prevDevice)")
        setInputDevice(deviceID: prevDevice)
      }
      previousDefaultInputDevice = nil
    }

    // Return the specific URL used for this session (fallback to a temp path)
    let url = currentRecordingURL ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("hex-missing-session.wav")
    currentRecordingURL = nil
    return url
  }

  func startMeterTask() {
    meterTask = Task {
      while !Task.isCancelled, let r = self.recorder, r.isRecording {
        r.updateMeters()
        let averagePower = r.averagePower(forChannel: 0)
        let averageNormalized = pow(10, averagePower / 20.0)
        let peakPower = r.peakPower(forChannel: 0)
        let peakNormalized = pow(10, peakPower / 20.0)
        meterContinuation.yield(Meter(averagePower: Double(averageNormalized), peakPower: Double(peakNormalized)))
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func stopMeterTask() {
    meterTask?.cancel()
    meterTask = nil
  }

  func observeAudioLevel() -> AsyncStream<Meter> {
    meterStream
  }
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}

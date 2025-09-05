# Hex App Performance Optimization Guide

Updated for WhisperKit revision 0a064c3ba8b424887ce691c2f6c85ddffde0ce89

## Executive Summary

This guide outlines Hex’s performance strategy, completed Phase 1 optimizations, and a comprehensive Phase 2 plan leveraging newly available WhisperKit capabilities. With the latest WhisperKit, we can now explicitly tune VAD, control decoding concurrency, enable hardware accelerators (Core ML, ANE, GPU) and stateful models, turn on speculative decoding, benefit from improved resampling/memory efficiency, and pilot a streaming transcription pipeline.

Highlights:
- Phase 1 delivered significant wins: 16 kHz 16‑bit PCM capture, aggressive prewarming, cleanup, and sound preloading.
- The updated WhisperKit exposes powerful levers to push Phase 2 further: VADOptions, DecodingOptions concurrency, hardware flags, stateful models, speculative decoding, memory optimizations, and streaming.

Observed Phase 1 impact (device‑dependent):
- 20–40% reduction in end‑to‑end latency for common utterances
- Elimination of 2–5s cold‑start delays via prewarming
- Lower CPU/IO during capture with 16‑bit PCM

With Phase 2, we target an additional 30–60% effective latency reduction leveraging stateful models and speculative decoding, while maintaining accuracy and stability.

## Implementation Progress (Status Update)

Phase 1 "Quick Wins" (Completed):
- Audio Format Optimization
  - 16‑bit signed integer Linear PCM @ 16 kHz mono for lower CPU/IO without impacting recognition quality.
  - Implemented in RecordingClientLive.startRecording() AVAudioRecorder settings.
- Aggressive Model Prewarming
  - Prewarm on app startup and on model changes when models are locally available; skip Parakeet to avoid unexpected network at launch.
  - Implemented via TranscriptionFeature.prewarmSelectedModel, triggered in AppFeature.
- Decoding Configuration (Simplified for then‑current API)
  - Centralized construction in TranscriptionOptimizations; used DecodingOptions() with defaults due to API limits at that time.
- Hardware Acceleration (API‑Dependent in Phase 1)
  - Unsupported flags removed; relied on WhisperKit defaults for accelerators.
- Sound Effect Preloading
  - Sounds preloaded at startup (AppFeature) to avoid first‑play stalls.
- Immediate Audio Cleanup
  - Temp recordings deleted when not needed; moved to permanent storage when configured; error paths cleaned up.

Current working state:
- Stable across supported macOS, responsive UI, no cold‑start penalties for prewarmed WhisperKit models, efficient storage behavior.

## Plan vs Implementation (Phase 1)

1) Advanced WhisperKit Controls
- Original Plan: Tune VAD, set worker counts, enable hardware flags via WhisperKitConfig/DecodingOptions.
- Actual: Used DecodingOptions() defaults; removed unsupported flags; centralized future‑proof builder.
- Why: API limitations and compilation issues in the earlier WhisperKit version.
- Path Forward: With the upgraded WhisperKit, Phase 2 reintroduces these levers.

2) Streaming Pipeline
- Original Plan: Overlap capture and decode.
- Actual: Kept reliable file‑based flow for Phase 1 stability.
- Path Forward: Implement streaming in Phase 2 behind an opt‑in flag.

3) Prewarming Scope
- Original: Prewarm selected and potentially fallback models.
- Actual: Prewarm selected model only if already on disk; skipped Parakeet at launch.
- Path Forward: Maintain conservative policy; optionally warm a fallback model when already downloaded.

4) Audio Format and I/O
- Original: Switch to 16‑bit PCM @ 16 kHz.
- Actual: Implemented as planned; strong win.

5) Temp File Lifecycle, Sound Preload
- Original: Ensure cleanup and preload.
- Actual: Implemented as designed.

## Phase 2 Optimization Plan (Leveraging Latest WhisperKit)

Goal: Further reduce latency (target +30–60% effective improvement on top of Phase 1), maintain accuracy, and keep UI responsiveness by adopting the latest WhisperKit capabilities.

Key new capabilities we will use:
1) VADOptions with configurable parameters
2) DecodingOptions with concurrentWorkerCount and concurrentChunkCount
3) WhisperKitConfig hardware acceleration flags (useCoreML, useNeuralEngine, useGPU, useStatefulModels)
4) Stateful Models for ~45% latency reduction
5) Speculative decoding for up to ~2.4x speedup
6) Memory optimizations for large files (faster resampling, lower memory)
7) Streaming transcription support

We will introduce these changes in controlled, observable steps, gated behind safe defaults and toggles.

### 2.1 Decoding Controls: VAD + Concurrency

- What:
  - Use VADOptions with tuned parameters to reduce non‑speech overhead and improve chunk boundaries.
  - Set DecodingOptions.concurrentWorkerCount based on hardware (auto; cap at 4 by default).
  - Set DecodingOptions.concurrentChunkCount to safely pipeline chunk decoding (start at 2, tune empirically).

- Recommended defaults:
  - VADOptions:
    - minSilenceDurationMs: 100
    - maxSilenceDurationMs: 2000
    - speechPadMs: 200
    - minSpeechDurationMs: 50
  - Workers: min(4, activeProcessorCount)
  - concurrentChunkCount: 2

- Implementation:
  - Update TranscriptionOptimizations to construct DecodingOptions using:
    - language/detectLanguage (from HexSettings.outputLanguage)
    - VADOptions above
    - concurrentWorkerCount, concurrentChunkCount
    - enable speculative decoding settings when combined with 2.4 (see 2.4)

- Acceptance criteria:
  - Reduced decode time vs. default options without accuracy regression.
  - UI remains responsive on Intel/low‑core devices.

### 2.2 Hardware Acceleration via WhisperKitConfig

- What:
  - Explicitly enable accelerators where supported:
    - useCoreML: true
    - useNeuralEngine: true (on ANE‑capable devices)
    - useGPU: true (when beneficial)
    - useStatefulModels: true (see 2.3)

- Implementation:
  - Update TranscriptionClientLive.loadWhisperKitModel:
    - Construct WhisperKitConfig including the above flags (guarded by API/device availability).
    - Pass recommendedConcurrentWorkers if the initializer exposes it.

- Acceptance criteria:
  - Noticeable further latency reductions on Apple Silicon with ANE/GPU.
  - No regressions on devices lacking these accelerators (flags become no‑ops).

### 2.3 Stateful Models (~45% Latency Reduction)

- What:
  - Enable stateful models in WhisperKitConfig (useStatefulModels: true).
  - Maintain a long‑lived WhisperKit instance to reuse decoder state across transcriptions.

- Implementation:
  - TranscriptionClientLive:
    - Keep single active instance per model; unload only on model switch.
    - Add a lightweight "warm tick" after load to ensure state initialization is complete.

- Acceptance criteria:
  - Median end‑to‑end latency reduced by ~45% on repeated transcriptions.
  - Memory footprint stable; no leaks during frequent model changes.

### 2.4 Speculative Decoding (~2.4x Speedup)

- What:
  - Enable speculative decoding in DecodingOptions (use the new flags added in the latest WhisperKit).
  - Configure draft tokens/parameters per WhisperKit API defaults; start with conservative settings and expand after testing.

- Implementation:
  - TranscriptionOptimizations.buildOptimizedDecodeOptions:
    - Turn on speculative decoding.
    - Keep VAD + concurrency from 2.1.
  - Add a Settings "Experimental" toggle to disable speculative decoding if needed.

- Acceptance criteria:
  - Significant decode speedup on typical utterances.
  - No unacceptable accuracy regressions; provide a quick fallback via settings.

### 2.5 Memory and Resampling Optimizations (Large Files)

- What:
  - Leverage WhisperKit’s faster resampling (3x) and 50% lower memory mode when decoding large files.
  - Use any configuration flags introduced for memory‑efficient paths.

- Implementation:
  - TranscriptionOptimizations:
    - If input duration or file size exceeds a threshold (e.g., ≥30s), enable memory‑optimized decode options where available.
  - Consider chunked decoding strategy for long recordings with progress updates.

- Acceptance criteria:
  - Large file decode times and memory usage significantly improved.
  - No OOM or UI stalls when decoding long audio.

### 2.6 Streaming Transcription (Opt‑in)

- What:
  - Use WhisperKit’s streaming capabilities to overlap capture and decoding, reducing "time to first words" and final latency.

- Implementation:
  - Add a new streaming path behind a setting:
    - RecordingStreamClient using AVAudioEngine tap → 16 kHz mono Float32 buffer stream.
    - TranscriptionPipeline actor:
      - start(model:options:)
      - push(chunk:)
      - finish() -> final text
    - UI/Feature integration:
      - TranscriptionFeature: when streaming is enabled, start pipeline on hotkey press, push chunks during recording, call finish on stop.
  - Backpressure handling to avoid memory growth; small reusable buffer pool.

- Acceptance criteria:
  - Earlier partial results and lower end‑to‑end latency vs. file‑based pipeline.
  - Stable cancellation, no leaks, minimal CPU headroom impact.

### 2.7 Observability, Tuning, and Safety Nets

- Metrics:
  - Collect prewarm time, decode time, RTF, speculative hit rates (if exposed), queue depths for streaming, and memory marks.
  - Add a small in‑app "Performance" debug overlay and optional JSON dump.

- Settings (Experimental section):
  - Enable/disable streaming, speculative decoding.
  - Override workers/chunks (auto by default).
  - VAD tuning fields with safe defaults.
  - Hardware toggles surfaced if needed; auto‑detect preferred.

- Rollback:
  - Feature flags for every Phase 2 lever.
  - A single "Use Legacy Decode Path" toggle to revert to Phase 1 behavior instantly.

## Rollout Plan

- Milestone A (Low risk)
  - Adopt VADOptions + DecodingOptions concurrency; enable hardware flags and stateful models.
  - Instrument metrics; keep speculative decoding off by default initially.
- Milestone B (Medium risk)
  - Enable speculative decoding by default on ANE‑capable devices; provide toggle.
- Milestone C (Pilot)
  - Introduce streaming path as opt‑in; collect telemetry; fix edge cases; then consider broader enablement.

## Acceptance Criteria (Phase 2 Overall)

- Latency:
  - Additional 30–60% improvement vs. Phase 1 on repeated transcriptions with stateful models and speculative decoding enabled.
- Stability:
  - No app hangs; streaming path cancels cleanly; no temp file leaks.
- Quality:
  - No material accuracy regressions; speculative decoding toggle quickly disables if needed.
- Resource Usage:
  - Memory and CPU remain within safe bounds under long/continuous usage.

## Engineering Tasks Summary

- TranscriptionOptimizations
  - Build DecodingOptions with:
    - VADOptions (minSilenceDurationMs, maxSilenceDurationMs, speechPadMs, minSpeechDurationMs)
    - concurrentWorkerCount (≤4), concurrentChunkCount (2 default)
    - speculative decoding enabled
  - Add heuristics for large files to enable memory‑optimized modes.

- TranscriptionClientLive
  - Update WhisperKitConfig to set:
    - useCoreML, useNeuralEngine, useGPU, useStatefulModels (capability‑guarded)
    - pass worker counts if supported
  - Keep a single long‑lived instance per model; prewarm and "warm tick".

- TranscriptionFeature
  - Add streaming mode path (feature‑flagged).
  - Keep file‑based path as stable fallback.
  - Display performance badge (RTF, ms); add streaming/partial indicators.

- Settings/UX
  - Experimental toggles for speculative decoding, streaming, and advanced tuning.
  - Auto defaults for most users.

- Observability
  - Collect decode metrics; optional JSON log for troubleshooting.

## Risks and Mitigations

- Speculative decoding accuracy regressions:
  - Mitigation: Default off in Milestone A; guarded by a toggle and per‑device gating.
- CPU spikes on low‑core CPUs:
  - Mitigation: Auto worker caps; allow user override; monitor RTF and thermal throttling.
- Streaming complexity:
  - Mitigation: Pilot behind a setting; apply backpressure and buffer pooling.

## Current Architecture (At a Glance)

- Phase 1 (current):
  - Hotkey → AVAudioRecorder (16‑bit PCM 16 kHz) → stop → WhisperKit transcribe with default DecodingOptions() and a prewarmed model
- Phase 2 (target):
  - Hotkey → streaming capture via AVAudioEngine → WhisperKit streaming decode with VAD + concurrency + speculative decoding, using stateful models and accelerators → final text on finish

## Conclusion

Phase 1 built a strong, stable foundation and removed major bottlenecks. The latest WhisperKit release unlocks the advanced levers we originally envisioned. Phase 2 will:
- Tune VAD and concurrency,
- Enable accelerators and stateful models,
- Turn on speculative decoding,
- Adopt memory‑efficient paths for large files,
- And pilot streaming transcription.

All changes are gated, observable, and reversible, enabling a safe rollout toward substantially lower latency and an even snappier Hex experience.

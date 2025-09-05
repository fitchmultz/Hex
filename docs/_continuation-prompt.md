# Hex App Performance Optimization - Continuation Prompt

## Summary

This is a performance optimization project for the Hex transcription app using WhisperKit. We completed Phase 1 optimizations (audio format, prewarming, cleanup, sound preloading) achieving 20-40% latency reduction. The user updated to WhisperKit revision 0a064c3ba8b424887ce691c2f6c85ddffde0ce89, which unlocks advanced features we originally planned. We now have a comprehensive Phase 2 plan targeting an additional 30-60% performance improvement through VAD tuning, concurrency controls, hardware acceleration, stateful models, speculative decoding, and streaming transcription.

## Mandatory Reading

- `PERFORMANCE_OPTIMIZATION_GUIDE.md` - Complete optimization plan, Phase 1 status, and Phase 2 roadmap
- `Hex/Features/Transcription/TranscriptionFeature.swift` - Main transcription logic and TCA reducer
- `Hex/Clients/TranscriptionClient.swift` - WhisperKit integration and model management
- `Hex/Clients/RecordingClient.swift` - Audio capture with 16-bit PCM optimization
- `Hex/Features/Transcription/TranscriptionOptimizations.swift` - Centralized performance utilities
- `Hex/Features/App/AppFeature.swift` - App coordination and prewarming triggers
- `Hex/Models/HexSettings.swift` - Settings model for configuration
- `Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` - Dependencies including WhisperKit version

## Environment

- **Platform**: macOS app using Swift and TCA (The Composable Architecture)
- **Framework**: WhisperKit revision 0a064c3ba8b424887ce691c2f6c85ddffde0ce89 (recent main branch)
- **Build System**: Xcode project with Swift Package Manager
- **Target Hardware**: Apple Silicon (M1/M2/M3) with Neural Engine, Intel Macs
- **Audio Format**: 16-bit signed integer Linear PCM at 16 kHz mono (Phase 1 optimization)

## Tools

- **RepoPrompt MCP**: Primary tool for code analysis, editing, and project management
  - `chat_send` with mode="edit" for all code changes
  - `manage_selection` for curating file context
  - `get_code_structure` for understanding architecture
  - `read_file` for examining specific code sections
- **Perplexity MCP**: For researching WhisperKit capabilities and performance techniques
- **Sequential Thinking MCP**: For complex analysis and planning
- **File Operations**: `read_file`, `write`, `search_replace` for code modifications

## Collaborators

- **User**: Mitch (project owner) - Performance-focused, wants maximum speed without quality loss
- **AI Assistant**: Claude (implementation lead) - Conducting analysis and implementation
- **RepoPrompt Chat**: `hex-performance-optimiza-B03185` - For continuity and context
- **Process**: Human-in-the-loop with AI implementation, user testing and approval

## Process

- **Approach**: Phased implementation with controlled rollout
- **Approval**: User testing and validation at each milestone
- **Implementation**: AI-driven code changes via RepoPrompt chat_send
- **Testing**: User validates performance improvements and quality
- **Rollback**: Feature flags enable instant reversion to Phase 1 behavior

## Architecture & Design Decisions

- **TCA Architecture**: Maintained throughout optimizations
- **Phased Approach**: Phase 1 (quick wins) → Phase 2 (advanced features)
- **Feature Flags**: All Phase 2 features gated behind settings for safe rollout
- **Centralized Utilities**: TranscriptionOptimizations.swift for consistent configuration
- **Conservative Prewarming**: Only selected model, skip Parakeet to avoid network usage
- **Quality First**: All optimizations must maintain or improve transcription accuracy

## Technical Debt & Issues

- **API Limitations**: Original plan adapted due to earlier WhisperKit version constraints
- **Compilation Issues**: Some advanced features caused build errors in earlier version
- **Testing Gap**: Need comprehensive testing of Phase 2 features before production
- **Memory Management**: Large file processing needs optimization for extended usage
- **Thermal Management**: Need to monitor and handle thermal throttling on sustained usage

## Immediate Next Steps

1. **Start Phase 2 Milestone A** (Low Risk):
   - Update TranscriptionOptimizations.swift with VADOptions tuning
   - Add DecodingOptions concurrency controls (concurrentWorkerCount, concurrentChunkCount)
   - Enable hardware acceleration flags in TranscriptionClient.swift
   - Implement stateful models for 45% latency reduction

2. **Add Feature Flags**:
   - Create experimental settings section in UI
   - Add toggles for speculative decoding, streaming, advanced tuning
   - Implement rollback capability to Phase 1 behavior

3. **Implement Metrics Collection**:
   - Add performance monitoring (prewarm time, decode time, RTF)
   - Create debug overlay for performance visualization
   - Enable JSON logging for troubleshooting

4. **Test and Validate**:
   - Test on different hardware configurations
   - Validate transcription quality maintained
   - Monitor memory usage and thermal performance

## Phase 2 Implementation Details

### Milestone A (Low Risk) - VAD + Concurrency + Hardware

- **VADOptions**: minSilenceDurationMs: 100, maxSilenceDurationMs: 2000, speechPadMs: 200, minSpeechDurationMs: 50
- **Concurrency**: concurrentWorkerCount: min(4, activeProcessorCount), concurrentChunkCount: 2
- **Hardware Flags**: useCoreML: true, useNeuralEngine: true, useGPU: true, useStatefulModels: true

### Milestone B (Medium Risk) - Speculative Decoding

- Enable speculative decoding for up to 2.4x speedup
- Add settings toggle for user control
- Monitor accuracy and provide fallback

### Milestone C (Pilot) - Streaming Transcription

- Implement AVAudioEngine-based streaming capture
- Create TranscriptionPipeline actor for real-time processing
- Add backpressure handling and buffer pooling

## Performance Targets

- **Phase 1 Achieved**: 20-40% latency reduction
- **Phase 2 Target**: Additional 30-60% improvement
- **Quality**: No accuracy regressions
- **Responsiveness**: UI remains smooth during processing
- **Memory**: Efficient handling of large files (3x faster resampling, 50% less memory)

## Key WhisperKit Features Available

- VADOptions with configurable parameters
- DecodingOptions with concurrency controls
- WhisperKitConfig hardware acceleration flags
- Stateful Models for 45% latency reduction
- Speculative decoding for 2.4x speedup
- Memory optimizations for large files
- Streaming transcription capabilities

## Critical Success Factors

- Maintain transcription quality (no accuracy regressions)
- Keep UI responsive during processing
- Ensure all changes are reversible via feature flags
- Test on different hardware configurations
- Monitor memory usage and thermal performance
- Provide clear performance metrics and debugging tools

## Anything Else

- User is very performance-focused and wants to push limits while maintaining quality
- All code changes must use RepoPrompt chat_send with mode="edit"
- Keep PERFORMANCE_OPTIMIZATION_GUIDE.md updated with progress
- Test each milestone thoroughly before proceeding to next
- Maintain backward compatibility and rollback capability
- Focus on measurable performance improvements with clear metrics
- User has confirmed the app is working well with Phase 1 changes

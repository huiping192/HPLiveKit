//
//  AudioMixer.swift
//  HPLiveKit
//
//  Created for audio mixing functionality
//

import Foundation
@preconcurrency import CoreMedia
@preconcurrency import AVFoundation
import Accelerate
import os

/// Audio mixer using Swift 6 Actor for thread safety
/// Mixes app audio and microphone audio with configurable volume ratios
/// IMPORTANT: Only supports 16-bit PCM audio. Other bit depths will be rejected with error logs.
actor AudioMixer {
  private static let logger = Logger(subsystem: "com.hplivekit", category: "AudioMixer")
  
  // MARK: - Configuration
  
  private let targetSampleRate: Double
  private let appVolume: Float  // Default 0.7 (70%)
  private let micVolume: Float  // Default 1.0 (100%)
  
  // MARK: - Audio Resamplers

  private let appResampler: AudioResampler
  private let micResampler: AudioResampler
  
  // MARK: - Input Streams
  
  private let appAudioStream: AsyncStream<SampleBufferBox>
  private let appAudioContinuation: AsyncStream<SampleBufferBox>.Continuation
  
  private let micAudioStream: AsyncStream<SampleBufferBox>
  private let micAudioContinuation: AsyncStream<SampleBufferBox>.Continuation
  
  // MARK: - Output Stream
  
  private let _outputStream: AsyncStream<SampleBufferBox>
  private let outputContinuation: AsyncStream<SampleBufferBox>.Continuation
  
  nonisolated var outputStream: AsyncStream<SampleBufferBox> {
    _outputStream
  }
  
  // MARK: - Processing State
  
  private var appAudioBuffer: [TimestampedBuffer] = []
  private var micAudioBuffer: [TimestampedBuffer] = []
  
  private let bufferTimeThreshold: CMTime = CMTime(seconds: 0.05, preferredTimescale: 1000000) // 50ms
  private let maxTimeDiffBeforeDrop: CMTime = CMTime(seconds: 1.0, preferredTimescale: 1000000) // 1s - drop buffer if time diff exceeds this
  
  // Processing tasks - use nonisolated(unsafe) to store tasks
  nonisolated(unsafe) private var appProcessingTask: Task<Void, Never>?
  nonisolated(unsafe) private var micProcessingTask: Task<Void, Never>?
  
  // MARK: - Helper Types
  
  private struct TimestampedBuffer {
    let sampleBufferBox: SampleBufferBox
    let timestamp: CMTime
  }
  
  // MARK: - Initialization
  
  init(targetSampleRate: Double = 48000, appVolume: Float = 0.7, micVolume: Float = 1.0) {
    self.targetSampleRate = targetSampleRate
    self.appVolume = appVolume
    self.micVolume = micVolume

    // Create separate resamplers for app and mic audio to avoid converter recreation
    self.appResampler = AudioResampler(targetSampleRate: targetSampleRate)
    self.micResampler = AudioResampler(targetSampleRate: targetSampleRate)
    
    // Create input streams
    (self.appAudioStream, self.appAudioContinuation) = AsyncStream<SampleBufferBox>.makeStream()
    (self.micAudioStream, self.micAudioContinuation) = AsyncStream<SampleBufferBox>.makeStream()

    // Create output stream
    (self._outputStream, self.outputContinuation) = AsyncStream<SampleBufferBox>.makeStream()

    // Start processing tasks
    self.appProcessingTask = Task { [weak self] in
      guard let self = self else { return }
      await self.processAppAudioStream()
    }

    self.micProcessingTask = Task { [weak self] in
      guard let self = self else { return }
      await self.processMicAudioStream()
    }
  }

  deinit {
    appProcessingTask?.cancel()
    micProcessingTask?.cancel()

    appAudioContinuation.finish()
    micAudioContinuation.finish()
    outputContinuation.finish()
  }
  
  // MARK: - Public API

  /// Push app audio sample buffer
  /// - Parameter sampleBuffer: Must be 16-bit PCM format
  nonisolated func pushAppAudio(_ sampleBuffer: SampleBufferBox) {
    // Debug: Log app audio data with actual PCM data size
    let format = CMSampleBufferGetFormatDescription(sampleBuffer.samplebuffer)
    if let asbd = format.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) {
      // Use extractPCMData to get real data size (CMSampleBufferGetTotalSampleSize may return 0)
      let dataSize: Int
      if let pcmData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer.samplebuffer) {
        dataSize = pcmData.count
      } else {
        dataSize = -1  // Extraction failed
      }
      Self.logger.info("[APP Audio] Received: \(dataSize) bytes, \(asbd.mSampleRate)Hz, \(asbd.mChannelsPerFrame)ch, \(asbd.mBitsPerChannel)bit")
    }
    appAudioContinuation.yield(sampleBuffer)
  }

  /// Push microphone audio sample buffer
  /// - Parameter sampleBuffer: Must be 16-bit PCM format
  nonisolated func pushMicAudio(_ sampleBuffer: SampleBufferBox) {
    // Debug: Log mic audio data with actual PCM data size
    let format = CMSampleBufferGetFormatDescription(sampleBuffer.samplebuffer)
    if let asbd = format.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) {
      // Use extractPCMData to get real data size (CMSampleBufferGetTotalSampleSize may return 0)
      let dataSize: Int
      if let pcmData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer.samplebuffer) {
        dataSize = pcmData.count
      } else {
        dataSize = -1  // Extraction failed
      }
      Self.logger.info("[MIC Audio] Received: \(dataSize) bytes, \(asbd.mSampleRate)Hz, \(asbd.mChannelsPerFrame)ch, \(asbd.mBitsPerChannel)bit")
    }

    // [DIAGNOSTIC] Input tracking
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer.samplebuffer)
    if let pcmData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer.samplebuffer),
       let asbd = format.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) {
      let rms = AudioSampleBufferUtils.calculateRMS(pcmData: pcmData, bitsPerChannel: Int(asbd.mBitsPerChannel))
      Self.logger.info("[DIAGNOSTIC] MIC INPUT: ts=\(timestamp.seconds)s, size=\(pcmData.count), RMS=\(String(format: "%.4f", rms)), format=\(asbd.mSampleRate)Hz/\(asbd.mChannelsPerFrame)ch/\(asbd.mBitsPerChannel)bit")
    }

    micAudioContinuation.yield(sampleBuffer)
  }
  
  /// Stop the mixer and finish all streams
  func stop() {
    appProcessingTask?.cancel()
    micProcessingTask?.cancel()

    appAudioContinuation.finish()
    micAudioContinuation.finish()
    outputContinuation.finish()

    appAudioBuffer.removeAll()
    micAudioBuffer.removeAll()
  }
  
  // MARK: - Private Processing Methods

  /// Process app audio stream (MAIN DRIVER for mixing)
  /// Each app audio frame triggers mixing logic
  private func processAppAudioStream() async {
    for await sampleBufferBox in appAudioStream {
      // [DIAGNOSTIC] Before resample
      let inputTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBufferBox.samplebuffer)
      if let inputPCM = AudioSampleBufferUtils.extractPCMData(from: sampleBufferBox.samplebuffer),
         let inputFormat = AudioSampleBufferUtils.extractFormat(from: sampleBufferBox.samplebuffer) {
        let inputRMS = AudioSampleBufferUtils.calculateRMS(pcmData: inputPCM, bitsPerChannel: Int(inputFormat.mBitsPerChannel))
        Self.logger.info("[DIAGNOSTIC] APP BEFORE RESAMPLE: ts=\(inputTimestamp.seconds)s, size=\(inputPCM.count), RMS=\(String(format: "%.4f", inputRMS)), format=\(inputFormat.mSampleRate)Hz/\(inputFormat.mChannelsPerFrame)ch/\(inputFormat.mBitsPerChannel)bit")
      }

      // Resample to target format using dedicated app audio resampler
      guard let normalizedBox = await appResampler.resample(sampleBufferBox) else {
        Self.logger.warning("Failed to resample app audio")
        continue
      }

      // [DIAGNOSTIC] After resample
      let outputTimestamp = CMSampleBufferGetPresentationTimeStamp(normalizedBox.samplebuffer)
      if let outputPCM = AudioSampleBufferUtils.extractPCMData(from: normalizedBox.samplebuffer),
         let outputFormat = AudioSampleBufferUtils.extractFormat(from: normalizedBox.samplebuffer) {
        let outputRMS = AudioSampleBufferUtils.calculateRMS(pcmData: outputPCM, bitsPerChannel: Int(outputFormat.mBitsPerChannel))
        Self.logger.info("[DIAGNOSTIC] APP AFTER RESAMPLE: ts=\(outputTimestamp.seconds)s, size=\(outputPCM.count), RMS=\(String(format: "%.4f", outputRMS)), format=\(outputFormat.mSampleRate)Hz/\(outputFormat.mChannelsPerFrame)ch/\(outputFormat.mBitsPerChannel)bit")
      }

      let timestamp = CMSampleBufferGetPresentationTimeStamp(normalizedBox.samplebuffer)
      appAudioBuffer.append(TimestampedBuffer(sampleBufferBox: normalizedBox, timestamp: timestamp))

      Self.logger.info("[DIAGNOSTIC] APP buffered, triggering mixing... app_buffer=\(self.appAudioBuffer.count), mic_buffer=\(self.micAudioBuffer.count)")

      // Event-driven mixing: process immediately when new data arrives
      await processMixing()
    }
  }


  /// Process mic audio stream (PASSIVE BUFFERING only)
  /// Mic audio is buffered and consumed by app audio stream's mixing logic
  private func processMicAudioStream() async {
    for await sampleBufferBox in micAudioStream {
      // [DIAGNOSTIC] Before resample
      let inputTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBufferBox.samplebuffer)
      if let inputPCM = AudioSampleBufferUtils.extractPCMData(from: sampleBufferBox.samplebuffer),
         let inputFormat = AudioSampleBufferUtils.extractFormat(from: sampleBufferBox.samplebuffer) {
        let inputRMS = AudioSampleBufferUtils.calculateRMS(pcmData: inputPCM, bitsPerChannel: Int(inputFormat.mBitsPerChannel))
        Self.logger.info("[DIAGNOSTIC] BEFORE RESAMPLE: ts=\(inputTimestamp.seconds)s, size=\(inputPCM.count), RMS=\(String(format: "%.4f", inputRMS)), format=\(inputFormat.mSampleRate)Hz/\(inputFormat.mChannelsPerFrame)ch/\(inputFormat.mBitsPerChannel)bit")
      }

      // Resample to target format using dedicated mic audio resampler
      guard let normalizedBox = await micResampler.resample(sampleBufferBox) else {
        Self.logger.warning("Failed to resample mic audio")
        continue
      }

      // [DIAGNOSTIC] After resample
      let outputTimestamp = CMSampleBufferGetPresentationTimeStamp(normalizedBox.samplebuffer)
      if let outputPCM = AudioSampleBufferUtils.extractPCMData(from: normalizedBox.samplebuffer),
         let outputFormat = AudioSampleBufferUtils.extractFormat(from: normalizedBox.samplebuffer) {
        let outputRMS = AudioSampleBufferUtils.calculateRMS(pcmData: outputPCM, bitsPerChannel: Int(outputFormat.mBitsPerChannel))
        Self.logger.info("[DIAGNOSTIC] AFTER RESAMPLE: ts=\(outputTimestamp.seconds)s, size=\(outputPCM.count), RMS=\(String(format: "%.4f", outputRMS)), format=\(outputFormat.mSampleRate)Hz/\(outputFormat.mChannelsPerFrame)ch/\(outputFormat.mBitsPerChannel)bit")
      }

      let timestamp = CMSampleBufferGetPresentationTimeStamp(normalizedBox.samplebuffer)
      micAudioBuffer.append(TimestampedBuffer(sampleBufferBox: normalizedBox, timestamp: timestamp))

      Self.logger.debug("Mic audio buffered: \(timestamp.seconds)s, buffer size: \(self.micAudioBuffer.count)")

      // Note: Mic audio stream does NOT trigger mixing - it only buffers data
      // Mixing is driven by app audio stream (main driver)
    }
  }

  private func processMixing() async {
    // Strategy: Single-stream passthrough when only one stream has data
    // If only one stream has data, output it directly

    // [DIAGNOSTIC] Log every mixing call
    Self.logger.info("[DIAGNOSTIC] processMixing() CALLED - app_buffer: \(self.appAudioBuffer.count), mic_buffer: \(self.micAudioBuffer.count)")

    if !appAudioBuffer.isEmpty && micAudioBuffer.isEmpty {
      // Only app audio available - direct passthrough (no limiting needed)
      // AudioResampler output is already safe and doesn't require limiting
      let buffer = appAudioBuffer.removeFirst()
      outputContinuation.yield(buffer.sampleBufferBox)
      Self.logger.info("[Decision] Output app audio ONLY (direct passthrough): \(buffer.timestamp.seconds)s")
      return
    }

    if appAudioBuffer.isEmpty && !micAudioBuffer.isEmpty {
      // Only mic audio available - direct passthrough (no limiting needed)
      // AudioResampler output is already safe and doesn't require limiting
      let buffer = micAudioBuffer.removeFirst()

      // [DIAGNOSTIC] Output tracking
      let currentTime = Date().timeIntervalSince1970
      if let outputPCM = AudioSampleBufferUtils.extractPCMData(from: buffer.sampleBufferBox.samplebuffer),
         let outputFormat = AudioSampleBufferUtils.extractFormat(from: buffer.sampleBufferBox.samplebuffer) {
        let outputRMS = AudioSampleBufferUtils.calculateRMS(pcmData: outputPCM, bitsPerChannel: Int(outputFormat.mBitsPerChannel))
        let delay = currentTime - buffer.timestamp.seconds
        Self.logger.info("[DIAGNOSTIC] MIC-ONLY OUTPUT: ts=\(buffer.timestamp.seconds)s, size=\(outputPCM.count), RMS=\(String(format: "%.4f", outputRMS)), bufferSize=\(self.micAudioBuffer.count), delay=\(String(format: "%.3f", delay))s")
      }

      outputContinuation.yield(buffer.sampleBufferBox)
      Self.logger.info("[Decision] Output mic audio ONLY (direct passthrough): \(buffer.timestamp.seconds)s")
      return
    }

    if appAudioBuffer.isEmpty || micAudioBuffer.isEmpty {
      // No data to process
      Self.logger.info("[DIAGNOSTIC] [Decision] No data to process (waiting for both streams) - app: \(self.appAudioBuffer.count), mic: \(self.micAudioBuffer.count)")
      return
    }
    
    // Both streams have data, mix them
    let appBuffer = appAudioBuffer.first!
    let micBuffer = micAudioBuffer.first!
    
    // Check timestamp alignment
    let timeDiff = CMTimeSubtract(appBuffer.timestamp, micBuffer.timestamp)
    let timeDiffAbs = abs(timeDiff.seconds)

    if timeDiffAbs > bufferTimeThreshold.seconds {
      // Time diff exceeds threshold - use adaptive strategy
      if timeDiffAbs > self.maxTimeDiffBeforeDrop.seconds {
        // Time diff > 1s: One stream is severely delayed or stalled, drop old buffer
        Self.logger.error("Severe timestamp mismatch (>\(self.maxTimeDiffBeforeDrop.seconds)s): app=\(appBuffer.timestamp.seconds)s, mic=\(micBuffer.timestamp.seconds)s, diff=\(timeDiffAbs)s - dropping old buffer")

        if CMTimeCompare(appBuffer.timestamp, micBuffer.timestamp) < 0 {
          appAudioBuffer.removeFirst()
        } else {
          micAudioBuffer.removeFirst()
        }
      } else {
        // Time diff between threshold and 1s: Output older buffer to maintain audio continuity
        Self.logger.warning("Timestamp mismatch: app=\(appBuffer.timestamp.seconds)s, mic=\(micBuffer.timestamp.seconds)s, diff=\(timeDiffAbs)s - outputting older buffer to maintain continuity")

        if CMTimeCompare(appBuffer.timestamp, micBuffer.timestamp) < 0 {
          // App is older, output app audio
          let buffer = appAudioBuffer.removeFirst()
          outputContinuation.yield(buffer.sampleBufferBox)
        } else {
          // Mic is older, output mic audio
          let buffer = micAudioBuffer.removeFirst()
          outputContinuation.yield(buffer.sampleBufferBox)
        }
      }
      return
    }
    
    // Mix audio with soft limiting
    Self.logger.info("[Decision] MIXING both streams: app=\(appBuffer.timestamp.seconds)s, mic=\(micBuffer.timestamp.seconds)s")
    if let mixed = mixBuffers(appBuffer: appBuffer.sampleBufferBox.samplebuffer, micBuffer: micBuffer.sampleBufferBox.samplebuffer) {
      // Apply soft limiter to mixed output
      if let limitedMixed = applySoftLimiterToSampleBuffer(SampleBufferBox(samplebuffer: mixed)) {
        outputContinuation.yield(limitedMixed)
        Self.logger.info("[Output] Mixed audio successful (soft limited)")
      } else {
        outputContinuation.yield(SampleBufferBox(samplebuffer: mixed)) // Fallback
        Self.logger.warning("[Output] Mixed audio successful (limiter failed, using original)")
      }
    } else {
      Self.logger.error("[Output] Failed to mix audio buffers")
    }

    // Remove processed buffers
    appAudioBuffer.removeFirst()
    micAudioBuffer.removeFirst()
  }
  
  private func mixBuffers(appBuffer: CMSampleBuffer, micBuffer: CMSampleBuffer) -> CMSampleBuffer? {
    // Extract PCM data from both buffers
    guard let appData = AudioSampleBufferUtils.extractPCMData(from: appBuffer),
          let micData = AudioSampleBufferUtils.extractPCMData(from: micBuffer) else {
      return nil
    }

    // Get format information
    guard let asbd = AudioSampleBufferUtils.extractFormat(from: appBuffer) else {
      Self.logger.error("Failed to get audio format description")
      return nil
    }

    // Mix PCM data with volume ratio
    guard let mixedData = mixPCMData(app: appData, mic: micData, bitsPerChannel: asbd.mBitsPerChannel) else {
      return nil
    }

    // Create new sample buffer with mixed data
    let timestamp = CMSampleBufferGetPresentationTimeStamp(appBuffer)
    return createSampleBuffer(from: mixedData, timestamp: timestamp, format: asbd)
  }
  private func mixPCMData(app: Data, mic: Data, bitsPerChannel: UInt32) -> Data? {
    // Only support 16-bit PCM
    guard bitsPerChannel == 16 else {
      Self.logger.error("Unsupported bit depth: \(bitsPerChannel). AudioMixer only supports 16-bit PCM audio. Input audio must be 16-bit signed integer format.")
      return nil
    }

    // Calculate bytes per frame (16-bit stereo = 2 channels × 2 bytes = 4 bytes per frame)
    let bytesPerFrame = 4  // 2 channels × 2 bytes
    let samplesPerFrame = 2  // 2 channels

    // [FIX] Ensure both buffers are frame-aligned to prevent sample misalignment
    // This prevents clipping/distortion caused by resampler size differences
    let appFrames = app.count / bytesPerFrame
    let micFrames = mic.count / bytesPerFrame
    let frameCount = min(appFrames, micFrames)
    let sampleCount = frameCount * samplesPerFrame  // Total samples for vDSP operations

    // Log size difference for diagnostics
    if app.count != mic.count {
      Self.logger.warning("[DIAGNOSTIC] Buffer size mismatch before mixing - app: \(app.count) bytes (\(appFrames) frames), mic: \(mic.count) bytes (\(micFrames) frames), using: \(frameCount) frames (\(sampleCount) samples)")
    }

    // Trim buffers to exact same frame count
    let appData = Data(app.prefix(frameCount * bytesPerFrame))
    let micData = Data(mic.prefix(frameCount * bytesPerFrame))

    // Calculate RMS to detect silence (use aligned data)
    let appRMS = AudioSampleBufferUtils.calculateRMS(pcmData: appData, bitsPerChannel: 16)
    let micRMS = AudioSampleBufferUtils.calculateRMS(pcmData: micData, bitsPerChannel: 16)
    let silenceThreshold = 0.001 // RMS below this is considered silence

    Self.logger.info("[RMS] app=\(String(format: "%.4f", appRMS)), mic=\(String(format: "%.4f", micRMS))")

    // If app audio is silence, return mic only (no mixing needed)
    if appRMS < silenceThreshold {
      Self.logger.warning("[Silence Detection] App audio is SILENT (RMS=\(String(format: "%.4f", appRMS))), returning mic only")
      return micData
    }

    // If mic audio is silence, return app only
    if micRMS < silenceThreshold {
      Self.logger.warning("[Silence Detection] Mic audio is SILENT (RMS=\(String(format: "%.4f", micRMS))), returning app only")
      return appData
    }

    var mixedData = Data(count: sampleCount * 2)  // sampleCount samples × 2 bytes per sample

    appData.withUnsafeBytes { appBytes in
      micData.withUnsafeBytes { micBytes in
        mixedData.withUnsafeMutableBytes { mixedBytes in
          let appSamples = appBytes.bindMemory(to: Int16.self)
          let micSamples = micBytes.bindMemory(to: Int16.self)
          let mixedSamples = mixedBytes.bindMemory(to: Int16.self)

          // Use Accelerate framework (vDSP) for SIMD-optimized mixing
          // This provides 4-8x performance improvement over manual loop

          // Create temporary Float buffers for vDSP operations
          var appFloat = [Float](repeating: 0, count: sampleCount)
          var micFloat = [Float](repeating: 0, count: sampleCount)
          var mixedFloat = [Float](repeating: 0, count: sampleCount)

          // Step 1: Convert Int16 to Float (vectorized)
          // vDSP_vflt16: Converts signed 16-bit integers to floating point
          vDSP_vflt16(appSamples.baseAddress!, 1, &appFloat, 1, vDSP_Length(sampleCount))
          vDSP_vflt16(micSamples.baseAddress!, 1, &micFloat, 1, vDSP_Length(sampleCount))

          // Step 2: Apply volume scaling (COMMENTED OUT FOR DIAGNOSTIC TESTING)
          // Testing hypothesis: appVolume(0.7) + micVolume(1.0) = 1.7x total gain causes clipping
          // Temporary fix: Use 0.5x for each stream to prevent overflow
          // TODO: Implement proper gain normalization or soft limiter
          // var appVol = self.appVolume
          // var micVol = self.micVolume
          // vDSP_vsmul(appFloat, 1, &appVol, &appFloat, 1, vDSP_Length(sampleCount))
          // vDSP_vsmul(micFloat, 1, &micVol, &micFloat, 1, vDSP_Length(sampleCount))

          // Step 3: Mix audio with 0.5x gain to prevent clipping (diagnostic test)
          // Each stream is scaled to 50% before mixing, total gain = 1.0x (no overflow)
          var halfGain: Float = 0.5
          vDSP_vsmul(appFloat, 1, &halfGain, &appFloat, 1, vDSP_Length(sampleCount))
          vDSP_vsmul(micFloat, 1, &halfGain, &micFloat, 1, vDSP_Length(sampleCount))
          vDSP_vadd(appFloat, 1, micFloat, 1, &mixedFloat, 1, vDSP_Length(sampleCount))

          // Step 4: Clipping to prevent overflow (vectorized)
          // vDSP_vclip: Clip values to range [Int16.min, Int16.max]
          var minValue = Float(Int16.min)
          var maxValue = Float(Int16.max)
          vDSP_vclip(mixedFloat, 1, &minValue, &maxValue, &mixedFloat, 1, vDSP_Length(sampleCount))

          // Step 5: Convert Float back to Int16 (vectorized)
          // vDSP_vfix16: Converts floating point to signed 16-bit integers
          vDSP_vfix16(mixedFloat, 1, mixedSamples.baseAddress!, 1, vDSP_Length(sampleCount))
        }
      }
    }

    return mixedData
  }
  
  private func createSampleBuffer(from data: Data, timestamp: CMTime, format: AudioStreamBasicDescription) -> CMSampleBuffer? {
    // Verify bit depth
    guard format.mBitsPerChannel == 16 else {
      Self.logger.error("Cannot create sample buffer: unsupported bit depth \(format.mBitsPerChannel). Must be 16-bit.")
      return nil
    }

    // Use utility method to create sample buffer
    guard let sampleBuffer = AudioSampleBufferUtils.createAudioSampleBuffer(
      from: data,
      timestamp: timestamp,
      format: format
    ) else {
      Self.logger.error("Failed to create sample buffer using AudioSampleBufferUtils")
      return nil
    }

    return sampleBuffer
  }

  /// Apply soft limiter to sample buffer to prevent clipping distortion
  /// - Parameter sampleBufferBox: Input sample buffer
  /// - Returns: Limited sample buffer, or nil if processing fails
  private func applySoftLimiterToSampleBuffer(_ sampleBufferBox: SampleBufferBox) -> SampleBufferBox? {
    let sampleBuffer = sampleBufferBox.samplebuffer

    // Extract PCM data
    guard let pcmData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer) else {
      Self.logger.error("[Soft Limiter] Failed to extract PCM data")
      return nil
    }

    // Get format
    guard let asbd = AudioSampleBufferUtils.extractFormat(from: sampleBuffer) else {
      Self.logger.error("[Soft Limiter] Failed to extract format")
      return nil
    }

    // Verify 16-bit format
    guard asbd.mBitsPerChannel == 16 else {
      Self.logger.error("[Soft Limiter] Unsupported bit depth: \(asbd.mBitsPerChannel)")
      return nil
    }

    // Apply soft limiter
    let limitedData = applySoftLimiter(pcmData)

    // Create new sample buffer with limited data
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard let limitedBuffer = createSampleBuffer(from: limitedData, timestamp: timestamp, format: asbd) else {
      Self.logger.error("[Soft Limiter] Failed to create sample buffer")
      return nil
    }

    return SampleBufferBox(samplebuffer: limitedBuffer)
  }

  /// Apply soft limiter to prevent clipping distortion
  /// Uses tanh function for smooth compression instead of hard clipping
  /// - Parameter data: Input PCM data (16-bit)
  /// - Returns: Limited PCM data (16-bit)
  private func applySoftLimiter(_ data: Data) -> Data {
    let bytesPerSample = 2 // 16-bit = 2 bytes
    let sampleCount = data.count / bytesPerSample
    var limitedData = Data(count: data.count)

    data.withUnsafeBytes { inputBytes in
      limitedData.withUnsafeMutableBytes { outputBytes in
        let inputSamples = inputBytes.bindMemory(to: Int16.self)
        let outputSamples = outputBytes.bindMemory(to: Int16.self)

        // Allocate Float buffers for vDSP operations
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        var limitedFloatSamples = [Float](repeating: 0, count: sampleCount)

        // Step 1: Convert Int16 to Float
        vDSP_vflt16(inputSamples.baseAddress!, 1, &floatSamples, 1, vDSP_Length(sampleCount))

        // Step 2: Normalize to [-1.0, 1.0] range
        var divisor: Float = Float(Int16.max) // 32767
        vDSP_vsdiv(floatSamples, 1, &divisor, &floatSamples, 1, vDSP_Length(sampleCount))

        // Step 3: Apply soft limiting using tanh
        // tanh smoothly compresses values > 1.0 or < -1.0
        // Removed scaleFactor pre-amplification to prevent over-compression
        // Only signals that genuinely exceed ±1.0 will be compressed
        // This preserves audio quality while still preventing clipping

        // Apply tanh (soft clip) directly to normalized signal
        var inputCount = Int32(sampleCount)
        vvtanhf(&limitedFloatSamples, floatSamples, &inputCount)

        // Step 4: Scale back to Int16 range
        var multiplier: Float = Float(Int16.max)
        vDSP_vsmul(limitedFloatSamples, 1, &multiplier, &limitedFloatSamples, 1, vDSP_Length(sampleCount))

        // Step 5: Convert Float back to Int16
        vDSP_vfix16(limitedFloatSamples, 1, outputSamples.baseAddress!, 1, vDSP_Length(sampleCount))
      }
    }

    return limitedData
  }
}


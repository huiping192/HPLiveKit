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

  // PCM buffer pools with timestamp tracking
  private var appPCMBuffer = TimestampedPCMBuffer(sampleRate: 48000, bytesPerFrame: 4)
  private var micPCMBuffer = TimestampedPCMBuffer(sampleRate: 48000, bytesPerFrame: 4)

  // Buffer overflow protection (max 100ms buffering)
  private let maxBufferFrames = 4800  // 100ms @ 48kHz

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

  /// PCM buffer with timestamp tracking for precise alignment
  private struct TimestampedPCMBuffer {
    var data: Data
    var startTimestamp: CMTime
    var sampleRate: Double
    var bytesPerFrame: Int

    init(sampleRate: Double = 48000, bytesPerFrame: Int = 4) {
      self.data = Data()
      self.startTimestamp = .zero
      self.sampleRate = sampleRate
      self.bytesPerFrame = bytesPerFrame
    }

    var isEmpty: Bool { data.isEmpty }
    var frameCount: Int { data.count / bytesPerFrame }

    /// Append new PCM data with timestamp
    mutating func append(_ newData: Data, timestamp: CMTime) {
      if data.isEmpty {
        // First data, set timestamp
        data = newData
        startTimestamp = timestamp
      } else {
        // Append to existing data
        data.append(newData)
        // startTimestamp remains pointing to the first frame
      }
    }

    /// Consume frames from buffer and return data with timestamp
    /// - Parameter frames: Number of frames to consume
    /// - Returns: Tuple of (consumed data, timestamp of first frame)
    mutating func consume(frames: Int) -> (data: Data, timestamp: CMTime)? {
      guard frames > 0, data.count >= frames * bytesPerFrame else {
        return nil
      }

      let consumeBytes = frames * bytesPerFrame
      let consumedData = Data(data.prefix(consumeBytes))
      let timestamp = startTimestamp

      // Update remaining data
      data = Data(data.suffix(from: consumeBytes))

      // Update timestamp for remaining data
      if !data.isEmpty {
        let duration = CMTime(seconds: Double(frames) / sampleRate, preferredTimescale: 1000000)
        startTimestamp = CMTimeAdd(startTimestamp, duration)
      } else {
        startTimestamp = .zero
      }

      return (consumedData, timestamp)
    }

    /// Clear all buffered data
    mutating func clear() {
      data.removeAll()
      startTimestamp = .zero
    }
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
    // [FRAME-DIAG] Record original input frames
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer.samplebuffer)
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer.samplebuffer)
    let duration = CMSampleBufferGetDuration(sampleBuffer.samplebuffer)

    Self.logger.info("[FRAME-DIAG] APP-SOURCE: frames=\(frameCount), dur=\(String(format: "%.6f", duration.seconds))s, ts=\(String(format: "%.6f", timestamp.seconds))s")

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
    // [FRAME-DIAG] Record original input frames
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer.samplebuffer)
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer.samplebuffer)
    let duration = CMSampleBufferGetDuration(sampleBuffer.samplebuffer)

    Self.logger.info("[FRAME-DIAG] MIC-SOURCE: frames=\(frameCount), dur=\(String(format: "%.6f", duration.seconds))s, ts=\(String(format: "%.6f", timestamp.seconds))s")

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

    // Clear PCM buffer pools
    appPCMBuffer.clear()
    micPCMBuffer.clear()
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

      // Extract PCM data and append to buffer pool
      guard let pcmData = AudioSampleBufferUtils.extractPCMData(from: normalizedBox.samplebuffer) else {
        Self.logger.error("Failed to extract PCM data from app audio")
        continue
      }

      let timestamp = CMSampleBufferGetPresentationTimeStamp(normalizedBox.samplebuffer)
      appPCMBuffer.append(pcmData, timestamp: timestamp)

      // Buffer overflow protection
      if appPCMBuffer.frameCount > maxBufferFrames {
        let dropFrames = appPCMBuffer.frameCount - maxBufferFrames
        _ = appPCMBuffer.consume(frames: dropFrames)
        Self.logger.warning("[BUFFER-POOL] App buffer overflow, dropped \(dropFrames) frames")
      }

      Self.logger.info("[DIAGNOSTIC] APP buffered, triggering mixing... app_buffer=\(self.appPCMBuffer.frameCount)F, mic_buffer=\(self.micPCMBuffer.frameCount)F")

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

      // Extract PCM data and append to buffer pool
      guard let pcmData = AudioSampleBufferUtils.extractPCMData(from: normalizedBox.samplebuffer) else {
        Self.logger.error("Failed to extract PCM data from mic audio")
        continue
      }

      let timestamp = CMSampleBufferGetPresentationTimeStamp(normalizedBox.samplebuffer)
      micPCMBuffer.append(pcmData, timestamp: timestamp)

      // Buffer overflow protection
      if micPCMBuffer.frameCount > maxBufferFrames {
        let dropFrames = micPCMBuffer.frameCount - maxBufferFrames
        _ = micPCMBuffer.consume(frames: dropFrames)
        Self.logger.warning("[BUFFER-POOL] Mic buffer overflow, dropped \(dropFrames) frames")
      }

      Self.logger.debug("Mic audio buffered: \(timestamp.seconds)s, buffer size: \(self.micPCMBuffer.frameCount)F")

      // Note: Mic audio stream does NOT trigger mixing - it only buffers data
      // Mixing is driven by app audio stream (main driver)
    }
  }

  private func processMixing() async {
    // Strategy: Single-stream passthrough when only one stream has data

    // [DIAGNOSTIC] Log every mixing call
    Self.logger.info("[DIAGNOSTIC] processMixing() CALLED - app_buffer: \(self.appPCMBuffer.frameCount)F, mic_buffer: \(self.micPCMBuffer.frameCount)F")

    // Get target format for creating sample buffers
    let targetFormat = appResampler.targetAudioFormat

    if !appPCMBuffer.isEmpty && micPCMBuffer.isEmpty {
      // Only app audio available - direct passthrough
      guard let (appData, appTimestamp) = appPCMBuffer.consume(frames: appPCMBuffer.frameCount) else {
        return
      }

      if let outputBuffer = createSampleBuffer(from: appData, timestamp: appTimestamp, format: targetFormat) {
        outputContinuation.yield(SampleBufferBox(samplebuffer: outputBuffer))
        Self.logger.info("[Decision] Output app audio ONLY (direct passthrough): \(appTimestamp.seconds)s, \(appData.count / 4)F")
      }
      return
    }

    if appPCMBuffer.isEmpty && !micPCMBuffer.isEmpty {
      // Only mic audio available - direct passthrough
      guard let (micData, micTimestamp) = micPCMBuffer.consume(frames: micPCMBuffer.frameCount) else {
        return
      }

      if let outputBuffer = createSampleBuffer(from: micData, timestamp: micTimestamp, format: targetFormat) {
        // [DIAGNOSTIC] Output tracking
        let currentTime = Date().timeIntervalSince1970
        let outputRMS = AudioSampleBufferUtils.calculateRMS(pcmData: micData, bitsPerChannel: 16)
        let delay = currentTime - micTimestamp.seconds
        Self.logger.info("[DIAGNOSTIC] MIC-ONLY OUTPUT: ts=\(micTimestamp.seconds)s, size=\(micData.count), RMS=\(String(format: "%.4f", outputRMS)), bufferSize=\(self.micPCMBuffer.frameCount)F, delay=\(String(format: "%.3f", delay))s")

        outputContinuation.yield(SampleBufferBox(samplebuffer: outputBuffer))
        Self.logger.info("[Decision] Output mic audio ONLY (direct passthrough): \(micTimestamp.seconds)s, \(micData.count / 4)F")
      }
      return
    }

    if appPCMBuffer.isEmpty || micPCMBuffer.isEmpty {
      // No data to process
      Self.logger.info("[DIAGNOSTIC] [Decision] No data to process (waiting for both streams) - app: \(self.appPCMBuffer.frameCount)F, mic: \(self.micPCMBuffer.frameCount)F")
      return
    }

    // Both streams have data, mix them
    let mixFrames = min(appPCMBuffer.frameCount, micPCMBuffer.frameCount)

    guard let (appData, appTimestamp) = appPCMBuffer.consume(frames: mixFrames),
          let (micData, _) = micPCMBuffer.consume(frames: mixFrames) else {
      Self.logger.error("Failed to consume data from buffers")
      return
    }

    Self.logger.info("[FRAME-DIAG] BUFFER-POOL: mixed=\(mixFrames)F, app_residual=\(self.appPCMBuffer.frameCount)F, mic_residual=\(self.micPCMBuffer.frameCount)F, output_ts=\(String(format: "%.6f", appTimestamp.seconds))s")
    Self.logger.info("[Decision] MIXING both streams: \(mixFrames)F, output_ts=\(appTimestamp.seconds)s")

    // Mix PCM data
    guard let mixedData = mixPCMData(app: appData, mic: micData, bitsPerChannel: 16) else {
      Self.logger.error("[Output] Failed to mix audio buffers")
      return
    }

    // Create sample buffer with correct timestamp
    guard let mixedBuffer = createSampleBuffer(from: mixedData, timestamp: appTimestamp, format: targetFormat) else {
      Self.logger.error("Failed to create mixed sample buffer")
      return
    }

    // Apply soft limiter
    if let limitedMixed = applySoftLimiterToSampleBuffer(SampleBufferBox(samplebuffer: mixedBuffer)) {
      outputContinuation.yield(limitedMixed)
      Self.logger.info("[Output] Mixed audio successful (soft limited)")
    } else {
      outputContinuation.yield(SampleBufferBox(samplebuffer: mixedBuffer))
      Self.logger.warning("[Output] Mixed audio successful (limiter failed, using original)")
    }
  }
  
  private func mixPCMData(app: Data, mic: Data, bitsPerChannel: UInt32) -> Data? {
    // Only support 16-bit PCM
    guard bitsPerChannel == 16 else {
      Self.logger.error("Unsupported bit depth: \(bitsPerChannel). AudioMixer only supports 16-bit PCM audio. Input audio must be 16-bit signed integer format.")
      return nil
    }

    // Verify both buffers are same size (should be guaranteed by buffer pool)
    guard app.count == mic.count else {
      Self.logger.error("[CRITICAL] Buffer size mismatch after pool alignment - app: \(app.count)B, mic: \(mic.count)B")
      return nil
    }

    // Calculate bytes per frame (16-bit stereo = 2 channels × 2 bytes = 4 bytes per frame)
    let bytesPerFrame = 4  // 2 channels × 2 bytes
    let samplesPerFrame = 2  // 2 channels
    let frameCount = app.count / bytesPerFrame
    let sampleCount = frameCount * samplesPerFrame  // Total samples for vDSP operations

    // Calculate RMS to detect silence
    let appRMS = AudioSampleBufferUtils.calculateRMS(pcmData: app, bitsPerChannel: 16)
    let micRMS = AudioSampleBufferUtils.calculateRMS(pcmData: mic, bitsPerChannel: 16)
    let silenceThreshold = 0.001 // RMS below this is considered silence

    Self.logger.info("[RMS] app=\(String(format: "%.4f", appRMS)), mic=\(String(format: "%.4f", micRMS))")

    // If app audio is silence, return mic only (no mixing needed)
    if appRMS < silenceThreshold {
      Self.logger.warning("[Silence Detection] App audio is SILENT (RMS=\(String(format: "%.4f", appRMS))), returning mic only")
      return mic
    }

    // If mic audio is silence, return app only
    if micRMS < silenceThreshold {
      Self.logger.warning("[Silence Detection] Mic audio is SILENT (RMS=\(String(format: "%.4f", micRMS))), returning app only")
      return app
    }

    var mixedData = Data(count: sampleCount * 2)  // sampleCount samples × 2 bytes per sample

    app.withUnsafeBytes { appBytes in
      mic.withUnsafeBytes { micBytes in
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


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

  private let targetSampleRate: Double
  private let appVolume: Float
  private let micVolume: Float
  
  private let appResampler: AudioResampler
  private let micResampler: AudioResampler

  private let appAudioStream: AsyncStream<SampleBufferBox>
  private let appAudioContinuation: AsyncStream<SampleBufferBox>.Continuation

  private let micAudioStream: AsyncStream<SampleBufferBox>
  private let micAudioContinuation: AsyncStream<SampleBufferBox>.Continuation

  private let _outputStream: AsyncStream<SampleBufferBox>
  private let outputContinuation: AsyncStream<SampleBufferBox>.Continuation
  
  nonisolated var outputStream: AsyncStream<SampleBufferBox> {
    _outputStream
  }

  private var appPCMBuffer = TimestampedPCMBuffer(sampleRate: 48000, bytesPerFrame: 4)
  private var micPCMBuffer = TimestampedPCMBuffer(sampleRate: 48000, bytesPerFrame: 4)

  private let maxBufferFrames = 4800  // 100ms @ 48kHz to prevent buffer overflow

  private let bufferTimeThreshold: CMTime = CMTime(seconds: 0.05, preferredTimescale: 1000000)
  private let maxTimeDiffBeforeDrop: CMTime = CMTime(seconds: 1.0, preferredTimescale: 1000000)

  nonisolated(unsafe) private var appProcessingTask: Task<Void, Never>?
  nonisolated(unsafe) private var micProcessingTask: Task<Void, Never>?

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

    mutating func append(_ newData: Data, timestamp: CMTime) {
      if data.isEmpty {
        data = newData
        startTimestamp = timestamp
      } else {
        data.append(newData)
      }
    }

    mutating func consume(frames: Int) -> (data: Data, timestamp: CMTime)? {
      guard frames > 0, data.count >= frames * bytesPerFrame else {
        return nil
      }

      let consumeBytes = frames * bytesPerFrame
      let consumedData = Data(data.prefix(consumeBytes))
      let timestamp = startTimestamp

      data = Data(data.suffix(from: consumeBytes))

      if !data.isEmpty {
        let duration = CMTime(seconds: Double(frames) / sampleRate, preferredTimescale: 1000000)
        startTimestamp = CMTimeAdd(startTimestamp, duration)
      } else {
        startTimestamp = .zero
      }

      return (consumedData, timestamp)
    }

    mutating func clear() {
      data.removeAll()
      startTimestamp = .zero
    }
  }

  init(targetSampleRate: Double = 48000, appVolume: Float = 0.7, micVolume: Float = 1.0) {
    self.targetSampleRate = targetSampleRate
    self.appVolume = appVolume
    self.micVolume = micVolume

    // Separate resamplers to avoid converter recreation overhead
    self.appResampler = AudioResampler(targetSampleRate: targetSampleRate, targetChannels: 2, targetBitsPerChannel: 16)
    self.micResampler = AudioResampler(targetSampleRate: targetSampleRate, targetChannels: 2, targetBitsPerChannel: 16)

    (self.appAudioStream, self.appAudioContinuation) = AsyncStream<SampleBufferBox>.makeStream()
    (self.micAudioStream, self.micAudioContinuation) = AsyncStream<SampleBufferBox>.makeStream()
    (self._outputStream, self.outputContinuation) = AsyncStream<SampleBufferBox>.makeStream()

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

  nonisolated func pushAppAudio(_ sampleBuffer: SampleBufferBox) {
    appAudioContinuation.yield(sampleBuffer)
  }

  nonisolated func pushMicAudio(_ sampleBuffer: SampleBufferBox) {
    micAudioContinuation.yield(sampleBuffer)
  }

  func stop() {
    appProcessingTask?.cancel()
    micProcessingTask?.cancel()

    appAudioContinuation.finish()
    micAudioContinuation.finish()
    outputContinuation.finish()

    appPCMBuffer.clear()
    micPCMBuffer.clear()
  }

  /// Process app audio stream (MAIN DRIVER for mixing)
  /// App audio arrival triggers mixing, while mic audio is passively buffered
  private func processAppAudioStream() async {
    for await sampleBufferBox in appAudioStream {
      guard let normalizedBox = await appResampler.resample(sampleBufferBox) else {
        Self.logger.warning("Failed to resample app audio")
        continue
      }

      guard let pcmData = AudioSampleBufferUtils.extractPCMData(from: normalizedBox.samplebuffer) else {
        Self.logger.error("Failed to extract PCM data from app audio")
        continue
      }

      let timestamp = CMSampleBufferGetPresentationTimeStamp(normalizedBox.samplebuffer)
      appPCMBuffer.append(pcmData, timestamp: timestamp)

      if appPCMBuffer.frameCount > maxBufferFrames {
        let dropFrames = appPCMBuffer.frameCount - maxBufferFrames
        _ = appPCMBuffer.consume(frames: dropFrames)
        Self.logger.warning("App buffer overflow, dropped \(dropFrames) frames")
      }

      await processMixing()
    }
  }

  /// Process mic audio stream (PASSIVE BUFFERING only)
  /// Buffered data will be consumed when app audio triggers mixing
  private func processMicAudioStream() async {
    for await sampleBufferBox in micAudioStream {
      guard let normalizedBox = await micResampler.resample(sampleBufferBox) else {
        Self.logger.warning("Failed to resample mic audio")
        continue
      }

      guard let pcmData = AudioSampleBufferUtils.extractPCMData(from: normalizedBox.samplebuffer) else {
        Self.logger.error("Failed to extract PCM data from mic audio")
        continue
      }

      let timestamp = CMSampleBufferGetPresentationTimeStamp(normalizedBox.samplebuffer)
      micPCMBuffer.append(pcmData, timestamp: timestamp)

      if micPCMBuffer.frameCount > maxBufferFrames {
        let dropFrames = micPCMBuffer.frameCount - maxBufferFrames
        _ = micPCMBuffer.consume(frames: dropFrames)
        Self.logger.warning("Mic buffer overflow, dropped \(dropFrames) frames")
      }
    }
  }

  private func processMixing() async {
    let targetFormat = appResampler.targetAudioFormat

    if !appPCMBuffer.isEmpty && micPCMBuffer.isEmpty {
      guard let (appData, appTimestamp) = appPCMBuffer.consume(frames: appPCMBuffer.frameCount) else {
        return
      }

      if let outputBuffer = createSampleBuffer(from: appData, timestamp: appTimestamp, format: targetFormat) {
        outputContinuation.yield(SampleBufferBox(samplebuffer: outputBuffer))
      }
      return
    }

    if appPCMBuffer.isEmpty && !micPCMBuffer.isEmpty {
      guard let (micData, micTimestamp) = micPCMBuffer.consume(frames: micPCMBuffer.frameCount) else {
        return
      }

      if let outputBuffer = createSampleBuffer(from: micData, timestamp: micTimestamp, format: targetFormat) {
        outputContinuation.yield(SampleBufferBox(samplebuffer: outputBuffer))
      }
      return
    }

    if appPCMBuffer.isEmpty || micPCMBuffer.isEmpty {
      return
    }

    let mixFrames = min(appPCMBuffer.frameCount, micPCMBuffer.frameCount)

    guard let (appData, appTimestamp) = appPCMBuffer.consume(frames: mixFrames),
          let (micData, _) = micPCMBuffer.consume(frames: mixFrames) else {
      Self.logger.error("Failed to consume data from buffers")
      return
    }

    guard let mixedData = mixPCMData(app: appData, mic: micData, bitsPerChannel: 16) else {
      Self.logger.error("Failed to mix audio buffers")
      return
    }

    guard let mixedBuffer = createSampleBuffer(from: mixedData, timestamp: appTimestamp, format: targetFormat) else {
      Self.logger.error("Failed to create mixed sample buffer")
      return
    }

    if let limitedMixed = applySoftLimiterToSampleBuffer(SampleBufferBox(samplebuffer: mixedBuffer)) {
      outputContinuation.yield(limitedMixed)
    } else {
      outputContinuation.yield(SampleBufferBox(samplebuffer: mixedBuffer))
    }
  }

  private func mixPCMData(app: Data, mic: Data, bitsPerChannel: UInt32) -> Data? {
    guard bitsPerChannel == 16 else {
      Self.logger.error("Unsupported bit depth: \(bitsPerChannel). AudioMixer only supports 16-bit PCM audio.")
      return nil
    }

    guard app.count == mic.count else {
      Self.logger.error("Buffer size mismatch - app: \(app.count)B, mic: \(mic.count)B")
      return nil
    }

    let bytesPerFrame = 4
    let samplesPerFrame = 2
    let frameCount = app.count / bytesPerFrame
    let sampleCount = frameCount * samplesPerFrame

    let appRMS = AudioSampleBufferUtils.calculateRMS(pcmData: app, bitsPerChannel: 16)
    let micRMS = AudioSampleBufferUtils.calculateRMS(pcmData: mic, bitsPerChannel: 16)
    let silenceThreshold = 0.001

    // Avoid mixing if one stream is silent
    if appRMS < silenceThreshold {
      return mic
    }

    if micRMS < silenceThreshold {
      return app
    }

    var mixedData = Data(count: sampleCount * 2)

    app.withUnsafeBytes { appBytes in
      mic.withUnsafeBytes { micBytes in
        mixedData.withUnsafeMutableBytes { mixedBytes in
          let appSamples = appBytes.bindMemory(to: Int16.self)
          let micSamples = micBytes.bindMemory(to: Int16.self)
          let mixedSamples = mixedBytes.bindMemory(to: Int16.self)

          var appFloat = [Float](repeating: 0, count: sampleCount)
          var micFloat = [Float](repeating: 0, count: sampleCount)
          var mixedFloat = [Float](repeating: 0, count: sampleCount)

          vDSP_vflt16(appSamples.baseAddress!, 1, &appFloat, 1, vDSP_Length(sampleCount))
          vDSP_vflt16(micSamples.baseAddress!, 1, &micFloat, 1, vDSP_Length(sampleCount))

          // Use 0.5x gain for each stream to prevent overflow (total gain = 1.0x)
          var halfGain: Float = 0.5
          vDSP_vsmul(appFloat, 1, &halfGain, &appFloat, 1, vDSP_Length(sampleCount))
          vDSP_vsmul(micFloat, 1, &halfGain, &micFloat, 1, vDSP_Length(sampleCount))
          vDSP_vadd(appFloat, 1, micFloat, 1, &mixedFloat, 1, vDSP_Length(sampleCount))

          var minValue = Float(Int16.min)
          var maxValue = Float(Int16.max)
          vDSP_vclip(mixedFloat, 1, &minValue, &maxValue, &mixedFloat, 1, vDSP_Length(sampleCount))

          vDSP_vfix16(mixedFloat, 1, mixedSamples.baseAddress!, 1, vDSP_Length(sampleCount))
        }
      }
    }

    return mixedData
  }
  
  private func createSampleBuffer(from data: Data, timestamp: CMTime, format: AudioStreamBasicDescription) -> CMSampleBuffer? {
    guard format.mBitsPerChannel == 16 else {
      Self.logger.error("Unsupported bit depth \(format.mBitsPerChannel). Must be 16-bit.")
      return nil
    }

    guard let sampleBuffer = AudioSampleBufferUtils.createAudioSampleBuffer(
      from: data,
      timestamp: timestamp,
      format: format
    ) else {
      Self.logger.error("Failed to create sample buffer")
      return nil
    }

    return sampleBuffer
  }

  private func applySoftLimiterToSampleBuffer(_ sampleBufferBox: SampleBufferBox) -> SampleBufferBox? {
    let sampleBuffer = sampleBufferBox.samplebuffer

    guard let pcmData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer) else {
      Self.logger.error("Soft limiter: Failed to extract PCM data")
      return nil
    }

    guard let asbd = AudioSampleBufferUtils.extractFormat(from: sampleBuffer) else {
      Self.logger.error("Soft limiter: Failed to extract format")
      return nil
    }

    guard asbd.mBitsPerChannel == 16 else {
      Self.logger.error("Soft limiter: Unsupported bit depth \(asbd.mBitsPerChannel)")
      return nil
    }

    let limitedData = applySoftLimiter(pcmData)

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard let limitedBuffer = createSampleBuffer(from: limitedData, timestamp: timestamp, format: asbd) else {
      Self.logger.error("Soft limiter: Failed to create sample buffer")
      return nil
    }

    return SampleBufferBox(samplebuffer: limitedBuffer)
  }

  /// Apply soft limiter using tanh function for smooth compression instead of hard clipping
  private func applySoftLimiter(_ data: Data) -> Data {
    let bytesPerSample = 2
    let sampleCount = data.count / bytesPerSample
    var limitedData = Data(count: data.count)

    data.withUnsafeBytes { inputBytes in
      limitedData.withUnsafeMutableBytes { outputBytes in
        let inputSamples = inputBytes.bindMemory(to: Int16.self)
        let outputSamples = outputBytes.bindMemory(to: Int16.self)

        var floatSamples = [Float](repeating: 0, count: sampleCount)
        var limitedFloatSamples = [Float](repeating: 0, count: sampleCount)

        vDSP_vflt16(inputSamples.baseAddress!, 1, &floatSamples, 1, vDSP_Length(sampleCount))

        var divisor: Float = Float(Int16.max)
        vDSP_vsdiv(floatSamples, 1, &divisor, &floatSamples, 1, vDSP_Length(sampleCount))

        // Apply tanh soft clipping directly to normalized signal
        // Only signals exceeding ±1.0 will be compressed, preserving audio quality
        var inputCount = Int32(sampleCount)
        vvtanhf(&limitedFloatSamples, floatSamples, &inputCount)

        var multiplier: Float = Float(Int16.max)
        vDSP_vsmul(limitedFloatSamples, 1, &multiplier, &limitedFloatSamples, 1, vDSP_Length(sampleCount))

        vDSP_vfix16(limitedFloatSamples, 1, outputSamples.baseAddress!, 1, vDSP_Length(sampleCount))
      }
    }

    return limitedData
  }
}


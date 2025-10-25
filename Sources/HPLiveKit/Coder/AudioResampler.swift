//
//  AudioResampler.swift
//  HPLiveKit
//
//  Created for audio format normalization
//

import Foundation
import CoreMedia
import AudioToolbox
import AVFoundation
import os

/// Audio format resampler using Swift 6 Actor for thread safety
/// Converts input CMSampleBuffer to normalized format
///
/// **Thread Safety**: All methods are actor-isolated and safe for concurrent access
/// **Resource Management**: Call stop() to release resources, or they will be released when actor is deallocated
actor AudioResampler {
  private static let logger = Logger(subsystem: "com.hplivekit", category: "AudioResampler")

  // MARK: - Configuration

  // Target format specifications
  private let targetSampleRate: Double
  private let targetChannels: UInt32
  private let targetBitsPerChannel: UInt32

  // MARK: - State

  // Audio converter wrapper for automatic cleanup
  private final class ConverterBox {
    var converter: AudioConverterRef?

    deinit {
      if let converter {
        AudioConverterDispose(converter)
      }
    }
  }

  private let converterBox = ConverterBox()

  private var converter: AudioConverterRef? {
    get { converterBox.converter }
    set { converterBox.converter = newValue }
  }

  // Source format tracking
  private var sourceSampleRate: Double = 0
  private var sourceChannels: UInt32 = 0
  private var sourceBitsPerChannel: UInt32 = 0

  // Cached format descriptors for performance
  private var cachedTargetFormat: AudioStreamBasicDescription?
  private var cachedFormatDescription: CMAudioFormatDescription?

  // MARK: - Initialization

  init(targetSampleRate: Double = 48000, targetChannels: UInt32 = 2, targetBitsPerChannel: UInt32 = 16) {
    self.targetSampleRate = targetSampleRate
    self.targetChannels = targetChannels
    self.targetBitsPerChannel = targetBitsPerChannel
  }

  // MARK: - Public API

  /// Get target audio format (for creating sample buffers externally)
  nonisolated var targetAudioFormat: AudioStreamBasicDescription {
    var outputFormat = AudioStreamBasicDescription()
    outputFormat.mSampleRate = targetSampleRate
    outputFormat.mFormatID = kAudioFormatLinearPCM
    outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    outputFormat.mChannelsPerFrame = targetChannels
    outputFormat.mBitsPerChannel = targetBitsPerChannel
    outputFormat.mBytesPerFrame = targetBitsPerChannel / 8 * targetChannels
    outputFormat.mFramesPerPacket = 1
    outputFormat.mBytesPerPacket = outputFormat.mBytesPerFrame
    return outputFormat
  }

  func stop() {
    if let converter {
      AudioConverterDispose(converter)
      self.converter = nil
    }
    cachedFormatDescription = nil
  }

  // MARK: - Private Helpers

  /// Get cached or create target audio format (private, actor-isolated)
  private var targetFormat: AudioStreamBasicDescription {
    if let cached = cachedTargetFormat {
      return cached
    }

    var outputFormat = AudioStreamBasicDescription()
    outputFormat.mSampleRate = targetSampleRate
    outputFormat.mFormatID = kAudioFormatLinearPCM
    outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    outputFormat.mChannelsPerFrame = targetChannels
    outputFormat.mBitsPerChannel = targetBitsPerChannel
    outputFormat.mBytesPerFrame = targetBitsPerChannel / 8 * targetChannels
    outputFormat.mFramesPerPacket = 1
    outputFormat.mBytesPerPacket = outputFormat.mBytesPerFrame

    cachedTargetFormat = outputFormat
    return outputFormat
  }
  
  /// Resample audio sample buffer to target format
  /// - Parameter sampleBufferBox: Input sample buffer box
  /// - Returns: Resampled sample buffer box with target format, or nil if conversion fails
  func resample(_ sampleBufferBox: SampleBufferBox) -> SampleBufferBox? {
    let sampleBuffer = sampleBufferBox.samplebuffer

    // [FRAME-DIAG] Record input info
    let inputFrameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    let inputDuration = CMSampleBufferGetDuration(sampleBuffer)
    let inputTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      Self.logger.error("Cannot get format description")
      return nil
    }

    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
      Self.logger.error("Cannot get audio stream basic description")
      return nil
    }

    // [FRAME-DIAG] Log input
    Self.logger.info("[FRAME-DIAG] RESAMPLE-IN: frames=\(inputFrameCount), dur=\(String(format: "%.6f", inputDuration.seconds))s, rate=\(asbd.mSampleRate)Hz, ts=\(String(format: "%.6f", inputTimestamp.seconds))s")
    
    // Check if resampling is needed
    let needsResampling = asbd.mSampleRate != targetSampleRate ||
    asbd.mChannelsPerFrame != targetChannels ||
    asbd.mBitsPerChannel != targetBitsPerChannel
    
    if !needsResampling {
      return sampleBufferBox // Return original if format matches
    }
    
    // Setup converter if format changed
    if !setupConverterIfNeeded(sourceFormat: asbd) {
      Self.logger.error("Failed to setup audio converter")
      return nil
    }
    
    // Extract audio data
    guard let audioData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer) else {
      Self.logger.error("Failed to extract audio data")
      return nil
    }
    
    // Convert audio data
    guard let convertedData = convert(audioData: audioData, sourceFormat: asbd) else {
      Self.logger.error("Failed to convert audio data")
      return nil
    }
    
    // Create new sample buffer with converted data
    guard let newSampleBuffer = createSampleBuffer(from: convertedData,
                                                     timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else {
      return nil
    }

    // [FRAME-DIAG] Log output
    let outputFrameCount = CMSampleBufferGetNumSamples(newSampleBuffer)
    let outputDuration = CMSampleBufferGetDuration(newSampleBuffer)
    let delta = outputFrameCount - inputFrameCount
    Self.logger.info("[FRAME-DIAG] RESAMPLE-OUT: frames=\(outputFrameCount), dur=\(String(format: "%.6f", outputDuration.seconds))s, delta=\(delta)")

    return SampleBufferBox(samplebuffer: newSampleBuffer)
  }
  
  // MARK: - Private Methods
  
  private func setupConverterIfNeeded(sourceFormat: AudioStreamBasicDescription) -> Bool {
    // Check if format changed
    if sourceSampleRate == sourceFormat.mSampleRate &&
        sourceChannels == sourceFormat.mChannelsPerFrame &&
        sourceBitsPerChannel == sourceFormat.mBitsPerChannel,
       converter != nil {
      return true // Converter already setup
    }

    // Dispose old converter
    if let oldConverter = converter {
      AudioConverterDispose(oldConverter)
      converter = nil
    }

    // Save source format
    sourceSampleRate = sourceFormat.mSampleRate
    sourceChannels = sourceFormat.mChannelsPerFrame
    sourceBitsPerChannel = sourceFormat.mBitsPerChannel

    // Create input format
    var inputFormat = sourceFormat

    // Create output format
    var outputFormat = targetFormat

    // Create converter
    var status = AudioConverterNew(&inputFormat, &outputFormat, &converter)
    if status != noErr {
      Self.logger.error("AudioConverterNew failed: \(status, privacy: .public)")
      return false
    }

    // Set sample rate converter quality to maximum for best audio quality
    // This is especially important for upsampling (e.g., 44.1kHz -> 48kHz)
    guard let converter = converter else { return false }
    var quality = kAudioConverterQuality_Max
    status = AudioConverterSetProperty(
      converter,
      kAudioConverterSampleRateConverterQuality,
      UInt32(MemoryLayout<UInt32>.size),
      &quality
    )

    if status != noErr {
      Self.logger.warning("Failed to set audio converter quality: \(status, privacy: .public), using default quality")
    } else {
      Self.logger.info("Audio converter quality set to MAX")
    }

    Self.logger.info("Audio converter created - Input: \(sourceFormat.mSampleRate, privacy: .public)Hz \(sourceFormat.mChannelsPerFrame, privacy: .public)ch \(sourceFormat.mBitsPerChannel, privacy: .public)bit -> Output: \(self.targetSampleRate, privacy: .public)Hz \(self.targetChannels, privacy: .public)ch \(self.targetBitsPerChannel, privacy: .public)bit")

    return true
  }
  /// Context for audio conversion to ensure proper memory lifetime
  private struct ConversionContext {
    let inputData: Data
    var hasProvidedData: Bool = false
    let sourceFormat: AudioStreamBasicDescription

    init(inputData: Data, sourceFormat: AudioStreamBasicDescription) {
      self.inputData = inputData
      self.sourceFormat = sourceFormat
    }
  }

  private func convert(audioData: Data, sourceFormat: AudioStreamBasicDescription) -> Data? {
    guard let converter = converter else { return nil }

    // Calculate output buffer size with 1.5x margin for safety
    let sourceFrames = audioData.count / Int(sourceFormat.mBytesPerFrame)
    let targetFrames = Int(Double(sourceFrames) * targetSampleRate / sourceFormat.mSampleRate)
    let outputBytesPerFrame = Int(targetBitsPerChannel / 8 * targetChannels)
    let outputSize = Int(Double(targetFrames * outputBytesPerFrame) * 1.5)

    // [DIAGNOSTIC] Log input info
    let inputRMS = AudioSampleBufferUtils.calculateRMS(pcmData: audioData, bitsPerChannel: Int(sourceFormat.mBitsPerChannel))
    Self.logger.info("[DIAGNOSTIC] AudioConverter INPUT: \(sourceFrames) frames, \(audioData.count) bytes, RMS=\(String(format: "%.4f", inputRMS)), \(sourceFormat.mSampleRate)Hz/\(sourceFormat.mChannelsPerFrame)ch")
    Self.logger.info("[DIAGNOSTIC] AudioConverter EXPECTED OUTPUT: \(targetFrames) frames, \(targetFrames * outputBytesPerFrame) bytes, \(self.targetSampleRate)Hz/\(self.targetChannels)ch")

    var outputData = Data(count: outputSize)

    // Pre-allocate input buffer to ensure lifetime
    let inputDataCopy = audioData
    let sourceFormatCopy = sourceFormat

    // Use AudioConverterFillComplexBuffer with improved callback that allows multiple reads
    let result: (status: OSStatus, actualSize: Int) = inputDataCopy.withUnsafeBytes { inputBytes in
      outputData.withUnsafeMutableBytes { outputBytes in
        guard let inputBaseAddress = inputBytes.baseAddress,
              let outputBaseAddress = outputBytes.baseAddress else {
          return (kAudioConverterErr_InvalidInputSize, 0)
        }

        // Setup output buffer list
        var outBufferList = AudioBufferList()
        outBufferList.mNumberBuffers = 1
        outBufferList.mBuffers.mNumberChannels = targetChannels
        outBufferList.mBuffers.mDataByteSize = UInt32(outputSize)
        outBufferList.mBuffers.mData = outputBaseAddress

        var ioOutputDataPacketSize = UInt32(targetFrames)

        // Callback state - track how much data has been consumed
        struct CallbackState {
          let inputBaseAddress: UnsafeRawPointer
          let inputDataSize: Int
          let sourceFormat: AudioStreamBasicDescription
          var consumedFrames: Int = 0  // Track consumed frames instead of boolean flag
          var callCount: Int = 0
        }

        var callbackState = CallbackState(
          inputBaseAddress: inputBaseAddress,
          inputDataSize: inputDataCopy.count,
          sourceFormat: sourceFormatCopy
        )

        // Call converter with callback that supports multiple reads
        let status = withUnsafeMutablePointer(to: &callbackState) { statePtr in
          AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumDataPackets, ioData, _, inUserData) -> OSStatus in
              guard let userDataPtr = inUserData else {
                return kAudioConverterErr_InvalidInputSize
              }

              let state = userDataPtr.assumingMemoryBound(to: CallbackState.self)
              state.pointee.callCount += 1

              let bytesPerFrame = Int(state.pointee.sourceFormat.mBytesPerFrame)
              let totalFrames = state.pointee.inputDataSize / bytesPerFrame
              let remainingFrames = totalFrames - state.pointee.consumedFrames

              // If all data consumed, signal end of data
              if remainingFrames <= 0 {
                ioNumDataPackets.pointee = 0
                return noErr
              }

              // Provide remaining data (AudioConverter will read what it needs)
              let framesToProvide = min(remainingFrames, Int(ioNumDataPackets.pointee))
              let bytesToProvide = framesToProvide * bytesPerFrame
              let offsetBytes = state.pointee.consumedFrames * bytesPerFrame

              // Setup input buffer list pointing to remaining data
              var inBufferList = AudioBufferList()
              inBufferList.mNumberBuffers = 1
              inBufferList.mBuffers.mNumberChannels = state.pointee.sourceFormat.mChannelsPerFrame
              inBufferList.mBuffers.mDataByteSize = UInt32(bytesToProvide)
              inBufferList.mBuffers.mData = UnsafeMutableRawPointer(mutating: state.pointee.inputBaseAddress.advanced(by: offsetBytes))

              ioData.pointee = inBufferList
              ioNumDataPackets.pointee = UInt32(framesToProvide)

              // Update consumed frames
              state.pointee.consumedFrames += framesToProvide

              return noErr
            },
            statePtr,
            &ioOutputDataPacketSize,
            &outBufferList,
            nil
          )
        }

        // [RESAMPLE-DEBUG] Log callback statistics
        Self.logger.info("[RESAMPLE-DEBUG] Callback called \(callbackState.callCount) times")
        Self.logger.info("[RESAMPLE-DEBUG] Total frames consumed: \(callbackState.consumedFrames) / \(sourceFrames)")

        // [DIAGNOSTIC] Log what AudioConverter actually wrote
        let actualFramesWritten = Int(ioOutputDataPacketSize)
        let actualBytesWritten = actualFramesWritten * outputBytesPerFrame
        let reportedSize = Int(outBufferList.mBuffers.mDataByteSize)
        Self.logger.info("[DIAGNOSTIC] AudioConverter WRITE INFO: ioOutputDataPacketSize=\(actualFramesWritten) frames, calculated=\(actualBytesWritten) bytes, mDataByteSize=\(reportedSize) bytes, diff=\(reportedSize - actualBytesWritten) bytes")

        // [RESAMPLE-DEBUG] Verify AudioConverter output
        Self.logger.info("[RESAMPLE-DEBUG] AudioConverter completed - status: \(status)")
        Self.logger.info("[RESAMPLE-DEBUG] Output size - ioOutputDataPacketSize: \(actualFramesWritten) frames")
        Self.logger.info("[RESAMPLE-DEBUG] Output size - calculated: \(actualBytesWritten) bytes (\(actualFramesWritten) × \(outputBytesPerFrame))")
        Self.logger.info("[RESAMPLE-DEBUG] Output size - mDataByteSize: \(reportedSize) bytes")
        Self.logger.info("[RESAMPLE-DEBUG] Output size - diff: \(reportedSize - actualBytesWritten) bytes")

        return (status, actualBytesWritten)
      }
    }

    guard result.status == noErr else {
      Self.logger.error("AudioConverterFillComplexBuffer failed: \(result.status, privacy: .public)")
      return nil
    }

    // [RESAMPLE-DEBUG] Before trim
    let beforeTrimSize = outputData.count
    Self.logger.info("[RESAMPLE-DEBUG] Before trim - outputData.count: \(beforeTrimSize) bytes")
    Self.logger.info("[RESAMPLE-DEBUG] Trimming to - result.actualSize: \(result.actualSize) bytes")

    // Trim to actual size
    outputData.count = result.actualSize

    // [RESAMPLE-DEBUG] After trim
    let afterTrimSize = outputData.count
    Self.logger.info("[RESAMPLE-DEBUG] After trim - outputData.count: \(afterTrimSize) bytes")
    Self.logger.info("[RESAMPLE-DEBUG] Trimmed bytes: \(beforeTrimSize - afterTrimSize)")

    // [DIAGNOSTIC] Log output info
    let actualFrames = result.actualSize / outputBytesPerFrame
    let outputRMS = AudioSampleBufferUtils.calculateRMS(pcmData: outputData, bitsPerChannel: Int(targetBitsPerChannel))
    Self.logger.info("[DIAGNOSTIC] AudioConverter ACTUAL OUTPUT: \(actualFrames) frames, \(result.actualSize) bytes, RMS=\(String(format: "%.4f", outputRMS))")

    // [RESAMPLE-DEBUG] Verify trimmed data integrity
    Self.logger.info("[RESAMPLE-DEBUG] Final data RMS: \(String(format: "%.4f", outputRMS))")
    Self.logger.info("[RESAMPLE-DEBUG] Data integrity - frames: \(actualFrames), expected: ~\(targetFrames)")

    let rmsLossPercent = inputRMS > 0 ? (1 - outputRMS/inputRMS) * 100 : 0
    Self.logger.info("[DIAGNOSTIC] AudioConverter RMS COMPARISON: input=\(String(format: "%.4f", inputRMS)), output=\(String(format: "%.4f", outputRMS)), loss=\(String(format: "%.1f%%", rmsLossPercent))")

    return outputData
  }
  
  private func createSampleBuffer(from data: Data, timestamp: CMTime) -> CMSampleBuffer? {
    // Get or create cached format description for performance
    if cachedFormatDescription == nil {
      var outputFormat = targetFormat
      var formatDescription: CMAudioFormatDescription?
      let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &outputFormat,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
      )

      guard status == noErr, let desc = formatDescription else {
        Self.logger.error("Failed to create format description: \(status, privacy: .public)")
        return nil
      }

      cachedFormatDescription = desc
    }

    // Use utility method to create sample buffer with cached format description
    guard let sampleBuffer = AudioSampleBufferUtils.createAudioSampleBuffer(
      from: data,
      timestamp: timestamp,
      format: targetFormat,
      formatDescription: cachedFormatDescription
    ) else {
      Self.logger.error("Failed to create sample buffer using AudioSampleBufferUtils")
      return nil
    }

    return sampleBuffer
  }
}

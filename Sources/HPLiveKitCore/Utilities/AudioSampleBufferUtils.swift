//
//  AudioSampleBufferUtils.swift
//  HPLiveKit
//
//  Audio sample buffer utility methods
//  Thread-safe static methods for audio processing
//

import Foundation
import CoreMedia
import AudioToolbox
import AVFoundation
import os

/// Utility methods for audio sample buffer operations
/// All methods are static and thread-safe (no shared state)
public enum AudioSampleBufferUtils {

  // MARK: - PCM Data Extraction

  /// Extract PCM audio data from CMSampleBuffer
  /// - Parameter sampleBuffer: Source sample buffer
  /// - Returns: Raw PCM data, or nil if extraction fails
  public static func extractPCMData(from sampleBuffer: CMSampleBuffer) -> Data? {
    var blockBuffer: CMBlockBuffer?
    var audioBufferList = AudioBufferList()

    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: &audioBufferList,
      bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &blockBuffer
    )

    guard status == noErr else {
      return nil
    }

    defer {
      // CMBlockBuffer is automatically memory managed in Swift 6
      _ = blockBuffer
    }

    let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
    guard let buffer = buffers.first, let data = buffer.mData else {
      return nil
    }

    return Data(bytes: data, count: Int(buffer.mDataByteSize))
  }

  // MARK: - Format Extraction

  /// Extract audio format description from sample buffer
  /// - Parameter sampleBuffer: Source sample buffer
  /// - Returns: AudioStreamBasicDescription, or nil if extraction fails
  public static func extractFormat(from sampleBuffer: CMSampleBuffer) -> AudioStreamBasicDescription? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      return nil
    }
    return extractFormat(from: formatDescription)
  }

  /// Extract audio format description from format description
  /// - Parameter formatDescription: CMAudioFormatDescription
  /// - Returns: AudioStreamBasicDescription, or nil if extraction fails
  public static func extractFormat(from formatDescription: CMAudioFormatDescription) -> AudioStreamBasicDescription? {
    return CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
  }

  // MARK: - Sample Buffer Creation

  /// Create audio sample buffer from PCM data
  /// - Parameters:
  ///   - data: Raw PCM data
  ///   - timestamp: Presentation timestamp
  ///   - format: Audio format description
  ///   - formatDescription: Optional pre-created format description (for performance)
  /// - Returns: Created CMSampleBuffer, or nil if creation fails
  public static func createAudioSampleBuffer(
    from data: Data,
    timestamp: CMTime,
    format: AudioStreamBasicDescription,
    formatDescription: CMAudioFormatDescription? = nil
  ) -> CMSampleBuffer? {
    // Get or create format description
    let formatDesc: CMAudioFormatDescription
    if let existingDesc = formatDescription {
      formatDesc = existingDesc
    } else {
      var mutableFormat = format
      var newFormatDescription: CMAudioFormatDescription?
      let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &mutableFormat,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &newFormatDescription
      )

      guard status == noErr, let desc = newFormatDescription else {
        return nil
      }
      formatDesc = desc
    }

    // Create block buffer
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )

    guard status == noErr, let blockBuf = blockBuffer else {
      return nil
    }

    // Copy data to block buffer
    status = data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return kAudioConverterErr_InvalidInputSize
      }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: blockBuf,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }

    guard status == noErr else {
      return nil
    }

    // Create sample buffer
    let frameCount = data.count / Int(format.mBytesPerFrame)
    var sampleBuffer: CMSampleBuffer?
    status = CMAudioSampleBufferCreateWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuf,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDesc,
      sampleCount: frameCount,
      presentationTimeStamp: timestamp,
      packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer
    )

    guard status == noErr, let sample = sampleBuffer else {
      return nil
    }

    return sample
  }

  // MARK: - Format Verification

  /// Verify if sample buffer matches expected format
  /// - Parameters:
  ///   - sampleBuffer: Sample buffer to verify
  ///   - expectedSampleRate: Expected sample rate
  ///   - expectedChannels: Expected number of channels
  ///   - expectedBitsPerChannel: Expected bits per channel
  /// - Returns: True if format matches, false otherwise
  public static func verifyFormat(
    _ sampleBuffer: CMSampleBuffer,
    expectedSampleRate: Double,
    expectedChannels: UInt32,
    expectedBitsPerChannel: UInt32
  ) -> Bool {
    guard let asbd = extractFormat(from: sampleBuffer) else {
      return false
    }

    return asbd.mSampleRate == expectedSampleRate &&
           asbd.mChannelsPerFrame == expectedChannels &&
           asbd.mBitsPerChannel == expectedBitsPerChannel
  }

  // MARK: - Audio Quality Analysis

  /// Calculate RMS (Root Mean Square) of audio data for quality comparison
  /// This is useful to verify that resampling doesn't destroy audio content
  /// - Parameters:
  ///   - pcmData: Raw PCM audio data
  ///   - bitsPerChannel: Bit depth (8, 16, 24, or 32)
  /// - Returns: RMS value (0.0 to 1.0)
  public static func calculateRMS(pcmData: Data, bitsPerChannel: Int) -> Double {
    guard !pcmData.isEmpty else { return 0 }

    var sumSquares: Double = 0
    var sampleCount = 0

    pcmData.withUnsafeBytes { bytes in
      switch bitsPerChannel {
      case 16:
        let samples = bytes.bindMemory(to: Int16.self)
        for i in 0..<samples.count {
          let normalized = Double(samples[i]) / Double(Int16.max)
          sumSquares += normalized * normalized
          sampleCount += 1
        }

      case 8:
        let samples = bytes.bindMemory(to: Int8.self)
        for i in 0..<samples.count {
          let normalized = Double(samples[i]) / Double(Int8.max)
          sumSquares += normalized * normalized
          sampleCount += 1
        }

      default:
        break
      }
    }

    guard sampleCount > 0 else { return 0 }
    return sqrt(sumSquares / Double(sampleCount))
  }

  /// Check if audio content is preserved after resampling (within tolerance)
  /// This compares RMS values to ensure audio energy is similar
  /// - Parameters:
  ///   - original: Original sample buffer
  ///   - resampled: Resampled sample buffer
  ///   - tolerance: Acceptable difference ratio (default 0.15 = 15%)
  /// - Returns: True if audio content is preserved within tolerance
  public static func isAudioContentPreserved(
    original: CMSampleBuffer,
    resampled: CMSampleBuffer,
    tolerance: Double = 0.15
  ) -> Bool {
    guard let originalData = extractPCMData(from: original),
          let resampledData = extractPCMData(from: resampled),
          let originalFormat = extractFormat(from: original),
          let resampledFormat = extractFormat(from: resampled) else {
      return false
    }

    let originalRMS = calculateRMS(pcmData: originalData, bitsPerChannel: Int(originalFormat.mBitsPerChannel))
    let resampledRMS = calculateRMS(pcmData: resampledData, bitsPerChannel: Int(resampledFormat.mBitsPerChannel))

    guard originalRMS > 0 else { return false }

    let difference = abs(originalRMS - resampledRMS) / originalRMS
    return difference <= tolerance
  }
}

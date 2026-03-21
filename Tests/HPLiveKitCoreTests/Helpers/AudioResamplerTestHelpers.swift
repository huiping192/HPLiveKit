//
//  AudioResamplerTestHelpers.swift
//  HPLiveKitTests
//
//  Created for AudioResampler testing support
//

import Foundation
import CoreMedia
import AudioToolbox
import AVFoundation
@testable import HPLiveKit

/// Helper functions and utilities for AudioResampler testing
enum AudioResamplerTestHelpers {

  // MARK: - Sample Buffer Creation

  /// Create a test audio sample buffer with specified format
  /// - Parameters:
  ///   - sampleRate: Sample rate in Hz
  ///   - channels: Number of channels
  ///   - bitsPerChannel: Bits per channel (8, 16, 24, 32)
  ///   - durationSeconds: Duration in seconds
  ///   - frequency: Sine wave frequency in Hz (default 440Hz - A4 note)
  /// - Returns: CMSampleBuffer with generated audio data
  static func createTestSampleBuffer(
    sampleRate: Double,
    channels: UInt32,
    bitsPerChannel: UInt32,
    durationSeconds: Double = 0.1,
    frequency: Double = 440.0
  ) -> CMSampleBuffer? {

    // Calculate buffer size
    let frameCount = Int(sampleRate * durationSeconds)
    let bytesPerFrame = Int(bitsPerChannel / 8 * channels)
    let dataSize = frameCount * bytesPerFrame

    // Generate PCM data (sine wave)
    let pcmData = generateSineWave(
      sampleRate: sampleRate,
      channels: Int(channels),
      bitsPerChannel: Int(bitsPerChannel),
      frameCount: frameCount,
      frequency: frequency
    )

    // Create audio format description
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = sampleRate
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    asbd.mChannelsPerFrame = channels
    asbd.mBitsPerChannel = bitsPerChannel
    asbd.mBytesPerFrame = UInt32(bytesPerFrame)
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerPacket = UInt32(bytesPerFrame)

    var formatDescription: CMAudioFormatDescription?
    var status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )

    guard status == noErr, let formatDesc = formatDescription else {
      print("Failed to create format description: \(status)")
      return nil
    }

    // Create block buffer
    var blockBuffer: CMBlockBuffer?
    status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: dataSize,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: dataSize,
      flags: 0,
      blockBufferOut: &blockBuffer
    )

    guard status == noErr, let blockBuf = blockBuffer else {
      print("Failed to create block buffer: \(status)")
      return nil
    }

    // Copy PCM data to block buffer
    status = pcmData.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return kAudioConverterErr_InvalidInputSize
      }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: blockBuf,
        offsetIntoDestination: 0,
        dataLength: dataSize
      )
    }

    guard status == noErr else {
      print("Failed to copy data to block buffer: \(status)")
      return nil
    }

    // Create sample buffer
    var sampleBuffer: CMSampleBuffer?
    let timestamp = CMTime(seconds: 0, preferredTimescale: 1000000)
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
      print("Failed to create sample buffer: \(status)")
      return nil
    }

    return sample
  }

  // MARK: - Audio Data Generation

  /// Generate sine wave PCM data
  private static func generateSineWave(
    sampleRate: Double,
    channels: Int,
    bitsPerChannel: Int,
    frameCount: Int,
    frequency: Double
  ) -> Data {
    var data = Data()

    let amplitude: Double = 0.3 // 30% to avoid clipping
    let angularFrequency = 2.0 * .pi * frequency

    for frame in 0..<frameCount {
      let time = Double(frame) / sampleRate
      let sampleValue = sin(angularFrequency * time) * amplitude

      // Convert to integer based on bit depth
      for _ in 0..<channels {
        switch bitsPerChannel {
        case 8:
          let intValue = Int8(sampleValue * Double(Int8.max))
          var value = intValue
          data.append(Data(bytes: &value, count: 1))

        case 16:
          let intValue = Int16(sampleValue * Double(Int16.max))
          var value = intValue
          withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
          }

        case 24:
          // 24-bit as Int32 but only use lower 24 bits
          let intValue = Int32(sampleValue * Double(Int32.max >> 8))
          var value = intValue
          withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes.prefix(3))
          }

        case 32:
          let intValue = Int32(sampleValue * Double(Int32.max))
          var value = intValue
          withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
          }

        default:
          fatalError("Unsupported bit depth: \(bitsPerChannel)")
        }
      }
    }

    return data
  }

}

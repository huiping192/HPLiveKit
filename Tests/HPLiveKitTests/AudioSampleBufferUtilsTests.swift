//
//  AudioSampleBufferUtilsTests.swift
//  HPLiveKitTests
//
//  Test suite for AudioSampleBufferUtils
//

import XCTest
import CoreMedia
import AudioToolbox
@testable import HPLiveKit

final class AudioSampleBufferUtilsTests: XCTestCase {

  // MARK: - Test: Extract PCM Data

  func testExtractPCMData() throws {
    // Arrange: Create test sample buffer
    guard let sampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 48000,
      channels: 2,
      bitsPerChannel: 16,
      durationSeconds: 0.1
    ) else {
      XCTFail("Failed to create test sample buffer")
      return
    }

    // Act: Extract PCM data
    let pcmData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer)

    // Assert: Data should be extracted successfully
    XCTAssertNotNil(pcmData, "PCM data should be extracted")

    if let data = pcmData {
      // Verify data size (sample rate * duration * channels * bytes per sample)
      let expectedSize = Int(48000 * 0.1 * 2 * 2)  // 48kHz * 0.1s * 2ch * 2bytes
      XCTAssertEqual(data.count, expectedSize, "PCM data size should match expected size")
    }
  }

  // MARK: - Test: Extract Format

  func testExtractFormat() throws {
    // Arrange: Create test sample buffer with known format
    guard let sampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 44100,
      channels: 1,
      bitsPerChannel: 16,
      durationSeconds: 0.1
    ) else {
      XCTFail("Failed to create test sample buffer")
      return
    }

    // Act: Extract format
    let format = AudioSampleBufferUtils.extractFormat(from: sampleBuffer)

    // Assert: Format should be extracted correctly
    XCTAssertNotNil(format, "Format should be extracted")

    if let asbd = format {
      XCTAssertEqual(asbd.mSampleRate, 44100, "Sample rate should match")
      XCTAssertEqual(asbd.mChannelsPerFrame, 1, "Channels should match")
      XCTAssertEqual(asbd.mBitsPerChannel, 16, "Bits per channel should match")
      XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM, "Format ID should be Linear PCM")
    }
  }

  // MARK: - Test: Create Audio Sample Buffer

  func testCreateAudioSampleBuffer() throws {
    // Arrange: Create test data
    let sampleRate: Double = 48000
    let channels: UInt32 = 2
    let bitsPerChannel: UInt32 = 16
    let durationSeconds: Double = 0.1

    let frameCount = Int(sampleRate * durationSeconds)
    let bytesPerFrame = Int(bitsPerChannel / 8 * channels)
    let dataSize = frameCount * bytesPerFrame

    // Create dummy PCM data
    let pcmData = Data(repeating: 0x55, count: dataSize)

    // Create format description
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = sampleRate
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    asbd.mChannelsPerFrame = channels
    asbd.mBitsPerChannel = bitsPerChannel
    asbd.mBytesPerFrame = UInt32(bytesPerFrame)
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerPacket = UInt32(bytesPerFrame)

    let timestamp = CMTime(seconds: 1.0, preferredTimescale: 1000000)

    // Act: Create sample buffer
    let sampleBuffer = AudioSampleBufferUtils.createAudioSampleBuffer(
      from: pcmData,
      timestamp: timestamp,
      format: asbd
    )

    // Assert: Sample buffer should be created successfully
    XCTAssertNotNil(sampleBuffer, "Sample buffer should be created")

    if let buffer = sampleBuffer {
      // Verify format
      XCTAssertTrue(
        AudioSampleBufferUtils.verifyFormat(
          buffer,
          expectedSampleRate: sampleRate,
          expectedChannels: channels,
          expectedBitsPerChannel: bitsPerChannel
        ),
        "Created sample buffer should have correct format"
      )

      // Verify timestamp
      let bufferTimestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
      XCTAssertEqual(
        bufferTimestamp.seconds,
        timestamp.seconds,
        accuracy: 0.0001,
        "Timestamp should be preserved"
      )

      // Verify data
      let extractedData = AudioSampleBufferUtils.extractPCMData(from: buffer)
      XCTAssertEqual(extractedData?.count, pcmData.count, "Data size should match")
    }
  }

  // MARK: - Test: Verify Format

  func testVerifyFormat() throws {
    // Arrange: Create test sample buffer
    guard let sampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 48000,
      channels: 2,
      bitsPerChannel: 16,
      durationSeconds: 0.1
    ) else {
      XCTFail("Failed to create test sample buffer")
      return
    }

    // Act & Assert: Verify with correct format
    XCTAssertTrue(
      AudioSampleBufferUtils.verifyFormat(
        sampleBuffer,
        expectedSampleRate: 48000,
        expectedChannels: 2,
        expectedBitsPerChannel: 16
      ),
      "Format verification should succeed with matching parameters"
    )

    // Act & Assert: Verify with incorrect sample rate
    XCTAssertFalse(
      AudioSampleBufferUtils.verifyFormat(
        sampleBuffer,
        expectedSampleRate: 44100,
        expectedChannels: 2,
        expectedBitsPerChannel: 16
      ),
      "Format verification should fail with wrong sample rate"
    )

    // Act & Assert: Verify with incorrect channels
    XCTAssertFalse(
      AudioSampleBufferUtils.verifyFormat(
        sampleBuffer,
        expectedSampleRate: 48000,
        expectedChannels: 1,
        expectedBitsPerChannel: 16
      ),
      "Format verification should fail with wrong channels"
    )

    // Act & Assert: Verify with incorrect bits per channel
    XCTAssertFalse(
      AudioSampleBufferUtils.verifyFormat(
        sampleBuffer,
        expectedSampleRate: 48000,
        expectedChannels: 2,
        expectedBitsPerChannel: 24
      ),
      "Format verification should fail with wrong bits per channel"
    )
  }
}

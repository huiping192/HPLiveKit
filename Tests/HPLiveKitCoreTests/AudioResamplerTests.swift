//
//  AudioResamplerTests.swift
//  HPLiveKitTests
//
//  Comprehensive test suite for AudioResampler
//

import XCTest
import CoreMedia
import AudioToolbox
@testable import HPLiveKit

final class AudioResamplerTests: XCTestCase {

  // MARK: - Test: Pass-through (No Conversion)

  func testPassThrough_SameFormat() async throws {
    // Arrange: Create resampler with 48kHz, stereo, 16-bit
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    // Create sample buffer matching target format
    guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 48000,
      channels: 2,
      bitsPerChannel: 16,
      durationSeconds: 0.1
    ) else {
      XCTFail("Failed to create input sample buffer")
      return
    }

    let inputBox = SampleBufferBox(samplebuffer: inputSampleBuffer)

    // Act: Resample
    let result = await resampler.resample(inputBox)

    // Assert: Should return original buffer (no conversion)
    XCTAssertNotNil(result, "Result should not be nil")

    if let outputSampleBuffer = result?.samplebuffer {
      // Verify format matches
      XCTAssertTrue(
        AudioSampleBufferUtils.verifyFormat(
          outputSampleBuffer,
          expectedSampleRate: 48000,
          expectedChannels: 2,
          expectedBitsPerChannel: 16
        ),
        "Output format should match target format"
      )

      // For pass-through, output should be identical to input
      let inputData = AudioSampleBufferUtils.extractPCMData(from: inputSampleBuffer)
      let outputData = AudioSampleBufferUtils.extractPCMData(from: outputSampleBuffer)
      XCTAssertEqual(inputData, outputData, "Pass-through should preserve data exactly")
    }
  }

  // MARK: - Test: Sample Rate Conversion

  func testSampleRateConversion_44100_to_48000() async throws {
    // Arrange: Create resampler targeting 48kHz
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    // Create 44.1kHz input
    guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 44100,
      channels: 2,
      bitsPerChannel: 16,
      durationSeconds: 0.1
    ) else {
      XCTFail("Failed to create input sample buffer")
      return
    }

    let inputBox = SampleBufferBox(samplebuffer: inputSampleBuffer)

    // Act: Resample
    let result = await resampler.resample(inputBox)

    // Assert
    XCTAssertNotNil(result, "Resampling should succeed")

    if let outputSampleBuffer = result?.samplebuffer {
      // Verify output format
      XCTAssertTrue(
        AudioSampleBufferUtils.verifyFormat(
          outputSampleBuffer,
          expectedSampleRate: 48000,
          expectedChannels: 2,
          expectedBitsPerChannel: 16
        ),
        "Output should be 48kHz stereo 16-bit"
      )

      // Verify audio content is preserved
      XCTAssertTrue(
        AudioSampleBufferUtils.isAudioContentPreserved(
          original: inputSampleBuffer,
          resampled: outputSampleBuffer,
          tolerance: 0.15
        ),
        "Audio content should be preserved after sample rate conversion"
      )
    }
  }


  // MARK: - Test: Channel Conversion

  func testChannelConversion_Mono_to_Stereo() async throws {
    // Arrange: Convert mono to stereo
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 48000,
      channels: 1,  // Mono
      bitsPerChannel: 16,
      durationSeconds: 0.1
    ) else {
      XCTFail("Failed to create mono input sample buffer")
      return
    }

    let inputBox = SampleBufferBox(samplebuffer: inputSampleBuffer)

    // Act
    let result = await resampler.resample(inputBox)

    // Assert
    XCTAssertNotNil(result, "Mono to stereo conversion should succeed")

    if let outputSampleBuffer = result?.samplebuffer {
      XCTAssertTrue(
        AudioSampleBufferUtils.verifyFormat(
          outputSampleBuffer,
          expectedSampleRate: 48000,
          expectedChannels: 2,  // Stereo
          expectedBitsPerChannel: 16
        ),
        "Output should be stereo"
      )
    }
  }

  func testChannelConversion_Stereo_to_Mono() async throws {
    // Arrange: Convert stereo to mono
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 1, targetBitsPerChannel: 16)

    guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 48000,
      channels: 2,  // Stereo
      bitsPerChannel: 16,
      durationSeconds: 0.1
    ) else {
      XCTFail("Failed to create stereo input sample buffer")
      return
    }

    let inputBox = SampleBufferBox(samplebuffer: inputSampleBuffer)

    // Act
    let result = await resampler.resample(inputBox)

    // Assert
    XCTAssertNotNil(result, "Stereo to mono conversion should succeed")

    if let outputSampleBuffer = result?.samplebuffer {
      XCTAssertTrue(
        AudioSampleBufferUtils.verifyFormat(
          outputSampleBuffer,
          expectedSampleRate: 48000,
          expectedChannels: 1,  // Mono
          expectedBitsPerChannel: 16
        ),
        "Output should be mono"
      )
    }
  }

  // MARK: - Test: Combined Conversions

  func testCombinedConversion_SampleRate_and_Channels() async throws {
    // Arrange: Convert 44.1kHz mono to 48kHz stereo
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 44100,
      channels: 1,
      bitsPerChannel: 16,
      durationSeconds: 0.1
    ) else {
      XCTFail("Failed to create input sample buffer")
      return
    }

    let inputBox = SampleBufferBox(samplebuffer: inputSampleBuffer)

    // Act
    let result = await resampler.resample(inputBox)

    // Assert
    XCTAssertNotNil(result, "Combined conversion should succeed")

    if let outputSampleBuffer = result?.samplebuffer {
      XCTAssertTrue(
        AudioSampleBufferUtils.verifyFormat(
          outputSampleBuffer,
          expectedSampleRate: 48000,
          expectedChannels: 2,
          expectedBitsPerChannel: 16
        ),
        "Output should be 48kHz stereo 16-bit"
      )
    }
  }

  // MARK: - Test: Multiple Consecutive Conversions

  func testMultipleConsecutiveConversions() async throws {
    // Arrange: Test that converter can handle multiple buffers in sequence
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    // Act & Assert: Process 10 consecutive buffers
    for i in 0..<10 {
      guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
        sampleRate: 44100,
        channels: 2,
        bitsPerChannel: 16,
        durationSeconds: 0.05,
        frequency: 440.0 + Double(i * 10)  // Vary frequency
      ) else {
        XCTFail("Failed to create input sample buffer \(i)")
        return
      }

      let inputBox = SampleBufferBox(samplebuffer: inputSampleBuffer)
      let result = await resampler.resample(inputBox)

      XCTAssertNotNil(result, "Conversion \(i) should succeed")

      if let outputSampleBuffer = result?.samplebuffer {
        XCTAssertTrue(
          AudioSampleBufferUtils.verifyFormat(
            outputSampleBuffer,
            expectedSampleRate: 48000,
            expectedChannels: 2,
            expectedBitsPerChannel: 16
          ),
          "Output \(i) should have correct format"
        )
      }
    }
  }

  // MARK: - Test: Format Changes

  func testFormatChange_ConverterRecreation() async throws {
    // Arrange: Test that converter handles format changes
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    // First: Process 44.1kHz stereo
    guard let input1 = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 44100,
      channels: 2,
      bitsPerChannel: 16
    ) else {
      XCTFail("Failed to create first input")
      return
    }

    let result1 = await resampler.resample(SampleBufferBox(samplebuffer: input1))
    XCTAssertNotNil(result1, "First conversion should succeed")

    // Second: Process 16kHz mono (different format)
    guard let input2 = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 16000,
      channels: 1,
      bitsPerChannel: 16
    ) else {
      XCTFail("Failed to create second input")
      return
    }

    let result2 = await resampler.resample(SampleBufferBox(samplebuffer: input2))
    XCTAssertNotNil(result2, "Second conversion with different format should succeed")

    // Third: Back to 44.1kHz stereo
    guard let input3 = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 44100,
      channels: 2,
      bitsPerChannel: 16
    ) else {
      XCTFail("Failed to create third input")
      return
    }

    let result3 = await resampler.resample(SampleBufferBox(samplebuffer: input3))
    XCTAssertNotNil(result3, "Third conversion should succeed")
  }

  // MARK: - Test: Timestamp Preservation

  func testTimestampPreservation() async throws {
    // Arrange
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 44100,
      channels: 2,
      bitsPerChannel: 16
    ) else {
      XCTFail("Failed to create input sample buffer")
      return
    }

    let inputBox = SampleBufferBox(samplebuffer: inputSampleBuffer)
    let inputTimestamp = CMSampleBufferGetPresentationTimeStamp(inputSampleBuffer)

    // Act
    let result = await resampler.resample(inputBox)

    // Assert: Timestamp should be preserved
    XCTAssertNotNil(result)
    if let outputSampleBuffer = result?.samplebuffer {
      let outputTimestamp = CMSampleBufferGetPresentationTimeStamp(outputSampleBuffer)
      XCTAssertEqual(
        inputTimestamp.seconds,
        outputTimestamp.seconds,
        accuracy: 0.0001,
        "Timestamp should be preserved"
      )
    }
  }

  // MARK: - Test: Stop and Cleanup

  func testStopAndCleanup() async throws {
    // Arrange
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 44100,
      channels: 2,
      bitsPerChannel: 16
    ) else {
      XCTFail("Failed to create input sample buffer")
      return
    }

    // Process one buffer
    let result1 = await resampler.resample(SampleBufferBox(samplebuffer: inputSampleBuffer))
    XCTAssertNotNil(result1, "First conversion should succeed")

    // Act: Stop resampler
    await resampler.stop()

    // Process another buffer after stop (should recreate converter)
    let result2 = await resampler.resample(SampleBufferBox(samplebuffer: inputSampleBuffer))
    XCTAssertNotNil(result2, "Conversion after stop should still work")
  }

  // MARK: - Test: Concurrent Access (Actor Safety)

  func testConcurrentAccess() async throws {
    // Arrange: Test that actor isolation prevents data races
    let resampler = AudioResampler(targetSampleRate: 48000, targetChannels: 2, targetBitsPerChannel: 16)

    guard let inputSampleBuffer = AudioResamplerTestHelpers.createTestSampleBuffer(
      sampleRate: 44100,
      channels: 2,
      bitsPerChannel: 16
    ) else {
      XCTFail("Failed to create input sample buffer")
      return
    }

    let inputBox = SampleBufferBox(samplebuffer: inputSampleBuffer)

    // Act: Call resample from multiple tasks concurrently
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<10 {
        group.addTask {
          let result = await resampler.resample(inputBox)
          return result != nil
        }
      }

      // Assert: All conversions should succeed
      var successCount = 0
      for await success in group {
        if success {
          successCount += 1
        }
      }

      XCTAssertEqual(successCount, 10, "All concurrent conversions should succeed")
    }
  }


}

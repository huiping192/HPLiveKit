import Foundation
import CoreMedia
import AudioToolbox
import AVFoundation
import os

actor AudioResampler {
  private static let logger = Logger(subsystem: "com.hplivekit", category: "AudioResampler")

  private let targetSampleRate: Double
  private let targetChannels: UInt32
  private let targetBitsPerChannel: UInt32

  // Wrapper for automatic AudioConverter cleanup on deallocation
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

  private var sourceSampleRate: Double = 0
  private var sourceChannels: UInt32 = 0
  private var sourceBitsPerChannel: UInt32 = 0

  private var cachedTargetFormat: AudioStreamBasicDescription?
  private var cachedFormatDescription: CMAudioFormatDescription?

  init(targetSampleRate: Double, targetChannels: UInt32, targetBitsPerChannel: UInt32) {
    self.targetSampleRate = targetSampleRate
    self.targetChannels = targetChannels
    self.targetBitsPerChannel = targetBitsPerChannel
  }

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
  
  func resample(_ sampleBufferBox: SampleBufferBox) -> SampleBufferBox? {
    let sampleBuffer = sampleBufferBox.samplebuffer

    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      Self.logger.error("Cannot get format description")
      return nil
    }

    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
      Self.logger.error("Cannot get audio stream basic description")
      return nil
    }
    let needsResampling = asbd.mSampleRate != targetSampleRate ||
    asbd.mChannelsPerFrame != targetChannels ||
    asbd.mBitsPerChannel != targetBitsPerChannel

    if !needsResampling {
      return sampleBufferBox
    }

    if !setupConverterIfNeeded(sourceFormat: asbd) {
      Self.logger.error("Failed to setup audio converter")
      return nil
    }

    guard let audioData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer) else {
      Self.logger.error("Failed to extract audio data")
      return nil
    }

    guard let convertedData = convert(audioData: audioData, sourceFormat: asbd) else {
      Self.logger.error("Failed to convert audio data")
      return nil
    }

    guard let newSampleBuffer = createSampleBuffer(from: convertedData,
                                                     timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else {
      return nil
    }

    return SampleBufferBox(samplebuffer: newSampleBuffer)
  }
  
  private func setupConverterIfNeeded(sourceFormat: AudioStreamBasicDescription) -> Bool {
    if sourceSampleRate == sourceFormat.mSampleRate &&
        sourceChannels == sourceFormat.mChannelsPerFrame &&
        sourceBitsPerChannel == sourceFormat.mBitsPerChannel,
       converter != nil {
      return true
    }

    if let oldConverter = converter {
      AudioConverterDispose(oldConverter)
      converter = nil
    }

    sourceSampleRate = sourceFormat.mSampleRate
    sourceChannels = sourceFormat.mChannelsPerFrame
    sourceBitsPerChannel = sourceFormat.mBitsPerChannel

    var inputFormat = sourceFormat
    var outputFormat = targetFormat

    var status = AudioConverterNew(&inputFormat, &outputFormat, &converter)
    if status != noErr {
      Self.logger.error("AudioConverterNew failed: \(status, privacy: .public)")
      return false
    }

    // Use MAX quality for best audio quality, especially important for upsampling (e.g., 44.1kHz -> 48kHz)
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
    }

    Self.logger.info("Audio converter created - Input: \(sourceFormat.mSampleRate, privacy: .public)Hz \(sourceFormat.mChannelsPerFrame, privacy: .public)ch \(sourceFormat.mBitsPerChannel, privacy: .public)bit -> Output: \(self.targetSampleRate, privacy: .public)Hz \(self.targetChannels, privacy: .public)ch \(self.targetBitsPerChannel, privacy: .public)bit")

    return true
  }

  private func convert(audioData: Data, sourceFormat: AudioStreamBasicDescription) -> Data? {
    guard let converter = converter else { return nil }

    // Use 1.5x margin for safety: AudioConverter may need extra space for sample rate conversion artifacts
    let sourceFrames = audioData.count / Int(sourceFormat.mBytesPerFrame)
    let targetFrames = Int(Double(sourceFrames) * targetSampleRate / sourceFormat.mSampleRate)
    let outputBytesPerFrame = Int(targetBitsPerChannel / 8 * targetChannels)
    let outputSize = Int(Double(targetFrames * outputBytesPerFrame) * 1.5)

    var outputData = Data(count: outputSize)

    let inputDataCopy = audioData
    let sourceFormatCopy = sourceFormat

    // Callback supports multiple reads - AudioConverter may request data in chunks
    let result: (status: OSStatus, actualSize: Int) = inputDataCopy.withUnsafeBytes { inputBytes in
      outputData.withUnsafeMutableBytes { outputBytes in
        guard let inputBaseAddress = inputBytes.baseAddress,
              let outputBaseAddress = outputBytes.baseAddress else {
          return (kAudioConverterErr_InvalidInputSize, 0)
        }

        var outBufferList = AudioBufferList()
        outBufferList.mNumberBuffers = 1
        outBufferList.mBuffers.mNumberChannels = targetChannels
        outBufferList.mBuffers.mDataByteSize = UInt32(outputSize)
        outBufferList.mBuffers.mData = outputBaseAddress

        var ioOutputDataPacketSize = UInt32(targetFrames)

        // Track consumed frames to support multiple callback invocations
        struct CallbackState {
          let inputBaseAddress: UnsafeRawPointer
          let inputDataSize: Int
          let sourceFormat: AudioStreamBasicDescription
          var consumedFrames: Int = 0
          var callCount: Int = 0
        }

        var callbackState = CallbackState(
          inputBaseAddress: inputBaseAddress,
          inputDataSize: inputDataCopy.count,
          sourceFormat: sourceFormatCopy
        )

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

              if remainingFrames <= 0 {
                ioNumDataPackets.pointee = 0
                return noErr
              }

              let framesToProvide = min(remainingFrames, Int(ioNumDataPackets.pointee))
              let bytesToProvide = framesToProvide * bytesPerFrame
              let offsetBytes = state.pointee.consumedFrames * bytesPerFrame

              var inBufferList = AudioBufferList()
              inBufferList.mNumberBuffers = 1
              inBufferList.mBuffers.mNumberChannels = state.pointee.sourceFormat.mChannelsPerFrame
              inBufferList.mBuffers.mDataByteSize = UInt32(bytesToProvide)
              inBufferList.mBuffers.mData = UnsafeMutableRawPointer(mutating: state.pointee.inputBaseAddress.advanced(by: offsetBytes))

              ioData.pointee = inBufferList
              ioNumDataPackets.pointee = UInt32(framesToProvide)

              state.pointee.consumedFrames += framesToProvide

              return noErr
            },
            statePtr,
            &ioOutputDataPacketSize,
            &outBufferList,
            nil
          )
        }

        let actualFramesWritten = Int(ioOutputDataPacketSize)
        let actualBytesWritten = actualFramesWritten * outputBytesPerFrame

        return (status, actualBytesWritten)
      }
    }

    guard result.status == noErr else {
      Self.logger.error("AudioConverterFillComplexBuffer failed: \(result.status, privacy: .public)")
      return nil
    }

    outputData.count = result.actualSize

    return outputData
  }

  private func createSampleBuffer(from data: Data, timestamp: CMTime) -> CMSampleBuffer? {
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

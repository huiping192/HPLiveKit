//
//  LiveAudioAACEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
@preconcurrency import AudioToolbox
@preconcurrency import AVFoundation
import HPRTMP
import os

/// Audio AAC encoder using Swift 6 Actor for thread safety
/// Input: CMSampleBuffer via encode() method (non-blocking)
/// Output: AudioFrame via AsyncStream
actor LiveAudioAACEncoder: AudioEncoder {
  private static let logger = Logger(subsystem: "com.hplivekit", category: "AudioAACEncoder")

  // MARK: - AsyncStream for Input/Output

  /// Input stream: receives CMSampleBuffer from external callers
  private let inputStream: AsyncStream<SampleBufferBox>
  /// Input continuation must be nonisolated(unsafe) because CMSampleBuffer is not Sendable
  /// but we need to yield from nonisolated encode() method
  private let inputContinuation: AsyncStream<SampleBufferBox>.Continuation

  /// Output stream: delivers encoded AudioFrame to subscribers
  private let _outputStream: AsyncStream<AudioFrame>
  /// Output continuation is nonisolated(unsafe) to allow yielding from async context
  private let outputContinuation: AsyncStream<AudioFrame>.Continuation

  /// Public read-only access to output stream
  nonisolated var outputStream: AsyncStream<AudioFrame> {
    _outputStream
  }

  // MARK: - Actor-Isolated State (Thread-Safe)

  private let configuration: LiveAudioConfiguration

  private var converter: AudioConverterRef?
  private var outFormatDescription: CMFormatDescription?

  /// Buffer to accumulate input audio data before encoding
  private var inputDataBuffer = Data()

  private var audioHeader: Data?
  private var aacHeader: Data?

  // Track actual audio format from input sample buffer
  private var actualChannels: UInt32 = 0
  private var actualSampleRate: Double = 0
  private var actualBitsPerChannel: UInt32 = 16

  // Track timestamp for accumulated buffer
  private var inputBufferStartTimestamp: CMTime?

  // Track number of frames encoded from current buffer
  private var encodedFrameCountInBuffer: Int = 0

  /// Processing task that consumes input stream and performs encoding
  /// Must be nonisolated(unsafe) to allow assignment in init
  nonisolated(unsafe) private var processingTask: Task<Void, Never>?

  // Calculate buffer length based on actual audio format
  // AAC frame size is 1024 samples: 1024 samples * (bits/8) bytes/sample * channels
  private var bufferLength: Int {
    return 1024 * Int(actualBitsPerChannel / 8) * Int(actualChannels)
  }

  // MARK: - Initialization

  init(configuration: LiveAudioConfiguration) {
    self.configuration = configuration

    // Create input stream
    (self.inputStream, self.inputContinuation) = AsyncStream.makeStream()

    // Create output stream
    (self._outputStream, self.outputContinuation) = AsyncStream.makeStream()

    // Start processing task (cannot access self.processingTask in nonisolated init)
    let task: Task<Void, Never> = Task { [weak self] in
      await self?.processEncodingLoop()
    }
    self.processingTask = task
  }

  // MARK: - Public API

  /// Encodes an audio sample buffer (non-blocking, returns immediately)
  /// The sample buffer is yielded to internal processing stream
  nonisolated func encode(sampleBuffer: SampleBufferBox) {
    inputContinuation.yield(sampleBuffer)
  }

  /// Stops the encoder and finishes all streams
  func stop() {
    // Cancel processing task
    processingTask?.cancel()

    // Finish streams
    inputContinuation.finish()
    outputContinuation.finish()

    // Clean up resources
    converter = nil
    inputDataBuffer = Data()

    audioHeader = nil
    aacHeader = nil

    actualChannels = 0
    actualSampleRate = 0
    actualBitsPerChannel = 16

    inputBufferStartTimestamp = nil
    encodedFrameCountInBuffer = 0
  }

  // MARK: - Private Processing Loop

  /// Main encoding loop that processes sample buffers from input stream
  private func processEncodingLoop() async {
    for await sampleBuffer in inputStream {
      await encodeSampleBuffer(sampleBuffer)
    }
  }

  /// Encodes a single sample buffer
  private func encodeSampleBuffer(_ sampleBufferBox: SampleBufferBox) async {
    do {
      let sampleBuffer = sampleBufferBox.samplebuffer
      try setupEncoder(sb: sampleBuffer)
      guard let audioData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer) else {
        Self.logger.error("Failed to extract PCM data from sample buffer")
        return
      }
      let currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

      // If buffer is empty, record the start timestamp and reset frame count
      if inputDataBuffer.isEmpty {
        inputBufferStartTimestamp = currentTimestamp
        encodedFrameCountInBuffer = 0
      }

      inputDataBuffer.append(audioData)

      // Calculate frame duration: 1024 samples / sample rate
      let frameDurationInSeconds = 1024.0 / actualSampleRate

      // Encode as many full frames as possible
      while inputDataBuffer.count >= self.bufferLength {
        guard let startTimestamp = inputBufferStartTimestamp else {
          Self.logger.error("inputBufferStartTimestamp is nil")
          break
        }

        // Calculate current frame's timestamp based on start timestamp + frame index
        // This approach is more accurate and handles timestamp jumps better
        let frameTimestamp = CMTimeAdd(
          startTimestamp,
          CMTime(seconds: Double(encodedFrameCountInBuffer) * frameDurationInSeconds,
                 preferredTimescale: 1000000)
        )

        let frameData = inputDataBuffer.prefix(bufferLength)

        // Encode and yield to output stream
        if let audioFrame = encodeBuffer(audioData: Data(frameData), timestamp: frameTimestamp) {
          outputContinuation.yield(audioFrame)
        }

        // Increment frame count for next iteration
        encodedFrameCountInBuffer += 1

        // Remove encoded data
        inputDataBuffer.removeFirst(bufferLength)
      }

      // Reset timestamp tracking when buffer is empty (allows new input to set new timestamp)
      if inputDataBuffer.isEmpty {
        inputBufferStartTimestamp = nil
        encodedFrameCountInBuffer = 0
      }
    } catch {
      Self.logger.error("Encoding failed: \(error.localizedDescription)")
    }
  }

  /// Encodes a buffer of audio data and returns the encoded AudioFrame
  /// Returns nil if encoding fails
  private func encodeBuffer(audioData: Data, timestamp: CMTime) -> AudioFrame? {
    guard let converter = converter else {
      return nil
    }
    var inBuffer = AudioBuffer()
    inBuffer.mNumberChannels = actualChannels  // Use actual channels instead of hardcoded 1
    audioData.withUnsafeBytes { bytes in
      inBuffer.mData = UnsafeMutableRawPointer(mutating: bytes.baseAddress!)
    }
    inBuffer.mDataByteSize = UInt32(audioData.count)

    var inBufferList = AudioBufferList()
    inBufferList.mNumberBuffers = 1
    inBufferList.mBuffers = inBuffer

    // Initialize output buffer list
    var outputData = Data(count: Int(inBuffer.mDataByteSize))
    var outBufferList = AudioBufferList()
    outBufferList.mNumberBuffers = 1
    outBufferList.mBuffers.mNumberChannels = inBuffer.mNumberChannels
    outBufferList.mBuffers.mDataByteSize = inBuffer.mDataByteSize
    outputData.withUnsafeMutableBytes { bytes in
      outBufferList.mBuffers.mData = bytes.baseAddress
    }

    var outputDataPacketSize = UInt32(1)
    let status = AudioConverterFillComplexBuffer(converter, inputDataProc, &inBufferList, &outputDataPacketSize, &outBufferList, nil)
    if status != noErr {
      Self.logger.error("AudioConverterFillComplexBuffer failed with status: \(status)")
      return nil
    }

    // Check if encoder actually produced packets
    if outputDataPacketSize == 0 {
      Self.logger.warning("No packets encoded, skipping frame")
      return nil
    }

    // Get actual encoded data size from output buffer
    let actualOutputSize = Int(outBufferList.mBuffers.mDataByteSize)
    let actualEncodedData = Data(outputData.prefix(actualOutputSize))

    let compressionRatio = Double(audioData.count) / Double(actualOutputSize)
    Self.logger.debug("Encoded audio frame - Timestamp: \(timestamp.seconds)s, Input: \(audioData.count) bytes, Output: \(actualOutputSize) bytes, Ratio: \(String(format: "%.1f", compressionRatio)):1")

    // Check if this might be ADTS format
    if actualEncodedData.count >= 2 {
      let byte0 = actualEncodedData[0]
      let byte1 = actualEncodedData[1]
      if byte0 == 0xFF && (byte1 & 0xF0) == 0xF0 {
        Self.logger.warning("Encoded data looks like ADTS AAC (has sync word 0xFF Fx). RTMP expects Raw AAC, not ADTS!")
      }
    }

    return AudioFrame(timestamp: UInt64(timestamp.seconds * 1000), data: actualEncodedData, header: audioHeader, aacHeader: aacHeader)
  }

  /// Input data callback for AudioConverter
  private let inputDataProc: AudioConverterComplexInputDataProc = { (
    audioConverter,
    ioNumDataPackets,
    ioData,
    ioPacketDesc,
    inUserData ) -> OSStatus in

    guard let bufferList = inUserData?.assumingMemoryBound(to: AudioBufferList.self).pointee else {
      return noErr
    }

    let dataPtr = UnsafeMutableAudioBufferListPointer(ioData)
    dataPtr[0].mNumberChannels = bufferList.mBuffers.mNumberChannels
    dataPtr[0].mData = bufferList.mBuffers.mData
    dataPtr[0].mDataByteSize = bufferList.mBuffers.mDataByteSize

    return noErr
  }

  // MARK: - Encoder Setup

  private func setupEncoder(sb: CMSampleBuffer) throws {
    guard converter == nil else { return }

    try createAudioConvertIfNeeded(sb: sb)

    setupHeaderData()

    setupBitrate()
  }

  private func setupHeaderData() {
    guard let outFormatDescription else { return }
    self.aacHeader = getAacHeader(outFormatDescription: outFormatDescription)
    self.audioHeader = getAudioHeader(outFormatDescription: outFormatDescription)
  }

  private func createAudioConvertIfNeeded(sb: CMSampleBuffer) throws {
    // Get audio format description
    guard let formatDescription = CMSampleBufferGetFormatDescription(sb) else {
      Self.logger.error("Cannot get audio format description")
      throw LiveError.audioFormatDescriptionMissing
    }

    // Get audio stream basic description (ASBD)
    let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)!.pointee

    // Get sample rate
    let sampleRate = audioStreamBasicDescription.mSampleRate

    // Get number of channels
    let channels = audioStreamBasicDescription.mChannelsPerFrame

    // Get bits per channel
    let bitsPerChannel = audioStreamBasicDescription.mBitsPerChannel

    // Check if format has changed
    if converter != nil {
      if actualSampleRate != sampleRate || actualChannels != channels || actualBitsPerChannel != bitsPerChannel {
        Self.logger.warning("Audio format changed - Previous: \(self.actualSampleRate) Hz, \(self.actualChannels) channels, \(self.actualBitsPerChannel) bits, New: \(sampleRate) Hz, \(channels) channels, \(bitsPerChannel) bits. Reinitializing encoder.")
        // Reset converter to reinitialize with new format
        converter = nil
        inputDataBuffer = Data()
        inputBufferStartTimestamp = nil
        encodedFrameCountInBuffer = 0
      } else {
        return
      }
    }

    // Save actual format parameters
    self.actualSampleRate = sampleRate
    self.actualChannels = channels
    self.actualBitsPerChannel = bitsPerChannel

    // Check bit depth compatibility (RTMP protocol limitation)
    if bitsPerChannel != 16 && bitsPerChannel != 8 {
      Self.logger.warning("⚠️ Non-standard audio bit depth: \(bitsPerChannel)-bit detected. RTMP only supports 8-bit and 16-bit. Will be mapped to 16-bit in RTMP header.")
    }

    // Copy the actual format flags from input to match byte order and other properties
    let inputFormatFlags = audioStreamBasicDescription.mFormatFlags

    let isBigEndian = (inputFormatFlags & kAudioFormatFlagIsBigEndian) != 0
    let isNonInterleaved = (inputFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    Self.logger.debug("Initializing encoder - Sample Rate: \(sampleRate) Hz, Channels: \(channels), Bits Per Channel: \(bitsPerChannel), Flags: 0x\(String(format: "%X", inputFormatFlags)), Byte Order: \(isBigEndian ? "Big-Endian" : "Little-Endian"), Interleaved: \(!isNonInterleaved), Buffer Length: \(self.bufferLength) bytes")

    var inputFormat = AudioStreamBasicDescription()
    inputFormat.mSampleRate = sampleRate
    inputFormat.mFormatID = kAudioFormatLinearPCM
    // Use actual input format flags instead of hardcoded values to match byte order
    inputFormat.mFormatFlags = inputFormatFlags
    inputFormat.mChannelsPerFrame = channels
    inputFormat.mFramesPerPacket = 1
    inputFormat.mBitsPerChannel = bitsPerChannel
    inputFormat.mBytesPerFrame = inputFormat.mBitsPerChannel / 8 * inputFormat.mChannelsPerFrame
    inputFormat.mBytesPerPacket = inputFormat.mBytesPerFrame * inputFormat.mFramesPerPacket

    // Output audio format
    var outputFormat = AudioStreamBasicDescription()
    outputFormat.mSampleRate = inputFormat.mSampleRate // Keep same sample rate
    outputFormat.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
    outputFormat.mFormatID = kAudioFormatMPEG4AAC // AAC encoding
    outputFormat.mChannelsPerFrame = channels
    outputFormat.mFramesPerPacket = 1024 // AAC frame size: 1024 samples per frame
    var outFormatDescription: CMFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &outputFormat, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &outFormatDescription)
    self.outFormatDescription = outFormatDescription


    // Hardware encoder and software encoder
    // Audio default is software encoder
    let subtype = kAudioFormatMPEG4AAC
    let requestedCodecs: [AudioClassDescription] = [
      .init(
        mType: kAudioEncoderComponentType,
        mSubType: subtype,
        mManufacturer: kAppleSoftwareAudioCodecManufacturer),
      .init(
        mType: kAudioEncoderComponentType,
        mSubType: subtype,
        mManufacturer: kAppleHardwareAudioCodecManufacturer)
    ]

    let result = AudioConverterNewSpecific(&inputFormat, &outputFormat, 2, requestedCodecs, &converter)
    if result != noErr {
      Self.logger.error("AudioConverterNewSpecific failed with status: \(result)")
      throw LiveError.audioConverterCreationFailed(result)
    }

    guard converter != nil else {
      Self.logger.error("Audio converter is nil after creation")
      throw LiveError.audioConverterCreationFailed(result)
    }
  }

  private func setupBitrate() {
    guard let converter else { return }
    var outputBitrate = UInt32(configuration.audioBitRate.rawValue)
    let propSize = MemoryLayout<UInt32>.size

    let setPropertyresult = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(propSize), &outputBitrate)

    if setPropertyresult != noErr {
      return
    }
  }

  private func getAudioHeader(outFormatDescription: CMFormatDescription) -> Data? {
    guard let streamBasicDesc = AudioSampleBufferUtils.extractFormat(from: outFormatDescription),
          let mp4Id = MPEG4ObjectID(rawValue: Int(streamBasicDesc.mFormatFlags)) else {
      return nil
    }
    var descData = Data()
    let config = AudioSpecificConfig(objectType: mp4Id,
                                     channelConfig: ChannelConfigType(rawValue: UInt8(streamBasicDesc.mChannelsPerFrame)),
                                     frequencyType: SampleFrequencyType(value: streamBasicDesc.mSampleRate))

    descData.append(aacHeader!)
    descData.write(AudioData.AACPacketType.header.rawValue)
    descData.append(config.encodeData)

    Self.logger.debug("Audio Header constructed - ObjectType: \(mp4Id.rawValue), Channels: \(streamBasicDesc.mChannelsPerFrame), Sample Rate: \(streamBasicDesc.mSampleRate)")

    return descData
  }

  /*
   Sound format: a 4-bit field that indicates the audio format, such as AAC or MP3.
   Sound rate: a 2-bit field that indicates the audio sample rate, such as 44.1 kHz or 48 kHz.
   Sound size: a 1-bit field that indicates the audio sample size, such as 16-bit or 8-bit.
   Sound type: a 1-bit field that indicates the audio channel configuration, such as stereo or mono.
   */
  private func getAacHeader(outFormatDescription: CMFormatDescription) -> Data? {
    guard let streamBasicDesc = AudioSampleBufferUtils.extractFormat(from: outFormatDescription) else {
      return nil
    }

    // Determine sound type based on actual number of channels
    let soundType: AudioData.SoundType = streamBasicDesc.mChannelsPerFrame == 1 ? .sndMono : .sndStereo

    // Determine sound size based on actual bit depth
    // RTMP only supports 8-bit and 16-bit, other bit depths are mapped to 16-bit
    let soundSize: AudioData.SoundSize = actualBitsPerChannel <= 8 ? .snd8Bit : .snd16Bit

    let value = (AudioData.SoundFormat.aac.rawValue << 4 |
                 AudioData.SoundRate(value: streamBasicDesc.mSampleRate).rawValue << 2 |
                 soundSize.rawValue << 1 |
                 soundType.rawValue)

    Self.logger.debug("AAC Header - Format: AAC, Sample Rate: \(streamBasicDesc.mSampleRate) Hz, Channels: \(streamBasicDesc.mChannelsPerFrame) (\(soundType == .sndMono ? "mono" : "stereo")), Bits: \(self.actualBitsPerChannel) (SoundSize: \(soundSize == .snd8Bit ? "8-bit" : "16-bit")), Header byte: 0x\(String(format: "%02X", value))")

    return Data([UInt8(value)])
  }

}

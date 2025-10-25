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
import NIOCore
import NIOFoundationCompat
import os

actor LiveAudioAACEncoder: AudioEncoder {
  private static let logger = Logger(subsystem: "com.hplivekit", category: "AudioAACEncoder")

  // MARK: - AsyncStream Properties

  private let inputStream: AsyncStream<SampleBufferBox>
  private let inputContinuation: AsyncStream<SampleBufferBox>.Continuation

  private let _outputStream: AsyncStream<AudioFrame>
  private let outputContinuation: AsyncStream<AudioFrame>.Continuation

  nonisolated var outputStream: AsyncStream<AudioFrame> {
    _outputStream
  }

  // MARK: - Configuration

  private let configuration: LiveAudioConfiguration

  // MARK: - AudioConverter State

  private var converter: AudioConverterRef?
  private var outFormatDescription: CMFormatDescription?

  private var actualChannels: UInt32 = 0
  private var actualSampleRate: Double = 0
  private var actualBitsPerChannel: UInt32 = 16

  // MARK: - PCM Buffer State

  private var pcmDataBuffer = ByteBuffer()
  private var bufferStartTimestamp: CMTime?
  private var encodedFrameCount: Int = 0

  // MARK: - RTMP Headers

  private var audioHeader: Data?
  private var aacHeader: Data?

  // MARK: - Processing Task

  nonisolated(unsafe) private var processingTask: Task<Void, Never>?

  // MARK: - Computed Properties

  /// AAC-LC fixed frame size: 1024 samples per frame
  private var bytesPerFrame: Int {
    return 1024 * Int(actualBitsPerChannel / 8) * Int(actualChannels)
  }

  /// Duration of each AAC frame, used for precise timestamp calculation
  private var frameDurationInSeconds: Double {
    return 1024.0 / actualSampleRate
  }

  // MARK: - Initialization

  init(configuration: LiveAudioConfiguration) {
    self.configuration = configuration

    (self.inputStream, self.inputContinuation) = AsyncStream.makeStream()
    (self._outputStream, self.outputContinuation) = AsyncStream.makeStream()

    let task: Task<Void, Never> = Task { [weak self] in
      await self?.processEncodingLoop()
    }
    self.processingTask = task
  }

  // MARK: - Public Interface

  nonisolated func encode(sampleBuffer: SampleBufferBox) {
    inputContinuation.yield(sampleBuffer)
  }

  func stop() {
    processingTask?.cancel()
    inputContinuation.finish()
    outputContinuation.finish()

    converter = nil
    pcmDataBuffer.clear()
    audioHeader = nil
    aacHeader = nil
    actualChannels = 0
    actualSampleRate = 0
    actualBitsPerChannel = 16
    bufferStartTimestamp = nil
    encodedFrameCount = 0
  }

  // MARK: - Encoding Pipeline

  private func processEncodingLoop() async {
    for await sampleBuffer in inputStream {
      await processSampleBuffer(sampleBuffer)
    }
  }

  private func processSampleBuffer(_ sampleBufferBox: SampleBufferBox) async {
    do {
      let sampleBuffer = sampleBufferBox.samplebuffer
      try setupConverterIfNeeded(sampleBuffer: sampleBuffer)

      guard let audioData = AudioSampleBufferUtils.extractPCMData(from: sampleBuffer) else {
        Self.logger.error("Failed to extract PCM data from sample buffer")
        return
      }

      let currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      appendPCMData(audioData, timestamp: currentTimestamp)

      try await encodeBufferedFrames()
    } catch {
      Self.logger.error("Encoding failed: \(error.localizedDescription)")
    }
  }

  // MARK: - PCM Buffer Management

  /// Accumulate PCM data until we have enough for a complete AAC frame
  /// AAC requires exactly 1024 samples per frame, but input CMSampleBuffer may contain arbitrary sample counts
  private func appendPCMData(_ data: Data, timestamp: CMTime) {
    if pcmDataBuffer.readableBytes == 0 {
      bufferStartTimestamp = timestamp
      encodedFrameCount = 0
    }
    pcmDataBuffer.writeBytes(data)
  }

  /// Extract and encode complete AAC frames from the buffer
  /// Uses a while loop because one CMSampleBuffer may contain data for multiple AAC frames
  private func encodeBufferedFrames() async throws {
    while pcmDataBuffer.readableBytes >= bytesPerFrame {
      guard let startTimestamp = bufferStartTimestamp else {
        Self.logger.error("bufferStartTimestamp is nil")
        break
      }

      let frameTimestamp = calculateFrameTimestamp(
        bufferStart: startTimestamp,
        frameIndex: encodedFrameCount
      )

      guard let frameData = pcmDataBuffer.readData(length: bytesPerFrame) else {
        Self.logger.error("Failed to read data from ByteBuffer")
        break
      }

      if let audioFrame = encodeAACFrame(pcmData: frameData, timestamp: frameTimestamp) {
        outputContinuation.yield(audioFrame)
      }

      encodedFrameCount += 1
    }

    pcmDataBuffer.discardReadBytes()

    if pcmDataBuffer.readableBytes == 0 {
      bufferStartTimestamp = nil
      encodedFrameCount = 0
    }
  }

  // MARK: - Timestamp Calculation

  /// Calculate precise timestamp for each AAC frame
  /// Uses buffer start time + frame index * frame duration instead of current CMSampleBuffer timestamp
  /// This prevents timestamp drift caused by irregular input audio data
  private func calculateFrameTimestamp(bufferStart: CMTime, frameIndex: Int) -> CMTime {
    return CMTimeAdd(
      bufferStart,
      CMTime(
        seconds: Double(frameIndex) * frameDurationInSeconds,
        preferredTimescale: 1000000
      )
    )
  }

  // MARK: - AAC Encoding

  private func encodeAACFrame(pcmData: Data, timestamp: CMTime) -> AudioFrame? {
    guard let converter = converter else {
      return nil
    }

    var inBuffer = AudioBuffer()
    inBuffer.mNumberChannels = actualChannels
    pcmData.withUnsafeBytes { bytes in
      inBuffer.mData = UnsafeMutableRawPointer(mutating: bytes.baseAddress!)
    }
    inBuffer.mDataByteSize = UInt32(pcmData.count)

    var inBufferList = AudioBufferList()
    inBufferList.mNumberBuffers = 1
    inBufferList.mBuffers = inBuffer

    var outputData = Data(count: Int(inBuffer.mDataByteSize))
    var outBufferList = AudioBufferList()
    outBufferList.mNumberBuffers = 1
    outBufferList.mBuffers.mNumberChannels = inBuffer.mNumberChannels
    outBufferList.mBuffers.mDataByteSize = inBuffer.mDataByteSize
    outputData.withUnsafeMutableBytes { bytes in
      outBufferList.mBuffers.mData = bytes.baseAddress
    }

    var outputDataPacketSize = UInt32(1)
    let status = AudioConverterFillComplexBuffer(
      converter,
      inputDataProc,
      &inBufferList,
      &outputDataPacketSize,
      &outBufferList,
      nil
    )

    if status != noErr {
      Self.logger.error("AudioConverterFillComplexBuffer failed with status: \(status)")
      return nil
    }

    if outputDataPacketSize == 0 {
      return nil
    }

    let actualOutputSize = Int(outBufferList.mBuffers.mDataByteSize)
    let actualEncodedData = Data(outputData.prefix(actualOutputSize))

    return AudioFrame(
      timestamp: UInt64(timestamp.seconds * 1000),
      data: actualEncodedData,
      header: audioHeader,
      aacHeader: aacHeader
    )
  }

  // MARK: - AudioConverter Callback

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

  // MARK: - Converter Management

  private func setupConverterIfNeeded(sampleBuffer: CMSampleBuffer) throws {
    guard converter == nil else { return }

    try createAudioConverter(from: sampleBuffer)
    buildRTMPHeaders()
    applyBitrateConfiguration()
  }

  private func buildRTMPHeaders() {
    guard let outFormatDescription else { return }

    self.aacHeader = RTMPAudioHeaderBuilder.buildAACHeader(
      outFormatDescription: outFormatDescription,
      actualBitsPerChannel: actualBitsPerChannel
    )

    if let aacHeader {
      self.audioHeader = RTMPAudioHeaderBuilder.buildAudioHeader(
        outFormatDescription: outFormatDescription,
        aacHeader: aacHeader
      )
    }
  }

  private func createAudioConverter(from sampleBuffer: CMSampleBuffer) throws {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      Self.logger.error("Cannot get audio format description")
      throw LiveError.audioFormatDescriptionMissing
    }

    let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)!.pointee

    let sampleRate = audioStreamBasicDescription.mSampleRate
    let channels = audioStreamBasicDescription.mChannelsPerFrame
    let bitsPerChannel = audioStreamBasicDescription.mBitsPerChannel

    if converter != nil {
      if actualSampleRate != sampleRate || actualChannels != channels || actualBitsPerChannel != bitsPerChannel {
        Self.logger.warning("Audio format changed, reinitializing encoder")
        resetConverterState()
      } else {
        return
      }
    }

    updateAudioFormat(sampleRate: sampleRate, channels: channels, bitsPerChannel: bitsPerChannel)

    var inputFormat = buildInputFormat(
      sampleRate: sampleRate,
      channels: channels,
      bitsPerChannel: bitsPerChannel,
      formatFlags: audioStreamBasicDescription.mFormatFlags
    )

    var outputFormat = buildOutputFormat(sampleRate: sampleRate, channels: channels)

    var outFormatDescription: CMFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &outputFormat,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &outFormatDescription
    )
    self.outFormatDescription = outFormatDescription

    let requestedCodecs: [AudioClassDescription] = [
      .init(
        mType: kAudioEncoderComponentType,
        mSubType: kAudioFormatMPEG4AAC,
        mManufacturer: kAppleSoftwareAudioCodecManufacturer
      ),
      .init(
        mType: kAudioEncoderComponentType,
        mSubType: kAudioFormatMPEG4AAC,
        mManufacturer: kAppleHardwareAudioCodecManufacturer
      )
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

  private func resetConverterState() {
    converter = nil
    pcmDataBuffer.clear()
    bufferStartTimestamp = nil
    encodedFrameCount = 0
  }

  private func updateAudioFormat(sampleRate: Double, channels: UInt32, bitsPerChannel: UInt32) {
    self.actualSampleRate = sampleRate
    self.actualChannels = channels
    self.actualBitsPerChannel = bitsPerChannel

    /// RTMP protocol limitation: only officially supports 8-bit and 16-bit audio
    if bitsPerChannel != 16 && bitsPerChannel != 8 {
      Self.logger.warning("Non-standard audio bit depth: \(bitsPerChannel)-bit. RTMP only supports 8/16-bit")
    }
  }

  private func buildInputFormat(
    sampleRate: Double,
    channels: UInt32,
    bitsPerChannel: UInt32,
    formatFlags: UInt32
  ) -> AudioStreamBasicDescription {
    var format = AudioStreamBasicDescription()
    format.mSampleRate = sampleRate
    format.mFormatID = kAudioFormatLinearPCM
    format.mFormatFlags = formatFlags
    format.mChannelsPerFrame = channels
    format.mFramesPerPacket = 1
    format.mBitsPerChannel = bitsPerChannel
    format.mBytesPerFrame = format.mBitsPerChannel / 8 * format.mChannelsPerFrame
    format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket
    return format
  }

  private func buildOutputFormat(
    sampleRate: Double,
    channels: UInt32
  ) -> AudioStreamBasicDescription {
    var format = AudioStreamBasicDescription()
    format.mSampleRate = sampleRate
    format.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
    format.mFormatID = kAudioFormatMPEG4AAC
    format.mChannelsPerFrame = channels
    format.mFramesPerPacket = 1024  // AAC-LC fixed frame size
    return format
  }

  private func applyBitrateConfiguration() {
    guard let converter else { return }

    var outputBitrate = UInt32(configuration.audioBitRate.rawValue)
    let propSize = MemoryLayout<UInt32>.size

    let result = AudioConverterSetProperty(
      converter,
      kAudioConverterEncodeBitRate,
      UInt32(propSize),
      &outputBitrate
    )

    if result != noErr {
      Self.logger.warning("Failed to set bitrate: \(result)")
    }
  }
}


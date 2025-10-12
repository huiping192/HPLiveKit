//
//  LiveAudioAACEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import AudioToolbox
import AVFoundation
import HPRTMP

class LiveAudioAACEncoder: AudioEncoder, @unchecked Sendable {
  
  private let configuration: LiveAudioConfiguration
  
  weak var delegate: AudioEncoderDelegate?
  
  private var converter: AudioConverterRef?
  private var outFormatDescription: CMFormatDescription?
  
  private var inputDataBuffer = Data()

  private var audioHeader: Data?
  private var aacHeader: Data?

  // Track actual audio format from input sample buffer
  private var actualChannels: UInt32 = 0
  private var actualSampleRate: Double = 0

  // Track timestamp for accumulated buffer
  private var inputBufferStartTimestamp: CMTime?

  // Track number of frames encoded from current buffer
  private var encodedFrameCountInBuffer: Int = 0

  // Track last timestamp for detecting jumps
  private var lastInputTimestamp: CMTime?
  
  required init(configuration: LiveAudioConfiguration) {
    self.configuration = configuration
    
    print("LiveAudioAACEncoder init")
  }
  
  func encode(sampleBuffer: CMSampleBuffer) {
    if !setupEncoder(sb: sampleBuffer) {
      return
    }
    let audioData = sampleBuffer.audioRawData
    let currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Check for timestamp jumps
    if let lastTS = lastInputTimestamp {
      let timeDiff = CMTimeGetSeconds(CMTimeSubtract(currentTimestamp, lastTS))
      // Use 200ms threshold to avoid false positives in screen share scenarios
      if timeDiff < 0 || timeDiff > 0.2 {
        #if DEBUG
        print("[LiveAudioAACEncoder] Warning: Timestamp jump detected!")
        print("  Previous: \(CMTimeGetSeconds(lastTS))s")
        print("  Current: \(CMTimeGetSeconds(currentTimestamp))s")
        print("  Diff: \(timeDiff * 1000)ms")
        print("  Clearing audio buffer and resetting timestamp tracking")
        #endif

        // Clear buffer and reset timestamp tracking to avoid mixing old and new data
        inputDataBuffer = Data()
        inputBufferStartTimestamp = nil
        encodedFrameCountInBuffer = 0
      }
    }
    lastInputTimestamp = currentTimestamp

    // If buffer is empty, record the start timestamp and reset frame count
    if inputDataBuffer.isEmpty {
      inputBufferStartTimestamp = currentTimestamp
      encodedFrameCountInBuffer = 0
    }

    inputDataBuffer.append(audioData)

    // Calculate frame duration: 1024 samples / sample rate
    let frameDurationInSeconds = 1024.0 / actualSampleRate

    // Encode as many full frames as possible
    while inputDataBuffer.count >= self.configuration.bufferLength {
      guard let startTimestamp = inputBufferStartTimestamp else {
        #if DEBUG
        print("[LiveAudioAACEncoder] Error: inputBufferStartTimestamp is nil")
        #endif
        break
      }

      // Calculate current frame's timestamp based on start timestamp + frame index
      // This approach is more accurate and handles timestamp jumps better
      let frameTimestamp = CMTimeAdd(
        startTimestamp,
        CMTime(seconds: Double(encodedFrameCountInBuffer) * frameDurationInSeconds,
               preferredTimescale: 1000000)
      )

      let frameData = inputDataBuffer.prefix(configuration.bufferLength)
      encodeBuffer(audioData: Data(frameData), timestamp: frameTimestamp)

      // Increment frame count for next iteration
      encodedFrameCountInBuffer += 1

      // Remove encoded data
      inputDataBuffer.removeFirst(configuration.bufferLength)
    }

    // Reset timestamp tracking when buffer is empty (allows new input to set new timestamp)
    if inputDataBuffer.isEmpty {
      inputBufferStartTimestamp = nil
      encodedFrameCountInBuffer = 0
    }
  }
  
  func stop() {
    converter = nil
    inputDataBuffer = Data()

    audioHeader = nil
    aacHeader = nil

    inputBufferStartTimestamp = nil
    encodedFrameCountInBuffer = 0
    lastInputTimestamp = nil
  }
    
  private func encodeBuffer(audioData: Data, timestamp: CMTime) {
    guard let converter = converter else {
      return
    }
    var inBuffer = AudioBuffer()
    inBuffer.mNumberChannels = actualChannels  // Use actual channels instead of hardcoded 1
    audioData.withUnsafeBytes { bytes in
      inBuffer.mData = UnsafeMutableRawPointer(mutating: bytes.baseAddress!)
    }
    inBuffer.mDataByteSize = UInt32(audioData.count)

    var inBufferList = AudioBufferList()
    inBufferList.mNumberBuffers = 1
    var buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &inBufferList.mBuffers,
                                                          count: Int(inBufferList.mNumberBuffers))
    buffers[0] = inBuffer

    // 初始化一个输出缓冲列表
    var outputData = Data(count: Int(inBuffer.mDataByteSize))
    var outBufferList = AudioBufferList()
    outBufferList.mNumberBuffers = 1
    let outBuffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &outBufferList.mBuffers,
                                                             count: Int(outBufferList.mNumberBuffers))
    outBuffers[0].mNumberChannels = inBuffer.mNumberChannels
    outBuffers[0].mDataByteSize = inBuffer.mDataByteSize   // 设置缓冲区大小
    outputData.withUnsafeMutableBytes { bytes in
      outBuffers[0].mData = bytes.baseAddress
    }

    var outputDataPacketSize = UInt32(1)
    let status = AudioConverterFillComplexBuffer(converter, inputDataProc, &inBufferList, &outputDataPacketSize, &outBufferList, nil)
    if status != noErr {
      #if DEBUG
      print("[LiveAudioAACEncoder] AudioConverterFillComplexBuffer failed with status: \(status)")
      #endif
      return
    }

    // Check if encoder actually produced packets
    if outputDataPacketSize == 0 {
      #if DEBUG
      print("[LiveAudioAACEncoder] Warning: No packets encoded, skipping frame")
      #endif
      return
    }

    // Get actual encoded data size from output buffer
    let actualOutputSize = Int(outBuffers[0].mDataByteSize)

    // Verify encoded data size is reasonable
    // AAC frames should be at least 50 bytes, typically 100-500 bytes
    // First frame might be encoder priming data and should be skipped
    if actualOutputSize == 0 || actualOutputSize < 50 || actualOutputSize > audioData.count {
      #if DEBUG
      print("[LiveAudioAACEncoder] Warning: Abnormal frame size (\(actualOutputSize) bytes), skipping")
      print("  This is likely encoder priming/delay data")
      #endif
      return
    }

    let actualEncodedData = Data(outputData.prefix(actualOutputSize))

    let audioFrame = AudioFrame(timestamp: UInt64(timestamp.seconds * 1000), data: actualEncodedData, header: audioHeader, aacHeader: aacHeader)
//    let audioFrame = AudioFrame(timestamp: UInt64(timestamp.seconds * 1000), data: outputData, header: audioHeader, aacHeader: aacHeader)

    #if DEBUG
    let compressionRatio = Double(audioData.count) / Double(actualOutputSize)
    print("[LiveAudioAACEncoder] Encoded audio frame:")
    print("  Timestamp: \(timestamp.seconds)s")
    print("  Input: \(audioData.count) bytes")
    print("  Output: \(actualOutputSize) bytes")
    print("  Compression ratio: \(String(format: "%.1f", compressionRatio)):1")
    print("  First 16 bytes: \(actualEncodedData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")

    // Check if this might be ADTS format
    if actualEncodedData.count >= 2 {
      let byte0 = actualEncodedData[0]
      let byte1 = actualEncodedData[1]
      if byte0 == 0xFF && (byte1 & 0xF0) == 0xF0 {
        print("  ⚠️  WARNING: This looks like ADTS AAC (has sync word 0xFF Fx)!")
        print("  RTMP expects Raw AAC, not ADTS!")
      } else {
        print("  ✓  Format appears to be Raw AAC (no ADTS header)")
      }
    }
    #endif

    delegate?.audioEncoder(encoder: self, audioFrame: audioFrame)
  }
  
  private let inputDataProc: AudioConverterComplexInputDataProc = { (
    audioConverter,
    ioNumDataPackets,
    ioData,
    ioPacketDesc,
    inUserData ) -> OSStatus in
    
    guard var bufferList = inUserData?.assumingMemoryBound(to: AudioBufferList.self).pointee else {
      print("AudioBufferList error")
      return noErr
    }
    let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &bufferList.mBuffers,
                                                          count: Int(bufferList.mNumberBuffers))
    
    let dataPtr = UnsafeMutableAudioBufferListPointer(ioData)
    dataPtr[0].mNumberChannels = buffers[0].mNumberChannels  // Use actual channels
    dataPtr[0].mData = buffers[0].mData
    dataPtr[0].mDataByteSize = buffers[0].mDataByteSize
    
    return noErr
  }
  
  private func setupEncoder(sb: CMSampleBuffer) -> Bool {
    if converter != nil {
      return true
    }
    if !createAudioConvertIfNeeded(sb: sb) {
      return false
    }
    
    setupHeaderData()
    
    setupBitrate()
    
    return true
  }
  
  private func setupHeaderData() {
    guard let outFormatDescription else { return }
    self.aacHeader = getAacHeader(outFormatDescription: outFormatDescription)
    self.audioHeader = getAudioHeader(outFormatDescription: outFormatDescription)
  }
  
  private func createAudioConvertIfNeeded(sb: CMSampleBuffer) -> Bool {
    // 获取音频格式描述
    guard let formatDescription = CMSampleBufferGetFormatDescription(sb) else {
      print("[LiveAudioAACEncoder] Error: Cannot get audio format description")
      return false
    }

    // 获取音频流基本描述（ASBD）
    let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)!.pointee

    // 获取采样率（Sample Rate）
    let sampleRate = audioStreamBasicDescription.mSampleRate

    // 获取通道数（Channels）
    let channels = audioStreamBasicDescription.mChannelsPerFrame

    // Check if format has changed
    if converter != nil {
      if actualSampleRate != sampleRate || actualChannels != channels {
        #if DEBUG
        print("[LiveAudioAACEncoder] Warning: Audio format changed!")
        print("  Previous: \(actualSampleRate) Hz, \(actualChannels) channels")
        print("  New: \(sampleRate) Hz, \(channels) channels")
        print("  Reinitializing encoder...")
        #endif
        // Reset converter to reinitialize with new format
        converter = nil
        inputDataBuffer = Data()
        inputBufferStartTimestamp = nil
        encodedFrameCountInBuffer = 0
      } else {
        return true
      }
    }

    // Save actual format parameters
    self.actualSampleRate = sampleRate
    self.actualChannels = channels

    // Copy the actual format flags from input to match byte order and other properties
    let inputFormatFlags = audioStreamBasicDescription.mFormatFlags

    #if DEBUG
    print("[LiveAudioAACEncoder] Initializing encoder with format:")
    print("  Sample Rate: \(sampleRate) Hz")
    print("  Channels: \(channels)")
    print("  Format Flags: 0x\(String(format: "%X", inputFormatFlags))")
    let isBigEndian = (inputFormatFlags & kAudioFormatFlagIsBigEndian) != 0
    let isNonInterleaved = (inputFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    print("  Byte Order: \(isBigEndian ? "Big-Endian" : "Little-Endian")")
    print("  Interleaved: \(!isNonInterleaved)")
    print("  Buffer Length: \(configuration.bufferLength) bytes")
    #endif

    var inputFormat = AudioStreamBasicDescription()
    inputFormat.mSampleRate = sampleRate
    inputFormat.mFormatID = kAudioFormatLinearPCM
    // Use actual input format flags instead of hardcoded values to match byte order
    inputFormat.mFormatFlags = inputFormatFlags
    inputFormat.mChannelsPerFrame = channels
    inputFormat.mFramesPerPacket = 1
    inputFormat.mBitsPerChannel = 16
    inputFormat.mBytesPerFrame = inputFormat.mBitsPerChannel / 8 * inputFormat.mChannelsPerFrame
    inputFormat.mBytesPerPacket = inputFormat.mBytesPerFrame * inputFormat.mFramesPerPacket
    
    // 输出音频格式
    var outputFormat = AudioStreamBasicDescription()
    outputFormat.mSampleRate = inputFormat.mSampleRate // 采样率保持一致
    outputFormat.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
    outputFormat.mFormatID = kAudioFormatMPEG4AAC // AAC编码 kAudioFormatMPEG4AAC kAudioFormatMPEG4AAC_HE_V2
    outputFormat.mChannelsPerFrame = channels
    outputFormat.mFramesPerPacket = 1024 // AAC frame size: 1024 samples per frame
    var outFormatDescription: CMFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &outputFormat, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &outFormatDescription)
    self.outFormatDescription = outFormatDescription
    
    
    // hard encoder and soft encoder
    // audio default is soft encoder
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
      return false
    }
    
    return converter != nil
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
    guard let streamBasicDesc = outFormatDescription.streamBasicDesc,
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

    #if DEBUG
    print("[LiveAudioAACEncoder] Audio Header constructed:")
    print("  ObjectType: \(mp4Id.rawValue)")
    print("  Channel Config: \(streamBasicDesc.mChannelsPerFrame)")
    print("  Sample Rate: \(streamBasicDesc.mSampleRate)")
    print("  AudioSpecificConfig: \(config.encodeData.map { String(format: "%02X", $0) }.joined(separator: " "))")
    print("  Full header (\(descData.count) bytes): \(descData.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " "))")
    #endif

    return descData
  }
  
  /*
   Sound format: a 4-bit field that indicates the audio format, such as AAC or MP3.
   Sound rate: a 2-bit field that indicates the audio sample rate, such as 44.1 kHz or 48 kHz.
   Sound size: a 1-bit field that indicates the audio sample size, such as 16-bit or 8-bit.
   Sound type: a 1-bit field that indicates the audio channel configuration, such as stereo or mono.
   */
  private func getAacHeader(outFormatDescription: CMFormatDescription) -> Data? {
    guard let streamBasicDesc = outFormatDescription.streamBasicDesc else {
      return nil
    }

    // Determine sound type based on actual number of channels
    let soundType: AudioData.SoundType = streamBasicDesc.mChannelsPerFrame == 1 ? .sndMono : .sndStereo

    let value = (AudioData.SoundFormat.aac.rawValue << 4 |
                 AudioData.SoundRate(value: streamBasicDesc.mSampleRate).rawValue << 2 |
                 AudioData.SoundSize.snd16Bit.rawValue << 1 |
                 soundType.rawValue)

    #if DEBUG
    print("[LiveAudioAACEncoder] AAC Header:")
    print("  Format: AAC")
    print("  Sample Rate: \(streamBasicDesc.mSampleRate) Hz")
    print("  Channels: \(streamBasicDesc.mChannelsPerFrame) (\(soundType == .sndMono ? "mono" : "stereo"))")
    print("  Header byte: 0x\(String(format: "%02X", value))")
    #endif

    return Data([UInt8(value)])
  }
  
}

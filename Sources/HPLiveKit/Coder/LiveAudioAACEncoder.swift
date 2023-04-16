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

extension CMAudioFormatDescription {
  
  var streamBasicDesc: AudioStreamBasicDescription? {
    get {
      return CMAudioFormatDescriptionGetStreamBasicDescription(self)?.pointee
    }
  }
}


/*
 AudioSpecificConfig = 2 bytes,
 number = bits
 ------------------------------
 | audioObjectType (5)        |
 | sampleingFrequencyIndex (4)|
 | channelConfigration (4)    |
 | frameLengthFlag (1)        |
 | dependsOnCoreCoder (1)     |
 | extensionFlag (1)          |
 ------------------------------
 */
struct AudioSpecificConfig {
  let objectType: MPEG4ObjectID
  var channelConfig: ChannelConfigType = .unknown
  var frequencyType: SampleFrequencyType = .unknown
  let frameLengthFlag: Bool
  let dependsOnCoreCoder: UInt8
  let extensionFlag: UInt8
  init (data: Data) {
    self.objectType = MPEG4ObjectID(rawValue: Int((0b11111000 & data[0]) >> 3)) ?? .aac_Main
    self.frequencyType = SampleFrequencyType(rawValue: (0b00000111 & data[0]) << 1 | (0b10000000 & data[1]) >> 7)
    self.channelConfig = ChannelConfigType(rawValue: (0b01111000 & data[1]) >> 3)
    let value = UInt8(data[1] & 0b00100000) == 1
    self.frameLengthFlag = value
    self.dependsOnCoreCoder = data[1] & 0b000000010
    self.extensionFlag = data[1] & 0b000000001
  }
  
  init(objectType: MPEG4ObjectID, channelConfig: ChannelConfigType, frequencyType: SampleFrequencyType, frameLengthFlag: Bool = false, dependsOnCoreCoder: UInt8 = 0, extensionFlag: UInt8 = 0) {
    self.objectType = objectType
    self.channelConfig = channelConfig
    self.frequencyType = frequencyType
    self.frameLengthFlag = frameLengthFlag
    self.dependsOnCoreCoder = dependsOnCoreCoder
    self.extensionFlag = extensionFlag
  }
  
  var encodeData: Data {
    get {
      let flag = self.frameLengthFlag ? 1 : 0
      let first = UInt8(self.objectType.rawValue) << 3 | UInt8(self.frequencyType.rawValue >> 1 & 0b00000111)
      let second = (0b10000000 & self.frequencyType.rawValue << 7) |
      (0b01111000 & self.channelConfig.rawValue << 3) |
      (UInt8(flag) << 2) |
      (self.dependsOnCoreCoder << 1) |
      self.extensionFlag
      return Data([first, second])
    }
  }
}

class LiveAudioAACEncoder: AudioEncoder {
  
  private let configuration: LiveAudioConfiguration
  
  weak var delegate: AudioEncoderDelegate?
  
  private var converter: AudioConverterRef?
  
  private var leftBuf: UnsafeMutableRawPointer
  private var aacBuf: UnsafeMutableRawPointer
  private var leftLength: Int = 0
  
  private var audioHeader: Data?
  fileprivate var outFormatDescription: CMFormatDescription? {
    didSet {
      guard let streamBasicDesc = self.outFormatDescription?.streamBasicDesc,
            let mp4Id = MPEG4ObjectID(rawValue: Int(streamBasicDesc.mFormatFlags)) else {
        return
      }
      var descData = Data()
      let config = AudioSpecificConfig(objectType: mp4Id,
                                       channelConfig: ChannelConfigType(rawValue: UInt8(streamBasicDesc.mChannelsPerFrame)),
                                       frequencyType: SampleFrequencyType(value: streamBasicDesc.mSampleRate))
      
      descData.append(aacHeader)
      descData.write(AudioData.AACPacketType.header.rawValue)
      descData.append(config.encodeData)
      self.audioHeader = descData
    }
  }
  
  /*
   Sound format: a 4-bit field that indicates the audio format, such as AAC or MP3.
   Sound rate: a 2-bit field that indicates the audio sample rate, such as 44.1 kHz or 48 kHz.
   Sound size: a 1-bit field that indicates the audio sample size, such as 16-bit or 8-bit.
   Sound type: a 1-bit field that indicates the audio channel configuration, such as stereo or mono.
   */
  var aacHeader: Data {
    get {
      guard let desc = self.outFormatDescription,
            let streamBasicDesc = desc.streamBasicDesc else {
        return Data()
      }
      let value = (AudioData.SoundFormat.aac.rawValue << 4 |
                   AudioData.SoundRate(value: streamBasicDesc.mSampleRate).rawValue << 2 |
                   AudioData.SoundSize.snd16Bit.rawValue << 1 |
                   AudioData.SoundType.sndStereo.rawValue)
      return Data([UInt8(value)])
    }
  }
  
  required init(configuration: LiveAudioConfiguration) {
    self.configuration = configuration
    
    print("LiveAudioAACEncoder init")
    
    leftBuf = malloc(configuration.bufferLength)
    aacBuf = malloc(configuration.bufferLength)
  }
  
  deinit {
    free(leftBuf)
    
    free(aacBuf)
  }
  
  func encodeAudioData(sampleBuffer: CMSampleBuffer) {
    var audioBufferList = AudioBufferList()
    var data = Data()
    var blockBuffer: CMBlockBuffer?
    
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &audioBufferList, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
    
    let buffers = UnsafeBufferPointer<AudioBuffer>(start: &audioBufferList.mBuffers, count: Int(audioBufferList.mNumberBuffers))
    
    for audioBuffer in buffers {
      let frame = audioBuffer.mData?.assumingMemoryBound(to: UInt8.self)
      data.append(frame!, count: Int(audioBuffer.mDataByteSize))
    }
    let audioData = data as NSData
    if !createAudioConvert(sb: sampleBuffer) {
      return
    }
    
    if leftLength + audioData.length >= self.configuration.bufferLength {
      ///<  发送
      let totalSize = leftLength + audioData.length
      let encodeCount = totalSize / configuration.bufferLength
      var totalBuf: UnsafeMutableRawPointer = malloc(totalSize)
      var p = totalBuf
      
      memset(totalBuf, Int32(totalSize), 0)
      memcpy(totalBuf, leftBuf, leftLength)
      memcpy(totalBuf + leftLength, audioData.bytes, audioData.length)
      
      let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      for _ in 0 ..< encodeCount {
        encodeBuffer(buf: p, timestamp: presentationTimeStamp)
        p += configuration.bufferLength
      }
      
      leftLength = totalSize % self.configuration.bufferLength
      memset(leftBuf, 0, self.configuration.bufferLength)
      memcpy(leftBuf, totalBuf + (totalSize - leftLength), leftLength)
      
      free(totalBuf)
      
      return
    }
    
    ///< 积累
    memcpy(leftBuf + leftLength, audioData.bytes, audioData.count)
    leftLength += audioData.count
    return
  }
  
  func stopEncoder() {
    converter = nil
    leftBuf = malloc(configuration.bufferLength)
    aacBuf = malloc(configuration.bufferLength)
    leftLength = 0
    
    audioHeader = nil
  }
    
  private func encodeBuffer(buf: UnsafeMutableRawPointer, timestamp: CMTime) {
    guard let converter = converter else {
      return
    }
    var inBuffer = AudioBuffer()
    inBuffer.mNumberChannels = 1
    inBuffer.mData = buf
    inBuffer.mDataByteSize = UInt32(configuration.bufferLength)
    
    var inBufferList = AudioBufferList()
    inBufferList.mNumberBuffers = 1
    var buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &inBufferList.mBuffers,
                                                          count: Int(inBufferList.mNumberBuffers))
    buffers[0] = inBuffer
    
    // 初始化一个输出缓冲列表
    var outBufferList = AudioBufferList()
    outBufferList.mNumberBuffers = 1
    let outBuffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &outBufferList.mBuffers,
                                                             count: Int(outBufferList.mNumberBuffers))
    outBuffers[0].mNumberChannels = inBuffer.mNumberChannels
    outBuffers[0].mDataByteSize = inBuffer.mDataByteSize   // 设置缓冲区大小
    outBuffers[0].mData = aacBuf
    
    var outputDataPacketSize = UInt32(1)
    let status = AudioConverterFillComplexBuffer(converter, inputDataProc, &inBufferList, &outputDataPacketSize, &outBufferList, nil)
    if status != noErr {
      return
    }
    
    var audioFrame = AudioFrame()
    audioFrame.header = audioHeader
    audioFrame.aacHeader = aacHeader
    audioFrame.timestamp = UInt64(timestamp.seconds * 1000)
    audioFrame.data = NSData(bytes: aacBuf, length: Int(outBuffers[0].mDataByteSize)) as Data
    
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
    dataPtr[0].mNumberChannels = 1
    dataPtr[0].mData = buffers[0].mData
    dataPtr[0].mDataByteSize = buffers[0].mDataByteSize
    
    return noErr
  }
  
  private func createAudioConvert(sb: CMSampleBuffer) -> Bool {
    if converter != nil {
      return true
    }
    
    // 获取音频格式描述
    guard let formatDescription = CMSampleBufferGetFormatDescription(sb) else {
      print("无法获取音频格式描述")
      return false
    }
    
    // 获取音频流基本描述（ASBD）
    let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)!.pointee
    
    // 获取采样率（Sample Rate）
    let sampleRate = audioStreamBasicDescription.mSampleRate
    print("Sample Rate: \(sampleRate)")
    
    // 获取通道数（Channels）
    let channels = audioStreamBasicDescription.mChannelsPerFrame
    print("Channels: \(channels)")
    
    var inputFormat = AudioStreamBasicDescription()
    inputFormat.mSampleRate = sampleRate
    inputFormat.mFormatID = kAudioFormatLinearPCM
    inputFormat.mFormatFlags =  kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
    inputFormat.mChannelsPerFrame = channels
    inputFormat.mFramesPerPacket = 1
    inputFormat.mBitsPerChannel = 16
    inputFormat.mBytesPerFrame = inputFormat.mBitsPerChannel / 8 * inputFormat.mChannelsPerFrame
    inputFormat.mBytesPerPacket = inputFormat.mBytesPerFrame * inputFormat.mFramesPerPacket
    
    // 输出音频格式
    var outputFormat = AudioStreamBasicDescription()
    memset(&outputFormat, 0, MemoryLayout.size(ofValue: outputFormat))
    outputFormat.mSampleRate = inputFormat.mSampleRate // 采样率保持一致
    outputFormat.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
    outputFormat.mFormatID = kAudioFormatMPEG4AAC // AAC编码 kAudioFormatMPEG4AAC kAudioFormatMPEG4AAC_HE_V2
    outputFormat.mChannelsPerFrame = channels
    outputFormat.mFramesPerPacket = 1024 // AAC一帧是1024个字节
    
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &outputFormat, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &outFormatDescription)
    
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
    
    guard let converter = converter else {
      return false
    }
    
    var outputBitrate = configuration.audioBitRate.rawValue
    let propSize = MemoryLayout.size(ofValue: outputBitrate)
    
    let setPropertyresult = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(propSize), &outputBitrate)
    
    if setPropertyresult != noErr {
      return false
    }
    
    return true
  }
  
}

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
  
  required init(configuration: LiveAudioConfiguration) {
    self.configuration = configuration
    
    print("LiveAudioAACEncoder init")
  }
  
  func encode(sampleBuffer: CMSampleBuffer) {
    if !setupEncoder(sb: sampleBuffer) {
      return
    }
    let audioData = sampleBuffer.audioRawData
    
    // buffer full, start encoding data
    if inputDataBuffer.count + audioData.count >= self.configuration.bufferLength {
      let totalSize = inputDataBuffer.count + audioData.count
      let encodeCount = totalSize / configuration.bufferLength
      var totalBuffer = Data()
      
      totalBuffer.append(inputDataBuffer)
      totalBuffer.append(audioData)
      
      let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      for i in 0 ..< encodeCount {
        let startIndex = i * configuration.bufferLength
        let endIndex = startIndex + configuration.bufferLength
        encodeBuffer(audioData: totalBuffer[startIndex..<endIndex], timestamp: presentationTimeStamp)
      }
            
      inputDataBuffer = totalBuffer.suffix(from: encodeCount * configuration.bufferLength)
      return
    }
    
    /// buffering audio data
    inputDataBuffer.append(audioData)
    return
  }
  
  func stop() {
    converter = nil
    inputDataBuffer = Data()
    
    audioHeader = nil
    aacHeader = nil
  }
    
  private func encodeBuffer(audioData: Data, timestamp: CMTime) {
    guard let converter = converter else {
      return
    }
    var inBuffer = AudioBuffer()
    inBuffer.mNumberChannels = 1
    audioData.withUnsafeBytes { bytes in
      inBuffer.mData = UnsafeMutableRawPointer(mutating: bytes.baseAddress!)
    }
    inBuffer.mDataByteSize = UInt32(configuration.bufferLength)
    
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
      return
    }
    
    let audioFrame = AudioFrame(timestamp: UInt64(timestamp.seconds * 1000), data: outputData, header: audioHeader, aacHeader: aacHeader)

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
    outputFormat.mSampleRate = inputFormat.mSampleRate // 采样率保持一致
    outputFormat.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
    outputFormat.mFormatID = kAudioFormatMPEG4AAC // AAC编码 kAudioFormatMPEG4AAC kAudioFormatMPEG4AAC_HE_V2
    outputFormat.mChannelsPerFrame = channels
    outputFormat.mFramesPerPacket = 1024 // AAC一帧是1024个字节
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
    let value = (AudioData.SoundFormat.aac.rawValue << 4 |
                 AudioData.SoundRate(value: streamBasicDesc.mSampleRate).rawValue << 2 |
                 AudioData.SoundSize.snd16Bit.rawValue << 1 |
                 AudioData.SoundType.sndStereo.rawValue)
    return Data([UInt8(value)])
  }
  
}

//
//  StreamRtmpSocket.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import HPRTMP
import QuartzCore

actor RtmpPublisher: Publisher {
  
  ///<  重连1分钟  3秒一次 一共20次
  private let retryTimesBreaken = 5
  private let retryTimesMargin = 3
  
  private let rtmpReceiveTimeout = 2
  private let dataItemsMaxCount = 100
  private let rtmpDataReserveSize = 400
  
  private weak var delegate: PublisherDelegate?
  
  func setDelegate(delegate: PublisherDelegate?) async {
    self.delegate = delegate
  }
  
  private let stream: LiveStreamInfo
  
  private let buffer: StreamingBuffer = StreamingBuffer()
  private var debugInfo: LiveDebug = .init()
  
  //错误信息
  private var retryTimes4netWorkBreaken: Int = 0
  private let reconnectInterval: Int
  private let reconnectCount: Int
  
  private var lastVideoTimestamp: UInt64 = 0
  private var lastAudioTimestamp: UInt64 = 0
  // 状态
  private var isSending = false
  private var isConnected = false
  private var isConnecting = false
  private var isReconnecting = false
  
  private var sendVideoHead = false
  private var sendAudioHead = false
  
  private let rtmp = RTMPPublishSession()
  
  private let configure: PublishConfigure
  
  init(stream: LiveStreamInfo, reconnectInterval: Int = 0, reconnectCount: Int = 0) {
    self.stream = stream
    
    self.reconnectInterval = reconnectInterval > 0 ? reconnectInterval : retryTimesMargin
    
    self.reconnectCount = reconnectCount > 0 ? reconnectCount : retryTimesBreaken
    
    let videoSize = stream.videoConfiguration?.videoSize ?? CGSize.zero
    let conf = PublishConfigure(
      width: Int(videoSize.width),
      height: Int(videoSize.height),
      videocodecid: VideoData.CodecId.avc.rawValue,
      audiocodecid: AudioData.SoundFormat.aac.rawValue,
      framerate: Int(stream.videoConfiguration?.videoFrameRate ?? 30)
    )
    
    configure = conf
    
    Task {
      await buffer.setDelegate(delegate: self)
      await self.rtmp.setDelegate(self)
    }
  }
  
  func start() async {
    guard !isConnecting else { return }

    isConnecting = true

    debugInfo.streamId = stream.streamId
    debugInfo.uploadUrl = stream.url
    
    delegate?.publisher(publisher: self, publishStatus: .pending)
    
    await connect()
  }
  
  // CallBack
  private func connect() async {
    guard await rtmp.publishStatus != .publishStart else {
      reconnect()
      return
    }
    
    await rtmp.publish(url: stream.url, configure: configure)
    
    delegate?.publisher(publisher: self, publishStatus: .start)
  }
  
  private func reconnect() {
    Task {
      self.retryTimes4netWorkBreaken += 1
      if self.retryTimes4netWorkBreaken < self.reconnectCount && !self.isReconnecting {
        self.isConnected = false
        self.isConnecting = false
        self.isReconnecting = true
        try await Task.sleep(nanoseconds: UInt64(reconnectInterval) * 1000000)
        await self._reconnect()
      } else if self.retryTimes4netWorkBreaken >= self.reconnectCount {
        self.delegate?.publisher(publisher: self, publishStatus: .error)
        self.delegate?.publisher(publisher: self, errorCode: .reconnectTimeOut)
      }
    }
  }
  
  private func _reconnect() async {
    self.isReconnecting = false
    if isConnected { return }
    
    sendAudioHead = false
    sendVideoHead = false
    
    delegate?.publisher(publisher: self, publishStatus: .refresh)
    
    await rtmp.invalidate()
    
    await connect()
  }
  
  func stop() async {
    delegate?.publisher(publisher: self, publishStatus: .stop)
    
    await rtmp.invalidate()
    
    await clean()
  }
  
  private func clean() async {
    isConnected = false
    isReconnecting = false
    isSending = false
    sendAudioHead = false
    sendVideoHead = false
    debugInfo = LiveDebug()
    await buffer.removeAll()
    retryTimes4netWorkBreaken = 0
  }
  
  func send(frame: any Frame) {
    Task {
      await buffer.append(frame: frame)
      if !isSending {
        await self.sendFrame()
      }
    }
  }
  
}

private extension RtmpPublisher {
  func sendFrame() async {
    guard !self.isSending else { return }
    guard await !buffer.isEmpty else { return }

    self.isSending = true
    
    if !self.isConnected || self.isReconnecting || self.isConnecting {
      self.isSending = false
      return
    }
    
    guard let frame = await self.buffer.popFirstFrame() else { return }
    
    await pushFrame(frame: frame)
    
    await updateDebugInfo(frame: frame)
    
    self.isSending = false
  }
  
  func pushFrame(frame: any Frame) async {
    if let frame = frame as? VideoFrame {
      await pushVideo(frame: frame)
      return
    }
    
    if let frame = frame as? AudioFrame {
      await pushAudio(frame: frame)
      return
    }
  }
  
  func pushVideo(frame: VideoFrame) async {
    if !self.sendVideoHead {
      self.sendVideoHead = true
      if frame.sps == nil || frame.pps == nil {
        self.isSending = false
        return
      }
      
      await sendVideoHeader(frame: frame)
      await sendVideoFrame(frame: frame)
    } else {
      await sendVideoFrame(frame: frame)
    }
  }
  
  func pushAudio(frame: AudioFrame) async {
    if !self.sendAudioHead {
      self.sendAudioHead = true
      await self.sendAudioHeader(frame: frame)
      await self.sendAudioFrame(frame: frame)
    } else {
      await self.sendAudioFrame(frame: frame)
    }
  }
  
  func updateDebugInfo(frame: any Frame) async {
    //debug更新
    self.debugInfo.totalFrameCount += 1
    self.debugInfo.dropFrameCount += await self.buffer.lastDropFrames
    await self.buffer.clearDropFramesCount()
    
    self.debugInfo.allDataSize += CGFloat(frame.data?.count ?? 0)
    self.debugInfo.elapsedMilli = CGFloat(UInt64(CACurrentMediaTime() * 1000)) - self.debugInfo.currentTimeStamp
    
    if debugInfo.elapsedMilli < 1000 {
      debugInfo.bandwidthPerSec += CGFloat(frame.data?.count ?? 0)
      if frame is AudioFrame {
        debugInfo.capturedAudioCountPerSec += 1
      } else {
        debugInfo.capturedVideoCountPerSec += 1
      }
      debugInfo.unsendCount = await buffer.list.count
    } else {
      debugInfo.currentBandwidth = debugInfo.bandwidthPerSec
      debugInfo.currentCapturedAudioCount = debugInfo.currentCapturedAudioCount
      debugInfo.currentCapturedVideoCount = debugInfo.capturedVideoCountPerSec
      
      delegate?.publisher(publisher: self, debugInfo: debugInfo)
      
      debugInfo.bandwidthPerSec = 0
      debugInfo.capturedVideoCountPerSec = 0
      debugInfo.capturedAudioCountPerSec = 0
      debugInfo.currentTimeStamp = CGFloat(UInt64(CACurrentMediaTime() * 1000))
    }
  }
  
}

private extension RtmpPublisher {
  func sendVideoHeader(frame: VideoFrame) async {
    guard let sps = frame.sps, let pps = frame.pps else { return }
    var body = Data()
    // Video Tag Header, key frame and avc encode
    let frameAndCode:UInt8 = UInt8(VideoData.FrameType.keyframe.rawValue << 4 | VideoData.CodecId.avc.rawValue)
    body.append(Data([frameAndCode]))
    
    // AVC sequence header
    body.append(Data([VideoData.AVCPacketType.header.rawValue]))
    
    // CompositionTime 0
    body.append(Data([0x00, 0x00, 0x00]))
    
    
    // AVCDecoderConfigurationRecord
    
    // configurationVersion
    body.append(Data([0x01]))
    
    // AVCProfileIndication,profile_compatibility,AVCLevelIndication, lengthSizeMinusOne
    body.append(Data([sps[1], sps[2], sps[3], 0xff]))
    
    /*sps*/
    
    // numOfSequenceParameterSets
    body.append(Data([0xe1]))
    // sequenceParameterSetLength
    body.append(UInt16(sps.count).bigEndian.data)
    // sequenceParameterSetNALUnit
    body.append(Data(sps))
        
    /*pps*/
    
    // numOfPictureParameterSets
    body.append(Data([0x01]))
    // pictureParameterSetLength
    body.append(UInt16(pps.count).bigEndian.data)
    // pictureParameterSetNALUnit
    body.append(Data(pps))
    
    await rtmp.publishVideoHeader(data: body)
  }
  
  func sendVideoFrame(frame: VideoFrame) async {
    guard let data = frame.data else { return }
    /*
     Frame Type: a 4-bit field that indicates the type of frame, such as a keyframe or an interframe.
     
     Codec ID: a 4-bit field that indicates the codec used to encode the video data, such as H.264 or VP6.
     
     AVC Packet Type: an 8-bit field that indicates the type of AVC packet, such as a sequence header or a NALU.
     
     Composition Time: a 24-bit field that indicates the composition time of the video frame.
     
     Video Data Payload: the actual video data payload, which includes the NAL units of the frame.
     */
    var descData = Data()
    let frameType = frame.isKeyFrame ? VideoData.FrameType.keyframe : VideoData.FrameType.inter
    let frameAndCode:UInt8 = UInt8(frameType.rawValue << 4 | VideoData.CodecId.avc.rawValue)
    descData.append(Data([frameAndCode]))
    descData.append(Data([VideoData.AVCPacketType.nalu.rawValue]))
    
    let delta = lastVideoTimestamp != 0 ? frame.timestamp - lastVideoTimestamp : 0
    // 24bit
    descData.write24(frame.compositionTime, bigEndian: true)
    descData.append(data)
    await rtmp.publishVideo(data: descData, delta: UInt32(delta))
    lastVideoTimestamp = frame.timestamp
  }
  
  func sendAudioHeader(frame: AudioFrame) async {
    guard let header = frame.header else {
      return
    }
    // Publish the audio header to the RTMP server
    await rtmp.publishAudioHeader(data: header)
  }
  
  func sendAudioFrame(frame: AudioFrame) async {
    guard let data = frame.data, let aacHeader = frame.aacHeader  else {
      return
    }
    var audioPacketData = Data()
    audioPacketData.append(aacHeader)
    audioPacketData.write(AudioData.AACPacketType.raw.rawValue)
    audioPacketData.append(data)
    let delta = lastAudioTimestamp != 0 ? UInt32(frame.timestamp - lastAudioTimestamp) : 0
    await rtmp.publishAudio(data: audioPacketData, delta: delta)
    lastAudioTimestamp = frame.timestamp
  }
}

extension RtmpPublisher: StreamingBufferDelegate {
  nonisolated func steamingBuffer(streamingBuffer: StreamingBuffer, bufferState: BufferState) {
    Task {
      await delegate?.publisher(publisher: self, bufferStatus: bufferState)
    }
  }
}

extension RtmpPublisher: RTMPPublishSessionDelegate {
  func sessionError(_ session: HPRTMP.RTMPPublishSession, error: HPRTMP.RTMPError) {
    reconnect()
  }
  
  func sessionStatusChange(_ session: HPRTMP.RTMPPublishSession, status: HPRTMP.RTMPPublishSession.Status) {
    if status == .publishStart {
      isConnected = true
      isConnecting = false
      isReconnecting = false
      isSending = false
    }
  }
}


extension ExpressibleByIntegerLiteral {
  var data: Data {
    var value: Self = self
    return Data(bytes: &value, count: MemoryLayout<Self>.size)
  }
}

//
//  StreamRtmpSocket.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import HPRTMP

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
  
  private lazy var buffer: StreamingBuffer = {
    let buffer = StreamingBuffer()
    buffer.delegate = self
    return buffer
  }()
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
      framerate: Int(stream.videoConfiguration?.videoFrameRate ?? 30),
      videoDatarate: Int((stream.videoConfiguration?.videoBitRate ?? 0)) / 1000,
      audioDatarate: Int((stream.audioConfiguration?.audioBitRate.rawValue ?? 0)) / 1000,
      audioSamplerate: stream.audioConfiguration?.audioSampleRate.rawValue
    )
    
    configure = conf
    
    Task {
      await self.rtmp.setDelegate(self)
    }
  }
  
  nonisolated func start() {
    Task {
      await self._start()
    }
  }
  
  private func _start() async {
    guard !isConnected else { return }
    
    debugInfo.streamId = stream.streamId
    debugInfo.uploadUrl = stream.url
    
    guard !isConnecting else { return }
    
    isConnecting = true
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
    if isConnected { return }
    
    sendAudioHead = false
    sendVideoHead = false
    
    delegate?.publisher(publisher: self, publishStatus: .refresh)
    
    await rtmp.invalidate()
    
    await connect()
  }
  
  func stop() async {
    await self._stop()
  }
  
  private func _stop() async {
    delegate?.publisher(publisher: self, publishStatus: .stop)
    
    await rtmp.invalidate()
    
    clean()
  }
  
  private func clean() {
    isConnected = false
    isReconnecting = false
    isSending = false
    isConnected = false
    sendAudioHead = false
    sendVideoHead = false
    debugInfo = LiveDebug()
    buffer.removeAll()
    retryTimes4netWorkBreaken = 0
  }
  
  func send(frame: Frame) {
    buffer.append(frame: frame)
    Task {
      if !isSending {
        await self.sendFrame()
      }
    }
  }
  
}

private extension RtmpPublisher {
  func sendFrame() async {
    guard !self.isSending && !self.buffer.list.isEmpty else { return }
    
    self.isSending = true
    
    if !self.isConnected || self.isReconnecting || self.isConnecting {
      self.isSending = false
      return
    }
    
    guard let frame = self.buffer.popFirstFrame() else { return }
    
    await pushFrame(frame: frame)
    
    updateDebugInfo(frame: frame)
    
    self.isSending = false
  }
  
  func pushFrame(frame: Frame) async {
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
      if frame.header == nil {
        self.isSending = false
        return
      }
      await self.sendAudioHeader(frame: frame)
      await self.sendAudioFrame(frame: frame)
    } else {
      await self.sendAudioFrame(frame: frame)
    }
  }
  
  func updateDebugInfo(frame: Frame) {
    //debug更新
    self.debugInfo.totalFrameCount += 1
    self.debugInfo.dropFrameCount += self.buffer.lastDropFrames
    self.buffer.lastDropFrames = 0
    
    self.debugInfo.allDataSize += CGFloat(frame.data?.count ?? 0)
    self.debugInfo.elapsedMilli = CGFloat(UInt64(CACurrentMediaTime() * 1000)) - self.debugInfo.currentTimeStamp
    
    if debugInfo.elapsedMilli < 1000 {
      debugInfo.bandwidthPerSec += CGFloat(frame.data?.count ?? 0)
      if frame is AudioFrame {
        debugInfo.capturedAudioCountPerSec += 1
      } else {
        debugInfo.capturedVideoCountPerSec += 1
      }
      debugInfo.unsendCount = buffer.list.count
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
    body.append(Data([0x17]))
    body.append(Data([0x00]))
    
    body.append(Data([0x00, 0x00, 0x00]))
    
    body.append(Data([0x01]))
    
    let spsSize = sps.count
    
    body.append(Data([sps[1], sps[2], sps[3], 0xff]))
    
    /*sps*/
    body.append(Data([0xe1]))
    body.append(Data([(UInt8(spsSize) >> 8) & 0xff, UInt8(spsSize) & 0xff]))
    body.append(Data(sps))
    
    let ppsSize = pps.count
    
    /*pps*/
    body.append(Data([0x01]))
    body.append(Data([(UInt8(ppsSize) >> 8) & 0xff, UInt8(ppsSize) & 0xff]))
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

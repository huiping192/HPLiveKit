//
//  StreamRtmpSocket.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import HPRTMP

class RtmpPublisher: NSObject, Publisher {
  
  ///<  重连1分钟  3秒一次 一共20次
  private let retryTimesBreaken = 5
  private let retryTimesMargin = 3
  
  private let rtmpReceiveTimeout = 2
  private let dataItemsMaxCount = 100
  private let rtmpDataReserveSize = 400
  
  weak var delegate: PublisherDelegate?
  
  private let stream: LiveStreamInfo
  
  private lazy var buffer: StreamingBuffer = {
    let buffer = StreamingBuffer()
    buffer.delegate = self
    return buffer
  }()
  private var debugInfo: LiveDebug = .init()
  
  private let rtmpSendQueue = DispatchQueue.global(qos: .userInitiated)
  
  //错误信息
  private var retryTimes4netWorkBreaken: Int = 0
  private let reconnectInterval: Int
  private let reconnectCount: Int
  
  // 状态
  private var isSending = false {
    //这里改成observer主要考虑一直到发送出错情况下，可以继续发送
    didSet {
      guard !isSending else { return }
      rtmpSendQueue.async {
        self.sendFrame()
      }
    }
  }
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
    
//    let conf = HPRTMPConf()
//    conf.url = stream.url
//
//    conf.audioBitrate = CGFloat(stream.audioConfiguration?.audioBitRate.rawValue ?? 1000)
//    conf.audioSampleRate = CGFloat(stream.audioConfiguration?.audioSampleRate.rawValue ?? 30)
//    conf.numberOfChannels = Int32(stream.audioConfiguration?.numberOfChannels ?? 1)
//
//    let videoSize = stream.videoConfiguration?.videoSize ?? CGSize.zero
//    conf.videoBitrate = CGFloat(stream.videoConfiguration?.videoBitRate ?? 1000)
//    conf.videoFrameRate = CGFloat(stream.videoConfiguration?.videoFrameRate ?? 30)
    
    let videoSize = stream.videoConfiguration?.videoSize ?? CGSize.zero
    let conf = PublishConfigure(
        width: Int(videoSize.width),
        height: Int(videoSize.height),
        displayWidth: Int(videoSize.width),
        displayHeight: Int(videoSize.height),
        videocodecid: VideoData.CodecId.avc.rawValue,
        audiocodecid: AudioData.SoundFormat.aac.rawValue,
        framerate: Int(stream.videoConfiguration?.videoFrameRate ?? 30),
        videoframerate: Int(stream.videoConfiguration?.videoFrameRate ?? 30)
    )
    
    configure = conf
    
    super.init()
    
    self.rtmp.delegate = self
  }
  
  func start() {
    rtmpSendQueue.async {
      self._start()
    }
  }
  
  private func _start() {
    guard !isConnected else { return }
    
    debugInfo.streamId = stream.streamId
    debugInfo.uploadUrl = stream.url
    
    guard !isConnected else { return }
    
    isConnected = true
    delegate?.publisher(publisher: self, publishStatus: .pending)
    
//    rtmp.close()
    
    connect()
  }
  
  // CallBack
  private func connect() {
//    guard self.rtmp.connect() == 0 else {
//      reconnect()
//      return
//    }
    
    rtmp.publish(url: stream.url, configure: configure)
    
    delegate?.publisher(publisher: self, publishStatus: .start)
    
    isConnected = true
    isConnecting = false
    isReconnecting = false
    isSending = false
  }
  
  private func reconnect() {
    rtmpSendQueue.async {
      self.retryTimes4netWorkBreaken += 1
      if self.retryTimes4netWorkBreaken < self.reconnectCount && !self.isReconnecting {
        self.isConnected = false
        self.isConnecting = false
        self.isReconnecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(self.reconnectInterval)) {
          self._reconnect()
        }
      } else if self.retryTimes4netWorkBreaken >= self.reconnectCount {
        self.delegate?.publisher(publisher: self, publishStatus: .error)
        self.delegate?.publisher(publisher: self, errorCode: .reconnectTimeOut)
      }
    }
  }
  
  private func _reconnect() {
    self.isReconnecting = false
    if isConnected { return }
    if isConnected { return }
    
    sendAudioHead = false
    sendVideoHead = false
    
    delegate?.publisher(publisher: self, publishStatus: .refresh)
    
//    rtmp.close()
    
    connect()
  }
  
  func stop() {
    rtmpSendQueue.async {
      self._stop()
      NSObject.cancelPreviousPerformRequests(withTarget: self)
    }
  }
  
  private func _stop() {
    delegate?.publisher(publisher: self, publishStatus: .stop)
    
//    rtmp.close()
    
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
    if !isSending {
      rtmpSendQueue.async {
        self.sendFrame()
      }
    }
  }
  
}

private extension RtmpPublisher {
  func sendFrame() {
    guard !self.isSending && !self.buffer.list.isEmpty else { return }
    
    self.isSending = true
    
    if !self.isConnected || self.isReconnecting || self.isConnecting {
      self.isSending = false
      return
    }
    
    guard let frame = self.buffer.popFirstFrame() else { return }
    
    pushFrame(frame: frame)
    
    updateDebugInfo(frame: frame)
    
    //修改发送状态
    DispatchQueue.global(qos: .userInitiated).async {
      self.isSending = false
    }
  }
  
  func pushFrame(frame: Frame) {
    if let frame = frame as? VideoFrame {
      pushVideo(frame: frame)
      return
    }
    
    if let frame = frame as? AudioFrame {
      pushAudio(frame: frame)
      return
    }
  }
  
  func pushVideo(frame: VideoFrame) {
    if !self.sendVideoHead {
      self.sendVideoHead = true
      if frame.sps == nil || frame.pps == nil {
        self.isSending = false
        return
      }
      
      self.sendVideoHeader(frame: frame)
    } else {
      self.sendVideoFrame(frame: frame)
    }
  }
  
  func pushAudio(frame: AudioFrame) {
    if !self.sendAudioHead {
      self.sendAudioHead = true
      if frame.audioInfo == nil {
        self.isSending = false
        return
      }
      self.sendAudioHeader(frame: frame)
    } else {
      self.sendAudioFrame(frame: frame)
    }
  }
  
  func updateDebugInfo(frame: Frame) {
    //debug更新
    self.debugInfo.totalFrameCount += 1
    self.debugInfo.dropFrameCount += self.buffer.lastDropFrames
    self.buffer.lastDropFrames = 0
    
    self.debugInfo.allDataSize += CGFloat(frame.data?.count ?? 0)
    self.debugInfo.elapsedMilli = CGFloat(Timestamp.now) - self.debugInfo.currentTimeStamp
    
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
      debugInfo.currentTimeStamp = CGFloat(Timestamp.now)
    }
  }
  
}

private extension RtmpPublisher {
  func sendVideoHeader(frame: VideoFrame) {
//    rtmp.sendVideoHeader(withSPS: frame.sps, pps: frame.pps)
//
//    Task {
//      rtmp.publishVideoHeader(data:time:)
//    }
   
  }
  
  func sendVideoFrame(frame: VideoFrame) {
//    rtmp.sendVideo(withVideoData: frame.data, timestamp: frame.timestamp, isKeyFrame: frame.isKeyFrame)
    Task {
      guard let data = frame.data else { return }
      try await rtmp.publishVideo(data: data, delta: UInt32(frame.timestamp))
    }
  }
  
  func sendAudioHeader(frame: AudioFrame) {
//    rtmp.sendAudioHeader(frame.header)
  }
  
  func sendAudioFrame(frame: AudioFrame) {
//    rtmp.sendAudio(withAudioData: frame.data, timestamp: frame.timestamp)
    
    Task {
      guard let data = frame.data else { return }
      try await rtmp.publishAudio(data: data, delta: UInt32(frame.timestamp))
    }
  }
}

extension RtmpPublisher: StreamingBufferDelegate {
  func steamingBuffer(streamingBuffer: StreamingBuffer, bufferState: BufferState) {
    delegate?.publisher(publisher: self, bufferStatus: bufferState)
  }
}

//extension RtmpPublisher: HPRTMPDelegate {
//  func rtmp(_ rtmp: HPRTMP!, error: Error!) {
//    self.reconnect()
//  }
//
//}

extension RtmpPublisher: RTMPPublishSessionDelegate {
  func sessionStatusChange(_ session: HPRTMP.RTMPPublishSession, status: HPRTMP.RTMPPublishSession.Status) {
    
  }
}

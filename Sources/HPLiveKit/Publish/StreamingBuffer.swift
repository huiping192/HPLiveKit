//
//  StreamingBuffer.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/27.
//

import Foundation

/** current buffer status */
enum BufferState {
  // buffer sending status unknown
  case unknown
  // buffer stack increase, should decline bitrate
  case increase
  // buffer stack decline, should increase bitrate
  case decline
}

protocol StreamingBufferDelegate: AnyObject {
  // buffer status change
  func steamingBuffer(streamingBuffer: StreamingBuffer, bufferState: BufferState)
}

actor StreamingBuffer {
  private static let defaultSortBufferMaxCount = UInt(5) ///< 排序10个内
  private static let defaultUpdateInterval = UInt(1) ///< 更新频率为1s
  private static let defaultCallBackInterval = UInt(5) ///< 5s计时一次
  private static let defaultSendBufferMaxCount = UInt(600) ///< 最大缓冲区为600
  
  weak var delegate: StreamingBufferDelegate?
  
  func setDelegate(delegate: StreamingBufferDelegate?) {
    self.delegate = delegate
  }
  
  /** current frame buffer */
  private(set) var list: [any Frame] = .init()
  
  /** buffer count max size */
  var maxCount: UInt = defaultSendBufferMaxCount
  
  /** count of drop frames in last time */
  var lastDropFrames: Int = 0
  
  private var sortList: [any Frame] = .init()
  private var thresholdList: [Int] = .init()
  
  /** 处理buffer缓冲区情况 */
  private var currentInterval: UInt = 0
  private var callBackInterval: UInt = StreamingBuffer.defaultCallBackInterval
  private var updateInterval: UInt = StreamingBuffer.defaultUpdateInterval
  private var startTimer: Bool = false
  
  var isEmpty: Bool {
    list.isEmpty
  }
  
  func clearDropFramesCount() {
    lastDropFrames = 0
  }
  /** add frame to buffer */
  func append(frame: any Frame) {
    if !startTimer {
      startTimer = true
      self.tick()
    }
    
    if sortList.count < StreamingBuffer.defaultSortBufferMaxCount {
      sortList.append(frame)
    } else {
      ///< 排序
      sortList.append(frame)
      sortList.sort { i, j in
        return i.timestamp < j.timestamp
      }
      /// 丢帧
      removeExpireFrame()
      /// 添加至缓冲区
      let firstFrame = sortList.first
      sortList.removeFirst()
      if let firstFrame = firstFrame {
        list.append(firstFrame)
      }
    }
  }
  
  /** pop the first frome buffer */
  func popFirstFrame() -> (any Frame)? {
    guard let firstFrame = list.first else { return nil }
    list.removeFirst()
    return firstFrame
  }
  
  /** remove all objects from Buffer */
  func removeAll() {
    list.removeAll()
  }
  
  init() {
    
  }
  
  private func removeExpireFrame() {
    if list.count < maxCount {
      return
    }
    ///< 第一个P到第一个I之间的p帧
    let pFrames = expirePFrames()
    lastDropFrames += pFrames.count
    if !pFrames.isEmpty {
      list = list.filter { value in
        !pFrames.contains(where: { value.timestamp == $0.timestamp })
      }
      return
    }
    
    ///<  删除一个I帧（但一个I帧可能对应多个nal）
    let iFrames = expirePFrames()
    if !iFrames.isEmpty {
      list = list.filter { value in
        !iFrames.contains(where: { value.timestamp == $0.timestamp })
      }
      return
    }
    
    list.removeAll()
  }
  
  private func expirePFrames() -> [any Frame] {
    var iframes = [any Frame]()
    var timestamp = UInt64(0)
    
    for frame in list {
      if let frame = frame as? VideoFrame, frame.isKeyFrame {
        if timestamp != 0 && timestamp != frame.timestamp {
          break
        }
        iframes.append(frame)
        timestamp = frame.timestamp
      }
    }
    
    return iframes
  }
  
  func currentBufferState() -> BufferState {
    var currentCount = 0
    var increaseCount = 0
    var decreaseCount = 0
    
    for number in thresholdList {
      if number > currentCount {
        increaseCount += 1
      } else {
        decreaseCount += 1
      }
      currentCount = number
    }
    
    if increaseCount >= callBackInterval {
      return .increase
    }
    
    if decreaseCount >= self.callBackInterval {
      return .decline
    }
    
    return .unknown
  }
  
  // -- 采样
  private func tick() {
    /** 采样 3个阶段   如果网络都是好或者都是差给回调 */
    currentInterval += updateInterval
    
    thresholdList.append(list.count)
    
    if currentInterval >= callBackInterval {
      let state = currentBufferState()
      if state == .increase {
        delegate?.steamingBuffer(streamingBuffer: self, bufferState: .increase)
      } else if state == .decline {
        delegate?.steamingBuffer(streamingBuffer: self, bufferState: .decline)
      }
      
      currentInterval = 0
      thresholdList.removeAll()
    }
    
    Task {
      try? await Task.sleep(nanoseconds: UInt64(updateInterval) * 1000000)
      tick()
    }
  }
  
}

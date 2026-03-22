//
//  StreamingBuffer.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/27.
//

import Foundation

/** current buffer status */
package enum BufferState {
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
  private var tickTask: Task<Void, Never>?
  
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

    // Always add to sort list for timestamp ordering
    sortList.append(frame)

    // When sort list reaches threshold, sort and move oldest frame to send buffer
    if sortList.count >= StreamingBuffer.defaultSortBufferMaxCount {
      // Sort by timestamp to ensure correct ordering
      sortList.sort { i, j in
        return i.timestamp < j.timestamp
      }

      // Remove expired frames if buffer is full
      removeExpireFrame()

      // Move the oldest frame (smallest timestamp) to the send buffer
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
    sortList.removeAll()
  }

  func stopTick() {
    tickTask?.cancel()
    tickTask = nil
    startTimer = false
  }

  func setMaxCount(_ count: UInt) {
    maxCount = count
  }

  init() {}
  
  private func removeExpireFrame() {
    if list.count < maxCount { return }

    // Step 1: Drop orphaned P-frames that appear before the first I-frame (undecoded without prior I-frame)
    let orphanedPFrames = expireOrphanedPFrames()
    if !orphanedPFrames.isEmpty {
      lastDropFrames += orphanedPFrames.count
      let ts = Set(orphanedPFrames.map { $0.timestamp })
      list = list.filter { !ts.contains($0.timestamp) }
      return
    }

    // Step 2: Drop P-frames within the oldest GOP (between first and second I-frame)
    let gopPFrames = expireGOPPFrames()
    if !gopPFrames.isEmpty {
      lastDropFrames += gopPFrames.count
      let ts = Set(gopPFrames.map { $0.timestamp })
      list = list.filter { !ts.contains($0.timestamp) }
      return
    }

    // Step 3: Drop the first I-frame batch as last resort
    let iFrames = expireIFrames()
    if !iFrames.isEmpty {
      lastDropFrames += iFrames.count
      let ts = Set(iFrames.map { $0.timestamp })
      list = list.filter { !ts.contains($0.timestamp) }
      return
    }

    list.removeAll()
  }

  // P-frames that appear before the first I-frame (can't be decoded without a prior keyframe)
  private func expireOrphanedPFrames() -> [any Frame] {
    var result = [any Frame]()
    for frame in list {
      if let videoFrame = frame as? VideoFrame {
        if videoFrame.isKeyFrame { break }
        result.append(frame)
      }
    }
    return result
  }

  // P-frames within the oldest GOP (between first I-frame and second I-frame)
  private func expireGOPPFrames() -> [any Frame] {
    var result = [any Frame]()
    var foundFirstIFrame = false
    for frame in list {
      if let videoFrame = frame as? VideoFrame {
        if videoFrame.isKeyFrame {
          if foundFirstIFrame { break }
          foundFirstIFrame = true
        } else if foundFirstIFrame {
          result.append(frame)
        }
      }
    }
    return result
  }

  // All frames belonging to the first I-frame group (same timestamp, one I-frame may span multiple NALs)
  private func expireIFrames() -> [any Frame] {
    var result = [any Frame]()
    var targetTimestamp = UInt64(0)
    for frame in list {
      if let videoFrame = frame as? VideoFrame, videoFrame.isKeyFrame {
        if targetTimestamp == 0 { targetTimestamp = videoFrame.timestamp }
        if videoFrame.timestamp == targetTimestamp {
          result.append(frame)
        } else {
          break
        }
      }
    }
    return result
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
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(StreamingBuffer.defaultUpdateInterval) * 1_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.sample()
      }
    }
  }

  private func sample() {
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
  }
  
}

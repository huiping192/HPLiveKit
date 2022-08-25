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
    // 未知
    case unknown
    // 缓冲区状态差应该降低码率
    // buffer stack increase, should decline bitrate
    case increase
    // 缓冲区状态好应该提升码率
    // buffer stack decline, should increase bitrate
    case decline
}

/** this two method will control videoBitRate */
protocol StreamingBufferDelegate: class {
    ///** 当前buffer变动（增加or减少） 根据buffer中的updateInterval时间回调*/
    func steamingBuffer(streamingBuffer: StreamingBuffer, bufferState: BufferState)
}

class StreamingBuffer {

    private static let defaultSortBufferMaxCount = UInt(5) ///< 排序10个内
    private static let defaultUpdateInterval = UInt(1) ///< 更新频率为1s
    private static let defaultCallBackInterval = UInt(5) ///< 5s计时一次
    private static let defaultSendBufferMaxCount = UInt(600) ///< 最大缓冲区为600

    /** The delegate of the buffer. buffer callback */
    weak var delegate: StreamingBufferDelegate?

    /** current frame buffer */
    private(set) var list: [Frame] = .init()

    /** buffer count max size default 1000 */
    var maxCount: UInt = defaultSendBufferMaxCount

    /** count of drop frames in last time */
    var lastDropFrames: Int = 0

    private var lock = DispatchSemaphore(value: 1)

    private var sortList: [Frame] = .init()
    private var thresholdList: [Int] = .init()

    /** 处理buffer缓冲区情况 */
    private var currentInterval: UInt = 0
    private var callBackInterval: UInt = StreamingBuffer.defaultCallBackInterval
    private var updateInterval: UInt = StreamingBuffer.defaultUpdateInterval
    private var startTimer: Bool = false

    /** add frame to buffer */
    func append(frame: Frame) {
        if !startTimer {
            startTimer = true
            self.tick()
        }

        lock.wait()
        if sortList.count < StreamingBuffer.defaultSortBufferMaxCount {
            sortList.append(frame)
        } else {
            ///< 排序
            sortList.append(frame)
            sortList.sort { i, j in
                return i.timestamp > j.timestamp
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

        lock.signal()
    }

    /** pop the first frome buffer */
    func popFirstFrame() -> Frame? {
        lock.wait()
        let firstFrame = list.first
        list.removeFirst()
        lock.signal()

        return firstFrame
    }

    /** remove all objects from Buffer */
    func removeAll() {
        lock.wait()
        list.removeAll()
        lock.signal()
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
                return !pFrames.contains(value)
            }
            return
        }

        ///<  删除一个I帧（但一个I帧可能对应多个nal）
        let iFrames = expirePFrames()
        if !iFrames.isEmpty {
            list = list.filter { value in
                !iFrames.contains(value)
            }
            return
        }

        list.removeAll()
    }

    private func expirePFrames() -> [Frame] {
        var iframes = [Frame]()
        var timestamp = Timestamp(0)

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

        lock.wait()
        thresholdList.append(list.count)
        lock.signal()

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

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(updateInterval))) { [weak self] in
            self?.tick()
        }
    }

}

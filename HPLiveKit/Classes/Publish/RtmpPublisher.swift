//
//  StreamRtmpSocket.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import HPLibRTMP

class RtmpPublisher: Publisher {

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
    private let rtmpSendQueue = DispatchQueue(label: "com.huiping192.HPLiveKit.RTMPPublisher.Queue")

    //错误信息
    private var retryTimes4netWorkBreaken: Int = 0
    private let reconnectInterval: Int
    private let reconnectCount: Int

    // 状态
    private var isSending = false {
        //这里改成observer主要考虑一直到发送出错情况下，可以继续发送
        didSet {

        }
    }
    private var isConnected = false
    private var isConnecting = false
    private var isReconnecting = false

    private var sendVideoHead = false
    private var sendAudioHead = false

    private let rtmp: HPRTMP

    init(stream: LiveStreamInfo, reconnectInterval: Int = 0, reconnectCount: Int = 0) {
        self.stream = stream

        self.reconnectInterval = reconnectInterval > 0 ? reconnectInterval : retryTimesMargin

        self.reconnectCount = reconnectCount > 0 ? reconnectCount : retryTimesBreaken

        let conf = HPRTMPConf()
        conf.url = stream.url

        conf.audioBitrate = CGFloat(stream.audioConfiguration?.audioBitRate.rawValue ?? 1000)
        conf.audioSampleRate = CGFloat(stream.audioConfiguration?.audioSampleRate.rawValue ?? 30)
        conf.numberOfChannels = Int32(stream.audioConfiguration?.numberOfChannels ?? 1)

        conf.videoSize = stream.videoConfiguration?.videoSize ?? CGSize.zero
        conf.videoBitrate = CGFloat(stream.videoConfiguration?.videoBitRate ?? 1000)
        conf.videoFrameRate = CGFloat(stream.videoConfiguration?.videoFrameRate ?? 30)

        self.rtmp =  HPRTMP(conf: conf)
    }

    func start() {
        rtmpSendQueue.async {
            self._start()
        }
    }

    private func _start() {
        guard isConnected else { return }

        debugInfo.streamId = stream.streamId
        debugInfo.uploadUrl = stream.url
        self.debugInfo.isRtmp = true

        guard isConnected else { return }

        isConnected = true
        delegate?.socketStatus(publisher: self, status: .pending)

        rtmp.close()

        RTMP264_Connect(url: stream.url)
    }

    // CallBack
    private func RTMP264_Connect(url: String) -> Int {

        isConnected = true
        isConnecting = false
        isReconnecting = false
        isSending = false

        return 0
    }

    func stop() {
        rtmpSendQueue.async {
            self._stop()
            NSObject.cancelPreviousPerformRequests(withTarget: self)
        }
    }

    private func _stop() {
        delegate?.socketStatus(publisher: self, status: .stop)

        rtmp.close()

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
            sendFrame()
        }
    }

    private func sendFrame() {

    }

}

private extension RtmpPublisher {

}

private extension RtmpPublisher {
    func sendVideoHeader(frame: VideoFrame) {
        rtmp.sendVideoHeader(withSPS: frame.sps, pps: frame.pps)
    }

    func sendVideoFrame(frame: VideoFrame) {
        rtmp.sendVideo(withVideoData: frame.data, timestamp: frame.timestamp, isKeyFrame: frame.isKeyFrame)
    }

    func sendAudioHeader(frame: AudioFrame) {
        rtmp.sendAudioHeader(frame.header)
    }

    func sendAudioFrame(frame: AudioFrame) {
        rtmp.sendAudio(withAudioData: frame.data, timestamp: frame.timestamp)
    }
}

extension RtmpPublisher: StreamingBufferDelegate {
    func steamingBuffer(streamingBuffer: StreamingBuffer, bufferState: BufferState) {

    }
}

//
//  StreamRtmpSocket.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import pili_librtmp

class RtmpPublisher: Publisher {

    ///<  重连1分钟  3秒一次 一共20次
    private let retryTimesBreaken = 5
    private let retryTimesMargin = 3

    private let rtmpReceiveTimeout = 2
    private let dataItemsMaxCount = 100
    private let rtmpDataReserveSize = 400
    private var rtmpHeadSize: Int {
        return MemoryLayout.size(ofValue: PILI_RTMPPacket.self) + Int(RTMP_MAX_HEADER_SIZE)
    }

    weak var delegate: PublisherDelegate?
    
    private var mRTMP: UnsafeMutablePointer<PILI_RTMP>?
    
    private let stream: LiveStreamInfo
        
    private lazy var buffer: StreamingBuffer = {
        let buffer = StreamingBuffer()
        buffer.delegate = self
        return buffer
    }()
    private var debugInfo: LiveDebug = .init()
    private let rtmpSendQueue = DispatchQueue(label: "com.huiping192.HPLiveKit.RTMPPublisher.Queue")
    
    //错误信息
    private var error: RTMPError?
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
    
    init(stream: LiveStreamInfo, reconnectInterval: Int = 0, reconnectCount: Int = 0) {
        self.stream = stream
    
        self.reconnectInterval = reconnectInterval > 0 ? reconnectInterval : retryTimesMargin
        
        self.reconnectCount = reconnectCount > 0 ? reconnectCount : retryTimesBreaken
    }
    
    
    func start() {
        rtmpSendQueue.async {
            self._start()
        }
    }

    private func _start() {
        guard isConnected, mRTMP != nil else { return }
        
        debugInfo.streamId = stream.streamId
        debugInfo.uploadUrl = stream.url
        self.debugInfo.isRtmp = true
        
        guard isConnected else { return }
        
        isConnected = true
        delegate?.socketStatus(publisher: self, status: .pending)
        
        if var mRTMP = mRTMP {
            PILI_RTMP_Close(mRTMP, nil)
            PILI_RTMP_Free(mRTMP)
        }
        
        RTMP264_Connect(url: stream.url)
    }
    
    // CallBack
    private func RTMP264_Connect(url: String) -> Int {
        func failed() ->Int {
            PILI_RTMP_Close(mRTMP, nil);
            PILI_RTMP_Free(mRTMP);
            self.mRTMP = nil
            return -1
        }
        
        //由于摄像头的timestamp是一直在累加，需要每次得到相对时间戳
        //分配与初始化
        mRTMP = PILI_RTMP_Alloc()
        PILI_RTMP_Init(mRTMP)
        
        //设置URL
        if PILI_RTMP_SetupURL(mRTMP, url.cString(using: .ascii), nil) != noErr {
            print("RTMP_SetupURL() failed!")
            return failed()
        }
        
        var rtmp = mRTMP?.pointee
//        rtmp?.m_errorCallback = nil
//        rtmp?.m_userData = nil
        rtmp?.m_msgCounter = 1
        rtmp?.Link.timeout = Int32(rtmpReceiveTimeout)

        //设置可写，即发布流，这个函数必须在连接前使用，否则无效
        PILI_RTMP_EnableWrite(mRTMP)
        
        //连接服务器
        if (PILI_RTMP_Connect(mRTMP, nil, nil) != noErr) {
            return failed()
        }

        //连接流
        if (PILI_RTMP_ConnectStream(mRTMP, 0, nil) != noErr) {
            return failed()
        }
        
        delegate?.socketStatus(publisher: self, status: .start)
        
        sendMetaData()
        
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
        
        if var mRTMP = mRTMP {
            PILI_RTMP_Close(mRTMP, nil);
            PILI_RTMP_Free(mRTMP);
            self.mRTMP = nil
        }
        
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
    
    private func sendMetaData() {
        
    }
}
 
private extension RtmpPublisher {
    
}

private extension RtmpPublisher {
    func sendVideoHeader(sps: Data, pps: Data) {

    }

    func sendVideoFrame() {

    }

    func sendAudioHeader() {

    }

    func sendAudioFrame() {

    }
}


extension RtmpPublisher: StreamingBufferDelegate {
    func steamingBuffer(streamingBuffer: StreamingBuffer, bufferState: BufferState) {
        
    }
}

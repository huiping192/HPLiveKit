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
        guard let rtmp = mRTMP?.pointee else { return }
        var packet: PILI_RTMPPacket = PILI_RTMPPacket()

                
//        var pubf: UnsafePointer<UInt8> = &0
//        var pend = &pubf + MemoryLayout.size(ofValue: pubf)
        var pend: UnsafeMutablePointer<Int8> =   UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        packet.m_nChannel = 0x03                  // control channel (invoke)
        packet.m_headerType = UInt8(RTMP_PACKET_SIZE_LARGE)
        packet.m_packetType = UInt8(RTMP_PACKET_TYPE_INFO)
        packet.m_nTimeStamp = 0
        packet.m_nInfoField2 = rtmp.m_stream_id
        packet.m_hasAbsTimestamp = 1
//        packet.m_body = pbuf + RTMP_MAX_HEADER_SIZE;
        
        var enc: UnsafeMutablePointer<Int8>? = packet.m_body
        var dataFrame = av_setDataFrame
        enc = PILI_AMF_EncodeString(enc, pend, &dataFrame)
        var onMetaData = av_onMetaData
        enc = PILI_AMF_EncodeString(enc, pend, &onMetaData)
        
        enc?.advanced(by: 1).pointee = Int8(PILI_AMF_OBJECT.rawValue)
        
        var duration = av_duration
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &duration, 0.0)
        var fileSize = av_fileSize
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &fileSize, 0.0)


        // videosize
        var width = av_width
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &width, Double(stream.videoConfiguration?.internalVideoSize.width ?? 0.0))
        var height = av_height
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &height, Double(stream.videoConfiguration?.internalVideoSize.height ?? 0.0))

        // video
        var videoCodecId = av_videocodecid
        var avc1 = av_avc1
        enc = PILI_AMF_EncodeNamedString(enc, pend, &videoCodecId, &avc1)
        var videoDataRate = av_videodatarate
        
        let bitrate = Double(stream.videoConfiguration?.videoBitRate ?? 0) / 1000.0
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &videoDataRate, bitrate)
        var avFrameRate = av_framerate
        let frameRate = stream.videoConfiguration?.videoFrameRate ?? 0
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &avFrameRate, Double(frameRate))

        // audio
        var audioCodecId = av_audiocodecid
        var avMp4a = av_mp4a
        enc = PILI_AMF_EncodeNamedString(enc, pend, &audioCodecId, &avMp4a)
        var audioDataRate = av_audiodatarate
        var audioBitrate = Double(stream.audioConfiguration?.audioBitRate.rawValue ?? 0)
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &audioDataRate, audioBitrate)
        
        var avAudioSampleRate = av_audiosamplerate
        var aduioSapleRate = Double(stream.audioConfiguration?.audioSampleRate.rawValue ?? 0)
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &avAudioSampleRate, aduioSapleRate)
        
        var aduioSampleSize = av_audiosamplesize
        enc = PILI_AMF_EncodeNamedNumber(enc, pend, &aduioSampleSize, 16.0)

        var avStereo = av_stereo
        enc = PILI_AMF_EncodeNamedBoolean(enc, pend, &avStereo, stream.audioConfiguration?.numberOfChannels == 2 ? 1 : 0 )

        // sdk version
        var avEncoder = av_encoder
        var avSDKVersion = av_SDKVersion
        enc = PILI_AMF_EncodeNamedString(enc, pend, &avEncoder, &avSDKVersion)
        
        
        
        enc?.advanced(by: 1).pointee = 0
        enc?.advanced(by: 1).pointee = 0

        enc?.advanced(by: 1).pointee = Int8(PILI_AMF_OBJECT_END.rawValue)

//        packet.m_nBodySize = (uint32_t)(enc - packet.m_body);
        
        if PILI_RTMP_SendPacket(mRTMP, &packet, 0, nil) == 0 {
            return
        }

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

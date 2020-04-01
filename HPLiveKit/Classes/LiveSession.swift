//
//  LiveSession.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import UIKit

//< only video (External input video)
struct LiveCaptureType: OptionSet {
    public let rawValue: Int

    static let captureAudio = LiveCaptureType(rawValue: 1 << 0) //< capture only audio
    static let captureVideo = LiveCaptureType(rawValue: 1 << 1) //< capture onlt video
    static let inputAudio = LiveCaptureType(rawValue: 1 << 2) //< only audio (External input audio)
    static let inputVideo = LiveCaptureType(rawValue: 1 << 3) //< only video (External input video)
}

///< 用来控制采集类型（可以内部采集也可以外部传入等各种组合，支持单音频与单视频,外部输入适用于录屏，无人机等外设介入）
struct LiveCaptureTypeMask {

    ///< only inner capture audio (no video)
    static let captureMaskAudio: LiveCaptureType  = [.captureAudio]
    ///< only inner capture video (no audio)
    static let captureMaskVideo: LiveCaptureType = [.captureVideo]
    ///< only outer input audio (no video)
    static let inputMaskAudio: LiveCaptureType  = [.inputAudio]
    ///< only outer input video (no audio)
    static let inputMaskVideo: LiveCaptureType  =  [.inputVideo]

    ///< inner capture audio and video
    static let captureMaskAll: LiveCaptureType  = captureMaskAudio.union(captureMaskVideo)
    ///< outer input audio and video(method see pushVideo and pushAudio)
    static let inputMaskAll: LiveCaptureType  =  inputMaskAudio.union(inputMaskVideo)

    ///< inner capture audio and outer input video(method pushVideo and setRunning)
    static let captureMaskAudioInputVideo: LiveCaptureType  =  captureMaskAudio.union(inputMaskAudio)
    ///< inner capture video and outer input audio(method pushAudio and setRunning)
    static let captureMaskVideoInputAudio: LiveCaptureType  = captureMaskVideo.union(inputMaskVideo)
    ///< default is inner capture audio and video
    static let captureDefaultMask: LiveCaptureType  = captureMaskAll
}

public protocol LiveSessionDelegate: class {
    ///** live status changed will callback */
    func liveSession(session: LiveSession, liveStateDidChange state: LiveState)
    ///** live debug info callback */
    func liveSession(session: LiveSession, debugInfo: LiveDebug)
    ///** callback socket errorcode */
    func liveSession(session: LiveSession, errorCode: LiveSocketErrorCode)
}

public class LiveSession: NSObject {

    public weak var delegate: LiveSessionDelegate?

    public var showDebugInfo: Bool = false
    public var adaptiveBitrate: Bool = true

    private let audioConfiguration: LiveAudioConfiguration
    private let videoConfiguration: LiveVideoConfiguration

    // 视频，音频数据源 video,audio data source
    private let videoCapture: LiveVideoCapture
    private let audioCapture: LiveAudioCapture

    // 视频，音频编码 encoder
    private let videoEncoder: VideoEncoder
    private let audioEncoder: AudioEncoder

    // 推流 publisher
    private var publisher: Publisher?

    /// 调试信息 debug info
    private var debugInfo: LiveDebug?
    /// 流信息 stream info
    private var streamInfo: LiveStreamInfo?
    /// 是否开始上传  is publishing
    private var uploading: Bool = false
    /// 当前状态 current live stream state
    private var state: LiveState?
    /// 当前直播type
    private var captureType: LiveCaptureType = LiveCaptureTypeMask.captureDefaultMask
    /// 时间戳锁  timestamp lock
    private var lock = DispatchSemaphore(value: 0)

    /// 上传相对时间戳
    private var relativeTimestamp: Timestamp = 0
    /// 音视频是否对齐
    private var avAlignment: Bool {
        if ( captureType.contains(LiveCaptureTypeMask.captureMaskVideo) || captureType.contains(LiveCaptureTypeMask.inputMaskAudio)) && (captureType.contains(LiveCaptureTypeMask.captureMaskVideo) || captureType.contains(LiveCaptureTypeMask.inputMaskVideo)) {

            return hasCaptureAudio && hasCaptureKeyFrame
        }

        return false
    }
    /// 当前是否采集到了音频
    private var hasCaptureAudio: Bool = false
    /// 当前是否采集到了关键帧
    private var hasCaptureKeyFrame: Bool = false

    public var preview: UIView? {
        get {
            videoCapture.perview
        }
        set {
            videoCapture.perview = newValue
        }
    }

    public var warterMarkView: UIView? {
        get {
            return videoCapture.warterMarkView
        }
        set {
            videoCapture.warterMarkView = newValue
        }
    }

    public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
        self.audioConfiguration = audioConfiguration
        self.videoConfiguration = videoConfiguration

        videoCapture = LiveVideoCapture(videoConfiguration: videoConfiguration)
        audioCapture = LiveAudioCapture(configuration: audioConfiguration)

        videoEncoder = LiveVideoH264Encoder(configuration: videoConfiguration)
        audioEncoder = LiveAudioAACEncoder(configuration: audioConfiguration)
    }

    deinit {
        stopCapturing()
    }

    public func startLive(streamInfo: LiveStreamInfo) {
        if publisher == nil {
            publisher = createRTMPPublisher()
        }
        var mutableStreamInfo = streamInfo

        mutableStreamInfo.audioConfiguration = audioConfiguration
        mutableStreamInfo.videoConfiguration = videoConfiguration

        self.streamInfo = mutableStreamInfo

        publisher?.start()
    }

    func stopLive() {
        uploading = false

        publisher?.stop()
        publisher = nil
    }

    public func stopCapturing() {
        videoCapture.running = false
        audioCapture.running = false
    }
}

private extension LiveSession {
    func createRTMPPublisher() -> Publisher {
        guard let streamInfo = streamInfo else {
            fatalError("streamInfo can not be nil!!!")
        }

        return RtmpPublisher(stream: streamInfo)
    }
}

private extension LiveSession {

    func pushFrame(frame: Frame) {
        guard let publisher = publisher else { return }

        if relativeTimestamp == 0 {
            relativeTimestamp = frame.timestamp
        }
        var realFrame = frame
        realFrame.timestamp = adjustTimestamp(timestamp: frame.timestamp)

        publisher.send(frame: realFrame)
    }

    func adjustTimestamp(timestamp: Timestamp) -> Timestamp {
        lock.wait()
        let currentTimestamp = timestamp - relativeTimestamp
        lock.signal()

        return currentTimestamp
    }

}

extension LiveSession: AudioCaptureDelegate, VideoCaptureDelegate {
    func captureOutput(capture: LiveAudioCapture, audioData: Data) {
        guard uploading else { return }

        audioEncoder.encodeAudioData(data: audioData, timeStamp: .now)
    }

    func captureOutput(capture: LiveVideoCapture, pixelBuffer: CVPixelBuffer) {
        guard uploading else { return }

        videoEncoder.encodeVideoData(pixelBuffer: pixelBuffer, timeStamp: .now)
    }
}

extension LiveSession: AudioEncoderDelegate, VideoEncoderDelegate {
    func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame) {
        guard uploading else { return }
        hasCaptureAudio = true

        if avAlignment {
            pushFrame(frame: audioFrame)
        }
    }

    func videoEncoder(encoder: VideoEncoder, frame: VideoFrame) {
        guard uploading else { return }

        if frame.isKeyFrame && self.hasCaptureAudio {
            hasCaptureKeyFrame = true
        }
        if avAlignment {
            pushFrame(frame: frame)
        }
    }
}

extension LiveSession: PublisherDelegate {
    func publisher(publisher: Publisher, publishStatus: LiveState) {
        if publishStatus == .start {
            if !uploading {
                hasCaptureAudio = false
                hasCaptureKeyFrame = false
                relativeTimestamp = 0
                uploading = true
            }
        }

        if publishStatus == .stop || publishStatus == .error {
            uploading = false
        }

        self.state = publishStatus
        delegate?.liveSession(session: self, liveStateDidChange: publishStatus)
    }

    func publisher(publisher: Publisher, bufferStatus: BufferState) {
        guard captureType.contains(.captureVideo) && adaptiveBitrate else { return }
        let videoBitRate = videoEncoder.videoBitRate

        if bufferStatus == .decline && videoBitRate < videoConfiguration.videoMaxBitRate {
            let adjustedVideoBitRate = videoBitRate + 50 * 1000 <= videoConfiguration.videoMaxBitRate ? videoBitRate + 50 * 1000 : videoConfiguration.videoMaxBitRate
            videoEncoder.videoBitRate = adjustedVideoBitRate
            print("[HPLiveKit] Increase bitrate \(adjustedVideoBitRate)")
            return
        }

        if bufferStatus == .increase && videoBitRate > videoConfiguration.videoMinBitRate {
            let adjustedVideoBitRate = videoBitRate - 100 * 1000 >= videoConfiguration.videoMinBitRate ? videoBitRate - 100 * 1000 : videoConfiguration.videoMinBitRate
            videoEncoder.videoBitRate = adjustedVideoBitRate
            print("[HPLiveKit] Decline bitrate \(adjustedVideoBitRate)")
            return
        }

    }

    func publisher(publisher: Publisher, errorCode: LiveSocketErrorCode) {
        delegate?.liveSession(session: self, errorCode: errorCode)
    }

    func publisher(publisher: Publisher, debugInfo: LiveDebug) {
        self.debugInfo = debugInfo
        if showDebugInfo {
            delegate?.liveSession(session: self, debugInfo: debugInfo)
        }
    }

}

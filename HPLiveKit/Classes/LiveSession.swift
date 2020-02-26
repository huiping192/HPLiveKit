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

@objc protocol LiveSessionDelegate {
    ///** live status changed will callback */
    @objc optional func liveSession(session: LiveSession, liveStateDidChange state: LiveState)
    ///** live debug info callback */
    @objc optional func liveSession(session: LiveSession, debugInfo: LiveState)
    ///** callback socket errorcode */
    @objc optional func liveSession(session: LiveSession, errorCode: LiveState)
}

@objc public class LiveSession: NSObject {

    private let audioConfiguration: LiveAudioConfiguration
    private let videoConfiguration: LiveVideoConfiguration

    // video,audio data source
    private var videoCapture: LiveVideoCapture?
    private var audioCapture: LiveAudioCapture?

    // encoder
    private var videoEncoder: VideoEncoder?
    private var audioEncoder: LiveAudioAACEncoder?

    // publisher
    private var socket: Publisher?

    /// 调试信息
    private var debugInfo: LiveDebug?
    /// 流信息
    private var streamInfo: LiveStreamInfo?
    /// 是否开始上传
    private var uploading: Bool = false
    /// 当前状态
    private var state: LiveState?
    /// 当前直播type
    private var captureType: LiveCaptureType = LiveCaptureTypeMask.captureDefaultMask
    /// 时间戳锁
    private var lock = DispatchSemaphore(value: 0)

    /// 上传相对时间戳
    private var relativeTimestamp: UInt64 = 0
    /// 音视频是否对齐
    private var avalignment: Bool? {
        if ( captureType.contains(LiveCaptureTypeMask.captureMaskVideo) || captureType.contains(LiveCaptureTypeMask.inputMaskAudio)) && (captureType.contains(LiveCaptureTypeMask.captureMaskVideo) || captureType.contains(LiveCaptureTypeMask.inputMaskVideo)) {

            return hasCaptureAudio && hasCaptureKeyFrame
        }

        return false
    }
    /// 当前是否采集到了音频
    private var hasCaptureAudio: Bool = false
    /// 当前是否采集到了关键帧
    private var hasCaptureKeyFrame: Bool = false

    public var perview: UIView? {
        get {
            return videoCapture?.perview
        }
        set {
            videoCapture?.perview = newValue
        }
    }

    public var warterMarkView: UIView? {
        get {
            return videoCapture?.warterMarkView
        }
        set {
            videoCapture?.warterMarkView = newValue
        }
    }

    public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
        self.audioConfiguration = audioConfiguration
        self.videoConfiguration = videoConfiguration

        videoCapture = LiveVideoCapture(videoConfiguration: videoConfiguration)
        audioCapture = LiveAudioCapture(configuration: audioConfiguration)
    }

    deinit {
        stopCapturing()
    }

    public func startLive(streamInfo: LiveStreamInfo) {
        var mutableStreamInfo = streamInfo
        mutableStreamInfo.videoConfiguration = self.videoConfiguration
        mutableStreamInfo.audioConfiguration = self.audioConfiguration

        self.streamInfo = mutableStreamInfo

        socket?.start()
    }

    func stopLive() {
        uploading = false

        socket?.stop()
        socket = nil
    }

    public func stopCapturing() {
        videoCapture?.running = false
        audioCapture?.running = false
    }
}

private extension LiveSession {

    func pushSendBuffer(frame: Frame) {
        if relativeTimestamp == 0 {
            relativeTimestamp = frame.timestamp
        }
        var realFrame = frame
        realFrame.timestamp = uploadTimestamp(timestamp: frame.timestamp)

        socket?.send(frame: realFrame)
    }

    func uploadTimestamp(timestamp: UInt64) -> UInt64 {
        lock.wait()

        var currentts = UInt64(0)
        currentts = timestamp - relativeTimestamp

        lock.signal()

        return currentts
    }

}

extension LiveSession: AudioCaptureDelegate, VideoCaptureDelegate {
    func captureOutput(capture: LiveAudioCapture, audioData: Data) {
        guard uploading else { return }

        audioEncoder?.encodeAudioData(data: audioData, timeStamp: .now)
    }

    func captureOutput(capture: LiveVideoCapture, pixelBuffer: CVPixelBuffer) {
        guard uploading else { return }

        videoEncoder?.encodeVideoData(pixelBuffer: pixelBuffer, timeStamp: .now)
    }
}

extension LiveSession: AudioEncoderDelegate, VideoEncoderDelegate {
    func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame) {
        guard uploading else { return }
        hasCaptureAudio = true

        if avalignment ?? false {
            pushSendBuffer(frame: audioFrame)
        }
    }

    func videoEncoder(encoder: VideoEncoder, frame: VideoFrame) {
        guard uploading else { return }

        if frame.isKeyFrame && self.hasCaptureAudio {
            hasCaptureKeyFrame = true
        }
        if avalignment ?? false {
            pushSendBuffer(frame: frame)
        }
    }
}

extension UInt64 {
    static var now: UInt64 {
        return UInt64(CACurrentMediaTime() * 1000)
    }
}

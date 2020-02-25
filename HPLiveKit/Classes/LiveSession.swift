//
//  LiveSession.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import UIKit

public class LiveSession {

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
    //    private var captureType: LiveCaptureTypeMask
    /// 时间戳锁
    private var lock = DispatchSemaphore(value: 0)

    /// 上传相对时间戳
    private var relativeTimestamp: UInt64?
    /// 音视频是否对齐
    private var avalignment: Bool?
    /// 当前是否采集到了音频
    private var hasCaptureAudio: Bool?
    /// 当前是否采集到了关键帧
    private var hasCaptureKeyFrame: Bool?

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

    func uploadTimestamp(timestamp: UInt64?) -> UInt64 {

        return 0
    }

}

extension LiveSession: AudioCaptureDelegate, VideoCaptureDelegate {
    func captureOutput(capture: LiveAudioCapture, audioData: Data?) {
        guard uploading else { return }

    }

    func captureOutput(capture: LiveVideoCapture, pixelBuffer: CVPixelBuffer?) {
        guard uploading else { return }

    }
}

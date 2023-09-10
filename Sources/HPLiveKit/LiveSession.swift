//
//  LiveSession.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import UIKit
import CoreMedia

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

    ///** callback socket errorcode */
    func liveSession(session: LiveSession, errorCode: LiveSocketErrorCode)

    ///** live debug info callback */
    func liveSession(session: LiveSession, debugInfo: LiveDebug)
}

extension LiveSessionDelegate {
    func liveSession(session: LiveSession, debugInfo: LiveDebug) {}
}

public class LiveSession: NSObject {

    // live stream call back delegate
    public weak var delegate: LiveSessionDelegate?

    /*  The adaptiveVideoBitrate control auto adjust video bitrate. Default is true */
    public var adaptiveVideoBitrate: Bool = true

    // video, audio configuration
    private let audioConfiguration: LiveAudioConfiguration
    private let videoConfiguration: LiveVideoConfiguration

    // video,audio data source
    private let capture: CaptureManager

    // video,audio encoder
    private let encoder: EncoderManager

    // 推流 publisher
    private var publisher: Publisher?

    // 视频保存 archive to local document
    private var filePublisher: FilePublisher = FilePublisher()

    // 调试信息 debug info
    private var debugInfo: LiveDebug?
    // 流信息 stream info
    private var streamInfo: LiveStreamInfo?
    // 是否开始上传  is publishing
    private var uploading: Bool = false
    // 当前状态 current live stream state
    private var state: LiveState?
    // 当前直播type current live type
    private var captureType: LiveCaptureType = LiveCaptureTypeMask.captureDefaultMask
    /// 当前是否采集到了音频
    private var hasCapturedAudio: Bool = false
    /// 当前是否采集到了关键帧
    private var hasCapturedKeyFrame: Bool = false

    public var preview: UIView? {
        get {
            capture.preview
        }
        set {
            capture.preview = newValue
        }
    }

    public var mute: Bool = false {
        didSet {
            capture.mute = mute
        }
    }
  
  public var captureDevicePositionFront: Bool = true {
    didSet {
      capture.captureDevicePositionFront = captureDevicePositionFront
    }
  }

    // 是否保存在本地文件
    // should save to local file, default is no
    public var saveLocalVideo: Bool = false

    public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
        self.audioConfiguration = audioConfiguration
        self.videoConfiguration = videoConfiguration

        capture = CaptureManager(audioConfiguration: audioConfiguration, videoConfiguration: videoConfiguration)
        encoder = EncoderManager(audioConfiguration: audioConfiguration, videoConfiguration: videoConfiguration)

        super.init()

        capture.delegate = self

        encoder.delegate = self
    }

    deinit {
        stopCapturing()
    }

  public func startLive(streamInfo: LiveStreamInfo) {
    Task {
      var mutableStreamInfo = streamInfo
      
      mutableStreamInfo.audioConfiguration = audioConfiguration
      mutableStreamInfo.videoConfiguration = videoConfiguration
      
      self.streamInfo = mutableStreamInfo
      
      if publisher == nil {
        publisher = createRTMPPublisher()
        await publisher?.setDelegate(delegate: self)
      }
      await publisher?.start()
    }
  }
  
  public func stopLive() {
    Task {
      uploading = false
      
      await publisher?.stop()
      publisher = nil
    }
  }

    public func startCapturing() {
        capture.startCapturing()
    }

    public func stopCapturing() {
        capture.stopCapturing()
    }
}

private extension LiveSession {
    func createRTMPPublisher() -> Publisher {
        guard let streamInfo = streamInfo else {
            fatalError("[HPLiveKit] streamInfo can not be nil!!!")
        }

        return RtmpPublisher(stream: streamInfo)
    }
}

private extension LiveSession {

    func pushFrame(frame: any Frame) {
      Task {
        guard let publisher = publisher else { return }

        await publisher.send(frame: frame)

        // save to file
        if saveLocalVideo {
            filePublisher.save(frame: frame)
        }
      }
    }
}

extension LiveSession: CaptureManagerDelegate {
  public func captureOutput(captureManager: CaptureManager, audio: CMSampleBuffer) {
    guard uploading else { return }
    
    encoder.encodeAudio(sampleBuffer: audio)
  }
  
  public func captureOutput(captureManager: CaptureManager, video: CMSampleBuffer) {
    guard uploading else { return }
    
    encoder.encodeVideo(sampleBuffer: video)
  }
}

extension LiveSession: EncoderManagerDelegate {
  public func encodeOutput(encoderManager: EncoderManager, audioFrame: AudioFrame) {
    guard uploading else { return }
    hasCapturedAudio = true
    
    pushFrame(frame: audioFrame)
  }
  
  public func encodeOutput(encoderManager: EncoderManager, videoFrame: VideoFrame) {
    guard uploading else { return }
    
    if videoFrame.isKeyFrame && self.hasCapturedAudio {
      hasCapturedKeyFrame = true
    }
    pushFrame(frame: videoFrame)
  }
}

extension LiveSession: PublisherDelegate {
    func publisher(publisher: Publisher, publishStatus: LiveState) {
        // reset status and start uploading data
        if publishStatus == .start && !uploading {
            hasCapturedAudio = false
            hasCapturedKeyFrame = false
            uploading = true
        }

        // stop uploading
        if publishStatus == .stop || publishStatus == .error {
            uploading = false
        }

        self.state = publishStatus
        delegate?.liveSession(session: self, liveStateDidChange: publishStatus)
    }

    func publisher(publisher: Publisher, bufferStatus: BufferState) {
        // only adjust video bitrate, audio cannot
        guard captureType.contains(.captureVideo) && adaptiveVideoBitrate else { return }

        let videoBitRate = encoder.videoBitRate

        if bufferStatus == .decline && videoBitRate < videoConfiguration.videoMaxBitRate {
            let adjustedVideoBitRate = min(videoBitRate + 50 * 1000, videoConfiguration.videoMaxBitRate)
            encoder.videoBitRate = adjustedVideoBitRate
            #if DEBUG
            print("[HPLiveKit] Increase bitrate \(videoBitRate) --> \(adjustedVideoBitRate)")
            #endif
            return
        }

        if bufferStatus == .increase && videoBitRate > videoConfiguration.videoMinBitRate {
            let adjustedVideoBitRate = max(videoBitRate - 100 * 1000, videoConfiguration.videoMinBitRate)
            encoder.videoBitRate = adjustedVideoBitRate
            #if DEBUG
            print("[HPLiveKit] Decline bitrate \(videoBitRate) --> \(adjustedVideoBitRate)")
            #endif
            return
        }

    }

    func publisher(publisher: Publisher, errorCode: LiveSocketErrorCode) {
        delegate?.liveSession(session: self, errorCode: errorCode)
    }

    func publisher(publisher: Publisher, debugInfo: LiveDebug) {
        self.debugInfo = debugInfo
        delegate?.liveSession(session: self, debugInfo: debugInfo)
    }

}

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

/// Live session mode
public enum LiveSessionMode {
    case camera        // Camera capture mode
    case screenShare   // Screen share mode (for RPBroadcastSampleHandler)
}

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

public protocol LiveSessionDelegate: AnyObject, Sendable {
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

public class LiveSession: NSObject, @unchecked Sendable {

    // live stream call back delegate
    public weak var delegate: LiveSessionDelegate?

    /*  The adaptiveVideoBitrate control auto adjust video bitrate. Default is true */
    public var adaptiveVideoBitrate: Bool = true

    // video, audio configuration
    private let audioConfiguration: LiveAudioConfiguration
    private let videoConfiguration: LiveVideoConfiguration

    // video,audio data source (only for camera mode)
    private let capture: CaptureManager?

    // video,audio encoder
    private let encoder: EncoderManager

    // 推流 publisher
    private var publisher: Publisher?

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
    // 当前模式 (camera or screenShare)
    private let mode: LiveSessionMode
    /// 当前是否采集到了音频
    private var hasCapturedAudio: Bool = false
    /// 当前是否采集到了关键帧
    private var hasCapturedKeyFrame: Bool = false

    // Frame processing with AsyncStream to ensure sequential order
    private let frameStream: AsyncStream<any Frame>
    private let frameContinuation: AsyncStream<any Frame>.Continuation
    private var frameProcessingTask: Task<Void, Never>?

    public var preview: UIView? {
        get {
            capture?.preview
        }
        set {
            capture?.preview = newValue
        }
    }

    public var mute: Bool = false {
        didSet {
            capture?.mute = mute
        }
    }

  public var captureDevicePositionFront: Bool = true {
    didSet {
      capture?.captureDevicePositionFront = captureDevicePositionFront
    }
  }


    public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration, mode: LiveSessionMode = .camera) {
        self.audioConfiguration = audioConfiguration
        self.videoConfiguration = videoConfiguration
        self.mode = mode

        // Only create CaptureManager in camera mode to avoid requesting camera/mic permissions
        if mode == .camera {
            capture = CaptureManager(audioConfiguration: audioConfiguration, videoConfiguration: videoConfiguration)
        } else {
            capture = nil
        }

        encoder = EncoderManager(audioConfiguration: audioConfiguration, videoConfiguration: videoConfiguration)

        // Initialize AsyncStream for frame processing
        var continuation: AsyncStream<any Frame>.Continuation!
        self.frameStream = AsyncStream<any Frame> { cont in
            continuation = cont
        }
        self.frameContinuation = continuation

        super.init()

        capture?.delegate = self
        encoder.delegate = self

        // Start frame processing task
        startFrameProcessing()
    }

    /// Screen share dedicated initializer
    /// - Parameters:
    ///   - videoEncodingQuality: Video encoding quality (default: .medium2)
    ///   - audioEncodingQuality: Audio encoding quality (default: .high)
    public convenience init(
        forScreenShare: Void = (),
        videoEncodingQuality: LiveVideoQuality = .medium2,
        audioEncodingQuality: LiveAudioQuality = .high
    ) {
        let videoConfig: LiveVideoConfiguration
        switch videoEncodingQuality {
        case .low1:
            videoConfig = LiveVideoConfigurationFactory.createLow1()
        case .low2:
            videoConfig = LiveVideoConfigurationFactory.createLow2()
        case .low3:
            videoConfig = LiveVideoConfigurationFactory.createLow3()
        case .medium1:
            videoConfig = LiveVideoConfigurationFactory.createMedium1()
        case .medium2:
            videoConfig = LiveVideoConfigurationFactory.createMedium2()
        case .medium3:
            videoConfig = LiveVideoConfigurationFactory.createMedium3()
        case .high1:
            videoConfig = LiveVideoConfigurationFactory.createHigh1()
        case .high2:
            videoConfig = LiveVideoConfigurationFactory.createHigh2()
        case .high3:
            videoConfig = LiveVideoConfigurationFactory.createHigh3()
        }

        let audioConfig: LiveAudioConfiguration
        switch audioEncodingQuality {
        case .low:
            audioConfig = LiveAudioConfigurationFactory.createLow()
        case .medium:
            audioConfig = LiveAudioConfigurationFactory.createMedium()
        case .high:
            audioConfig = LiveAudioConfigurationFactory.createHigh()
        case .veryHigh:
            audioConfig = LiveAudioConfigurationFactory.createVeryHigh()
        }

        self.init(audioConfiguration: audioConfig,
                  videoConfiguration: videoConfig,
                  mode: .screenShare)
    }

    deinit {
        stopCapturing()
        frameProcessingTask?.cancel()
        frameContinuation.finish()
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

      // Ensure frame processing task is running
      if frameProcessingTask == nil || frameProcessingTask?.isCancelled == true {
        startFrameProcessing()
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
        // Screen share mode does not use internal capture
        guard mode == .camera else { return }
        capture?.startCapturing()
    }

    public func stopCapturing() {
        // Screen share mode does not use internal capture
        guard mode == .camera else { return }
        capture?.stopCapturing()
    }

    // MARK: - Screen Share Methods

    /// Push video sample buffer (for RPBroadcastSampleHandler)
    /// - Parameter sampleBuffer: Video sample buffer from RPBroadcastSampleHandler
    public func pushVideo(_ sampleBuffer: CMSampleBuffer) {
        guard mode == .screenShare else {
            #if DEBUG
            print("[HPLiveKit] pushVideo is only available in screenShare mode")
            #endif
            return
        }
        guard uploading else { return }

        try? encoder.encodeVideo(sampleBuffer: sampleBuffer)
    }

    /// Push app audio sample buffer (for RPBroadcastSampleHandler)
    /// - Parameter sampleBuffer: App audio sample buffer from RPBroadcastSampleHandler
    public func pushAppAudio(_ sampleBuffer: CMSampleBuffer) {
        guard mode == .screenShare else {
            #if DEBUG
            print("[HPLiveKit] pushAppAudio is only available in screenShare mode")
            #endif
            return
        }
        guard uploading else { return }

        try? encoder.encodeAudio(sampleBuffer: sampleBuffer)
    }

    /// Push mic audio sample buffer (for RPBroadcastSampleHandler)
    /// - Parameter sampleBuffer: Mic audio sample buffer from RPBroadcastSampleHandler
    /// - Note: This method is reserved for future implementation. Currently not supported.
    public func pushMicAudio(_ sampleBuffer: CMSampleBuffer) {
        guard mode == .screenShare else {
            #if DEBUG
            print("[HPLiveKit] pushMicAudio is only available in screenShare mode")
            #endif
            return
        }
        // TODO: Implement mic audio mixing with app audio
        #if DEBUG
        print("[HPLiveKit] pushMicAudio is not implemented yet")
        #endif
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

    /// Start the frame processing task that sequentially processes frames from the stream
    func startFrameProcessing() {
        frameProcessingTask?.cancel()
        frameProcessingTask = Task { [weak self] in
            guard let self = self else { return }

            // Process frames sequentially in the order they are yielded
            // This ensures timestamp ordering is preserved
            for await frame in self.frameStream {
                guard let publisher = self.publisher else { continue }

                #if DEBUG
                // Log frame processing for debugging
                let frameType = frame is VideoFrame ? "Video" : "Audio"
                if let videoFrame = frame as? VideoFrame, videoFrame.isKeyFrame {
                    print("[LiveSession] Processing keyframe: \(frameType) timestamp=\(frame.timestamp)ms")
                }
                #endif

                await publisher.send(frame: frame)
            }
        }
    }

    func pushFrame(frame: any Frame) {
        // Use yield instead of creating a new Task
        // This ensures frames are processed in the exact order they are received
        frameContinuation.yield(frame)
    }
}

extension LiveSession: CaptureManagerDelegate {
  public func captureOutput(captureManager: CaptureManager, audio: CMSampleBuffer) {
    guard uploading else { return }

    try? encoder.encodeAudio(sampleBuffer: audio)
  }

  public func captureOutput(captureManager: CaptureManager, video: CMSampleBuffer) {
    guard uploading else { return }

    try? encoder.encodeVideo(sampleBuffer: video)
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
            encoder.resetTimestamp()  // Reset timestamp to start from 0
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

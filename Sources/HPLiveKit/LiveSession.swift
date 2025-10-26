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
import ReplayKit
import os

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
    private static let logger = Logger(subsystem: "com.hplivekit", category: "LiveSession")

    // live stream call back delegate
    public weak var delegate: LiveSessionDelegate?

    /*  The adaptiveVideoBitrate control auto adjust video bitrate. Default is true */
    public var adaptiveVideoBitrate: Bool = true

    // video, audio configuration
    private let audioConfiguration: LiveAudioConfiguration
    private let videoConfiguration: LiveVideoConfiguration

    // video,audio data source (only for camera mode)
    private let capture: CaptureManager?

    // video,audio encoders (Actor-based, thread-safe)
    private let audioEncoder: LiveAudioAACEncoder
    private let videoEncoder: LiveVideoH264Encoder

    // timestamp synchronizer
    private let timestampSynchronizer = TimestampSynchronizer()

    // Encoder output stream processing tasks
    private var audioEncoderTask: Task<Void, Never>?
    private var videoEncoderTask: Task<Void, Never>?
    private var mixerTask: Task<Void, Never>?

    // 推流 publisher
    private var publisher: Publisher?

    // Audio mixer (only for screenShare mode)
    private var audioMixer: AudioMixer?

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

        // Create encoders directly (no EncoderManager needed)
        audioEncoder = LiveAudioAACEncoder(configuration: audioConfiguration)
        videoEncoder = LiveVideoH264Encoder(configuration: videoConfiguration)

        // Initialize AsyncStream for frame processing
        var continuation: AsyncStream<any Frame>.Continuation!
        self.frameStream = AsyncStream<any Frame> { cont in
            continuation = cont
        }
        self.frameContinuation = continuation

        super.init()

        capture?.delegate = self

        // Start frame processing task
        startFrameProcessing()

        // Start encoder output stream subscriptions
        startEncoderStreams()

        // Setup audio mixer for screenShare mode
        if mode == .screenShare && audioConfiguration.audioMixingEnabled {
            audioMixer = AudioMixer(
                targetSampleRate: 48000,
                appVolume: audioConfiguration.appAudioVolume,
                micVolume: audioConfiguration.micAudioVolume
            )
            startMixerStream()
        }
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

        // Cancel encoder output stream tasks
        audioEncoderTask?.cancel()
        videoEncoderTask?.cancel()
        mixerTask?.cancel()
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
  
    /// Push sample buffer from RPBroadcastSampleHandler
    /// - Parameters:
    ///   - sampleBuffer: Sample buffer from RPBroadcastSampleHandler
    ///   - type: Sample buffer type (video, audioApp, or audioMic)
    public func push(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        guard mode == .screenShare else {
            #if DEBUG
            print("[HPLiveKit] push(_:type:) is only available in screenShare mode")
            #endif
            return
        }
        guard uploading else { return }

        timestampSynchronizer.recordIfNeeded(sampleBuffer)

        switch type {
        case .video:
            videoEncoder.encode(sampleBuffer: SampleBufferBox(samplebuffer: sampleBuffer))
        case .audioApp:
            audioMixer?.pushAppAudio(SampleBufferBox(samplebuffer: sampleBuffer))
        case .audioMic:
            audioMixer?.pushMicAudio(SampleBufferBox(samplebuffer: sampleBuffer))
        @unknown default:
            #if DEBUG
            print("[HPLiveKit] Unknown sample buffer type: \(type)")
            #endif
            break
        }
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
                await publisher?.send(frame: frame)
            }
        }
    }

    /// Start encoder output stream subscriptions
    /// Subscribe to encoder output streams and process encoded frames
    func startEncoderStreams() {
        // Subscribe to audio encoder output
        audioEncoderTask = Task { [weak self] in
            guard let self = self else { return }
            for await audioFrame in self.audioEncoder.outputStream {
                guard self.uploading else { continue }
                self.hasCapturedAudio = true

                let normalizedFrame = self.timestampSynchronizer.normalize(audioFrame)
                self.pushFrame(frame: normalizedFrame)
            }
        }

        // Subscribe to video encoder output
        videoEncoderTask = Task { [weak self] in
            guard let self = self else { return }
            for await videoFrame in self.videoEncoder.outputStream {
                guard self.uploading else { continue }

                if videoFrame.isKeyFrame && self.hasCapturedAudio {
                    self.hasCapturedKeyFrame = true
                }

                let normalizedFrame = self.timestampSynchronizer.normalize(videoFrame)
                self.pushFrame(frame: normalizedFrame)
            }
        }
    }

    /// Start audio mixer output stream subscription
    /// Subscribe to mixer output and encode mixed audio
    func startMixerStream() {
        guard let audioMixer = audioMixer else { return }

        mixerTask?.cancel()
        mixerTask = Task { [weak self] in
            guard let self = self else { return }
            for await mixedBufferBox in audioMixer.outputStream {
                guard self.uploading else { continue }

                // [DIAGNOSTIC] Before encoding (Scenario B: AudioMixer passthrough)
                let timestamp = CMSampleBufferGetPresentationTimeStamp(mixedBufferBox.samplebuffer)
                if let pcmData = AudioSampleBufferUtils.extractPCMData(from: mixedBufferBox.samplebuffer),
                   let format = AudioSampleBufferUtils.extractFormat(from: mixedBufferBox.samplebuffer) {
                    let rms = AudioSampleBufferUtils.calculateRMS(pcmData: pcmData, bitsPerChannel: Int(format.mBitsPerChannel))
                    Self.logger.info("[DIAGNOSTIC] SCENARIO-B (AudioMixer) ENCODE INPUT: ts=\(timestamp.seconds)s, size=\(pcmData.count), RMS=\(String(format: "%.4f", rms)), format=\(format.mSampleRate)Hz/\(format.mChannelsPerFrame)ch/\(format.mBitsPerChannel)bit")
                }

                // Mixed audio already has normalized timestamp from mixer
                // Directly encode without additional timestamp recording
                self.audioEncoder.encode(sampleBuffer: mixedBufferBox)
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

    timestampSynchronizer.recordIfNeeded(audio)
    // Directly encode audio (non-blocking, encoder is Actor-based)
    audioEncoder.encode(sampleBuffer: SampleBufferBox(samplebuffer: audio))
  }

  public func captureOutput(captureManager: CaptureManager, video: CMSampleBuffer) {
    guard uploading else { return }

    timestampSynchronizer.recordIfNeeded(video)
    // Directly encode video (non-blocking, encoder is Actor-based)
    videoEncoder.encode(sampleBuffer: SampleBufferBox(samplebuffer: video))
  }
}

extension LiveSession: PublisherDelegate {
    func publisher(publisher: Publisher, publishStatus: LiveState) {
        // reset status and start uploading data
        if publishStatus == .start && !uploading {
            hasCapturedAudio = false
            hasCapturedKeyFrame = false
            timestampSynchronizer.reset()  // Reset timestamp to start from 0
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

        // Adjust video bitrate asynchronously (encoder is Actor-based)
        Task { [weak self] in
            guard let self = self else { return }

            let videoBitRate = await self.videoEncoder.currentVideoBitRate

            if bufferStatus == .decline && videoBitRate < self.videoConfiguration.videoMaxBitRate {
                let adjustedVideoBitRate = min(videoBitRate + 50 * 1000, self.videoConfiguration.videoMaxBitRate)
                await self.videoEncoder.setVideoBitRate(adjustedVideoBitRate)
                #if DEBUG
                print("[HPLiveKit] Increase bitrate \(videoBitRate) --> \(adjustedVideoBitRate)")
                #endif
                return
            }

            if bufferStatus == .increase && videoBitRate > self.videoConfiguration.videoMinBitRate {
                let adjustedVideoBitRate = max(videoBitRate - 100 * 1000, self.videoConfiguration.videoMinBitRate)
                await self.videoEncoder.setVideoBitRate(adjustedVideoBitRate)
                #if DEBUG
                print("[HPLiveKit] Decline bitrate \(videoBitRate) --> \(adjustedVideoBitRate)")
                #endif
                return
            }
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

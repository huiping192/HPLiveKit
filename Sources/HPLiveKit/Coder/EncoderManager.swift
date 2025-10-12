//
//  EncoderManager.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2021/11/16.
//

import Foundation
import CoreVideo
import CoreMedia

public protocol EncoderManagerDelegate: AnyObject {
  func encodeOutput(encoderManager: EncoderManager, audioFrame: AudioFrame)
  func encodeOutput(encoderManager: EncoderManager, videoFrame: VideoFrame)
}

public class EncoderManager: NSObject {

  // video,audio encoder
  private var videoEncoder: VideoEncoder
  private let audioEncoder: AudioEncoder

  // Unified base timestamp for audio/video synchronization
  // Set to the timestamp of the first frame (audio or video) that arrives
  private var baseTimestamp: UInt64?

  public weak var delegate: EncoderManagerDelegate?

  public var videoBitRate: UInt {
    get {
      videoEncoder.videoBitRate
    }
    set {
      videoEncoder.videoBitRate = newValue
    }
  }

  public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration) {
    videoEncoder = LiveVideoH264Encoder(configuration: videoConfiguration)
    audioEncoder = LiveAudioAACEncoder(configuration: audioConfiguration)

    super.init()

    videoEncoder.delegate = self
    audioEncoder.delegate = self
  }

  public func encodeAudio(sampleBuffer: CMSampleBuffer) {
    audioEncoder.encode(sampleBuffer: sampleBuffer)
  }

  public func encodeVideo(sampleBuffer: CMSampleBuffer) {
    videoEncoder.encode(sampleBuffer: sampleBuffer)
  }

  /// Reset base timestamp (call when starting a new stream)
  public func resetTimestamp() {
    baseTimestamp = nil
  }
}

extension EncoderManager: AudioEncoderDelegate, VideoEncoderDelegate {
  func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame) {
    // Record the first frame's timestamp as base (audio or video, whichever comes first)
    if baseTimestamp == nil {
      baseTimestamp = audioFrame.timestamp
    }

    // Create normalized frame with adjusted timestamp
    let normalizedFrame = AudioFrame(
      timestamp: audioFrame.timestamp - baseTimestamp!,
      data: audioFrame.data,
      header: audioFrame.header,
      aacHeader: audioFrame.aacHeader
    )

    delegate?.encodeOutput(encoderManager: self, audioFrame: normalizedFrame)
  }

  func videoEncoder(encoder: VideoEncoder, frame: VideoFrame) {
    // Record the first frame's timestamp as base (audio or video, whichever comes first)
    if baseTimestamp == nil {
      baseTimestamp = frame.timestamp
    }

    // Create normalized frame with adjusted timestamp
    let normalizedFrame = VideoFrame(
      timestamp: frame.timestamp - baseTimestamp!,
      data: frame.data,
      header: frame.header,
      isKeyFrame: frame.isKeyFrame,
      compositionTime: frame.compositionTime,
      sps: frame.sps,
      pps: frame.pps
    )

    delegate?.encodeOutput(encoderManager: self, videoFrame: normalizedFrame)
  }
}

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

  public func encodeAudio(sampleBuffer: CMSampleBuffer) throws {
    // Set baseTimestamp from the first audio/video frame that arrives (before encoding)
    if baseTimestamp == nil {
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      baseTimestamp = UInt64(CMTimeGetSeconds(pts) * 1000)
    }
    try audioEncoder.encode(sampleBuffer: sampleBuffer)
  }

  public func encodeVideo(sampleBuffer: CMSampleBuffer) throws {
    // Set baseTimestamp from the first audio/video frame that arrives (before encoding)
    if baseTimestamp == nil {
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      baseTimestamp = UInt64(CMTimeGetSeconds(pts) * 1000)
    }
    try videoEncoder.encode(sampleBuffer: sampleBuffer)
  }

  /// Reset base timestamp (call when starting a new stream)
  public func resetTimestamp() {
    baseTimestamp = nil
  }
}

extension EncoderManager: AudioEncoderDelegate, VideoEncoderDelegate {
  func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame) {
    // baseTimestamp is already set in encodeAudio/encodeVideo before encoding
    guard let base = baseTimestamp else { return }

    // Create normalized frame with adjusted timestamp
    let normalizedFrame = AudioFrame(
      timestamp: audioFrame.timestamp - base,
      data: audioFrame.data,
      header: audioFrame.header,
      aacHeader: audioFrame.aacHeader
    )

    delegate?.encodeOutput(encoderManager: self, audioFrame: normalizedFrame)
  }

  func videoEncoder(encoder: VideoEncoder, frame: VideoFrame) {
    // baseTimestamp is already set in encodeAudio/encodeVideo before encoding
    guard let base = baseTimestamp else { return }

    // Create normalized frame with adjusted timestamp
    let normalizedFrame = VideoFrame(
      timestamp: frame.timestamp - base,
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

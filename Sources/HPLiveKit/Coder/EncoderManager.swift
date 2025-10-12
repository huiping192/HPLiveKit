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

  public weak var delegate: EncoderManagerDelegate?

  // Base timestamp for relative timing (starts from first frame)
  private var baseTimestamp: CMTime?
  private let timestampLock = NSLock()

  public var videoBitRate: UInt {
    get {
      videoEncoder.videoBitRate
    }
    set {
      videoEncoder.videoBitRate = newValue
    }
  }
  
  public init(audioConfiguration: LiveAudioConfiguration, videoConfiguration: LiveVideoConfiguration, mode: LiveSessionMode) {
    videoEncoder = LiveVideoH264Encoder(configuration: videoConfiguration, mode: mode)
    audioEncoder = LiveAudioAACEncoder(configuration: audioConfiguration)

    super.init()

    videoEncoder.delegate = self
    audioEncoder.delegate = self
  }
  
  public func encodeAudio(sampleBuffer: CMSampleBuffer) {
    let normalizedBuffer = normalizeTimestamp(sampleBuffer: sampleBuffer)
    audioEncoder.encode(sampleBuffer: normalizedBuffer)
  }

  public func encodeVideo(sampleBuffer: CMSampleBuffer) {
    let normalizedBuffer = normalizeTimestamp(sampleBuffer: sampleBuffer)
    videoEncoder.encode(sampleBuffer: normalizedBuffer)
  }

  // Normalize timestamp to start from 0
  private func normalizeTimestamp(sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
    timestampLock.lock()
    defer { timestampLock.unlock() }

    let originalTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Record first timestamp as base
    if baseTimestamp == nil {
      baseTimestamp = originalTimestamp
      #if DEBUG
      print("[EncoderManager] Base timestamp set to \(originalTimestamp.seconds)s")
      #endif
    }

    guard let baseTimestamp = baseTimestamp else {
      return sampleBuffer
    }

    // Calculate relative timestamp
    let relativeTimestamp = CMTimeSubtract(originalTimestamp, baseTimestamp)

    // Create new sample buffer with relative timestamp
    var timingInfo = CMSampleTimingInfo(
      duration: CMSampleBufferGetDuration(sampleBuffer),
      presentationTimeStamp: relativeTimestamp,
      decodeTimeStamp: CMTime.invalid
    )

    var newSampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timingInfo,
      sampleBufferOut: &newSampleBuffer
    )

    if status == noErr, let newBuffer = newSampleBuffer {
      return newBuffer
    } else {
      #if DEBUG
      print("[EncoderManager] Failed to create normalized sample buffer, using original")
      #endif
      return sampleBuffer
    }
  }

  // Reset base timestamp (call when starting a new stream)
  public func resetTimestamp() {
    timestampLock.lock()
    baseTimestamp = nil
    timestampLock.unlock()
    #if DEBUG
    print("[EncoderManager] Timestamp reset")
    #endif
  }
}

extension EncoderManager: AudioEncoderDelegate, VideoEncoderDelegate {
  func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame) {
    delegate?.encodeOutput(encoderManager: self, audioFrame: audioFrame)
  }
  
  func videoEncoder(encoder: VideoEncoder, frame: VideoFrame) {
    delegate?.encodeOutput(encoderManager: self, videoFrame: frame)
  }
}

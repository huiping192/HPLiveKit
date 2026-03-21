//
//  LiveDebug.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public struct LiveDebug: Sendable {
  /// Stream URLs
  public var uploadUrl: String?
  /// Uploaded resolution
  public var videoSize: CGSize?
  /// Time elapsed since the last statistic, in milliseconds
  public var elapsedMilli: CGFloat = 0
  /// Current timestamp, used for calculating data within 1 second
  public var currentTimeStamp: CGFloat = 0
  /// Total data size
  public var allDataSize: CGFloat = 0
  /// Bandwidth per second
  public var bandwidthPerSec: CGFloat = 0
  /// Last measured bandwidth
  public var currentBandwidth: CGFloat = 0

  /// Number of frames dropped
  public var dropFrameCount: Int = 0
  /// Total number of frames
  public var totalFrameCount: Int = 0

  /// Number of audio captures per second
  public var capturedAudioCountPerSec: Int = 0
  /// Number of video captures per second
  public var capturedVideoCountPerSec: Int = 0

  /// Last measured number of audio captures
  public var currentCapturedAudioCount: Int = 0
  /// Last measured number of video captures
  public var currentCapturedVideoCount: Int = 0

  /// Number of unsent frames (representing current buffer waiting to be sent)
  public var unsendCount: Int = 0
}

extension LiveDebug: CustomStringConvertible {
  public var description: String {
    return String(format: "Dropped Frames: %ld Total Frames: %ld Last Audio Captures: %d Last Video Captures: %d Unsent Count: %ld Total Data Size: %0.f", dropFrameCount, totalFrameCount, currentCapturedAudioCount, currentCapturedVideoCount, unsendCount, allDataSize)
  }
}


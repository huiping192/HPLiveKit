//
//  VideoEncoder.swift
//  FBSnapshotTestCase
//
//  Created by Huiping Guo on 2020/02/24.
//

import Foundation
import AVFoundation

/// Video encoder protocol using Swift 6 Actor model for thread safety
/// Output is delivered via AsyncStream instead of delegate callbacks
protocol VideoEncoder: Actor {

  /// Output stream for encoded video frames
  /// Subscribe to this stream to receive encoded frames asynchronously
  var outputStream: AsyncStream<VideoFrame> { get }

  /// Encodes a video sample buffer (non-blocking)
  /// This method returns immediately and yields the sample buffer to internal processing stream
  /// - Parameter sampleBuffer: The video sample buffer containing raw video data
  nonisolated func encode(sampleBuffer: CMSampleBuffer)

  /// Dynamically adjusts the video bit rate
  /// Higher bit rate means better quality but increased bandwidth
  /// - Parameter bitRate: New bit rate value in bits per second
  func setVideoBitRate(_ bitRate: UInt) async

  /// Gets the current video bit rate
  var currentVideoBitRate: UInt { get }

  /// Stops the encoder and finishes all streams
  func stop()
}

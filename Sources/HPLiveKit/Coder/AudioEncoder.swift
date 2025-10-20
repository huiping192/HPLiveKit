//
//  AudioEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/26.
//

import Foundation
import CoreMedia

/// Audio encoder protocol using Swift 6 Actor model for thread safety
/// Output is delivered via AsyncStream instead of delegate callbacks
protocol AudioEncoder: Actor {
  /// Output stream for encoded audio frames
  /// Subscribe to this stream to receive encoded frames asynchronously
  var outputStream: AsyncStream<AudioFrame> { get }

  /// Encodes an audio sample buffer (non-blocking)
  /// This method returns immediately and yields the sample buffer to internal processing stream
  /// - Parameter sampleBuffer: The audio sample buffer to encode
  nonisolated func encode(sampleBuffer: CMSampleBuffer)

  /// Stops the encoder and finishes all streams
  func stop()
}

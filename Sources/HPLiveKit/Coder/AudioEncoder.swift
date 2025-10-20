//
//  AudioEncoder.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/26.
//

import Foundation
import CoreMedia

protocol AudioEncoderDelegate: AnyObject {
  func audioEncoder(encoder: AudioEncoder, audioFrame: AudioFrame)
}

protocol AudioEncoder: AnyObject {
  var delegate: AudioEncoderDelegate? {
    get
    set
  }

  /// Encodes an audio sample buffer
  /// - Parameter sampleBuffer: The audio sample buffer to encode
  /// - Throws: LiveError if encoding fails
  func encode(sampleBuffer: CMSampleBuffer) throws

  func stop()
}

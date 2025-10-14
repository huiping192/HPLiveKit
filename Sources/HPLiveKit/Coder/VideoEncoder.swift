//
//  VideoEncoder.swift
//  FBSnapshotTestCase
//
//  Created by Huiping Guo on 2020/02/24.
//

import Foundation
import AVFoundation

// Protocol for handling video encoding events
protocol VideoEncoderDelegate: AnyObject {
  
  // This method is called whenever the encoder successfully encodes a video frame.
  // The encoded frame is passed as an argument.
  func videoEncoder(encoder: VideoEncoder, frame: VideoFrame)
}

// Protocol for encoding video data
protocol VideoEncoder: AnyObject {

  // Method to encode a video frame.
  // The sample buffer contains the raw video data that needs to be encoded.
  // Throws LiveError if encoding fails.
  func encode(sampleBuffer: CMSampleBuffer) throws
  
  // Property representing the bit rate of the video encoder.
  // Higher bit rate generally means better video quality but increased bandwidth consumption.
  var videoBitRate: UInt { get set }
  
  // Initializer for the VideoEncoder.
  // The configuration specifies various encoding settings like resolution, frame rate, etc.
  init(configuration: LiveVideoConfiguration)
  
  // Delegate property for receiving encoding events.
  // The delegate must conform to `VideoEncoderDelegate`.
  var delegate: VideoEncoderDelegate? { get set }
  
  // Method to stop the encoder.
  // This can be useful to release resources when encoding is not needed.
  func stop()
}

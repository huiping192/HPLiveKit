//
//  VideoEncoder.swift
//  FBSnapshotTestCase
//
//  Created by Huiping Guo on 2020/02/24.
//

import Foundation
import AVFoundation

// 编码器编码后回调
protocol VideoEncoderDelegate: class {
  func videoEncoder(encoder: VideoEncoder, frame: VideoFrame)
}

protocol VideoEncoder: class {
  
  func encodeVideoData(sampleBuffer: CMSampleBuffer)
  
  var videoBitRate: UInt {
    get
    set
  }
  
  init(configuration: LiveVideoConfiguration)
  
  var delegate: VideoEncoderDelegate? {
    get
    set
  }
  
  func stopEncoder()
}

//
//  LiveVideoConfiguration.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import AVFoundation
import UIKit
public enum LiveVideoSessionPreset {
  /// Low resolution
  case preset360x640
  /// Medium resolution
  case preset540x960
  /// High resolution
  case preset720x1280
  
  var avSessionPreset: AVCaptureSession.Preset {
    switch self {
    case .preset360x640:
      return .vga640x480
    case .preset540x960:
      return .iFrame960x540
    case .preset720x1280:
      return .hd1280x720
    }
  }
  
  var cameraImageSize: CGSize {
    var size: CGSize
    switch self {
    case .preset360x640:
      size = CGSize(width: 360, height: 640)
    case .preset540x960:
      size = CGSize(width: 540, height: 960)
    case .preset720x1280:
      size = CGSize(width: 720, height: 1280)
    }
    
    return size
  }
}

/// Video Quality
public enum LiveVideoQuality {
  /// Resolution: 360 * 640, Frame Rate: 15, Bitrate: 500Kbps
  case low1
  /// Resolution: 360 * 640, Frame Rate: 24, Bitrate: 800Kbps
  case low2
  /// Resolution: 360 * 640, Frame Rate: 30, Bitrate: 800Kbps
  case low3
  /// Resolution: 540 * 960, Frame Rate: 15, Bitrate: 800Kbps
  case medium1
  /// Resolution: 540 * 960, Frame Rate: 24, Bitrate: 800Kbps
  case medium2
  /// Resolution: 540 * 960, Frame Rate: 30, Bitrate: 800Kbps
  case medium3
  /// Resolution: 720 * 1280, Frame Rate: 15, Bitrate: 1000Kbps
  case high1
  /// Resolution: 720 * 1280, Frame Rate: 24, Bitrate: 1200Kbps
  case high2
  /// Resolution: 720 * 1280, Frame Rate: 30, Bitrate: 1200Kbps
  case high3
}

public struct LiveVideoConfiguration: @unchecked Sendable {
  // Video resolution, width and height should be set as multiples of 2 to avoid green borders during decoding and playback.
  let videoSize: CGSize
  
  // Whether the output image is aspect-ratio-respectful. Default is false.
  var videoSizeRespectingAspectRatio: Bool = false
  
  // Video output orientation
  var outputImageOrientation: UIInterfaceOrientation = .portrait
  
  // Auto rotation (here, only supports left-to-right and portrait-to-portraitUpsideDown)
  var autorotate: Bool = true
  
  // Video frame rate, i.e., fps
  let videoFrameRate: UInt
  
  // Video minimum frame rate, i.e., fps
  let videoMinFrameRate: UInt
  // Video maximum frame rate, i.e., fps
  let videoMaxFrameRate: UInt
  
  // Maximum keyframe interval, can be set to 2 times the fps, affects the size of a gop
  var videoMaxKeyframeInterval: UInt {
    videoFrameRate * 2
  }
  
  // Video bitrate, unit is bps
  let videoBitRate: UInt
  // Video maximum bitrate, unit is bps
  let videoMaxBitRate: UInt
  
  // Video minimum bitrate, unit is bps
  let videoMinBitRate: UInt
  
  // Session preset for resolution
  let sessionPreset: LiveVideoSessionPreset
  
  // System session preset for resolution
  var avSessionPreset: AVCaptureSession.Preset {
    sessionPreset.avSessionPreset
  }
}


extension LiveVideoConfiguration {
  var isLandscape: Bool {
    outputImageOrientation == .landscapeLeft || outputImageOrientation == .landscapeRight
  }
  
  // for internal use
  var internalVideoSize: CGSize {
    if videoSizeRespectingAspectRatio {
      return aspectRatioVideoSize
    }
    
    return orientationFormatVideoSize
  }
  
  var orientationFormatVideoSize: CGSize {
    if !isLandscape {
      return videoSize
    }
    return CGSize(width: videoSize.height, height: videoSize.width)
  }
  
  var aspectRatioVideoSize: CGSize {
    let size = AVMakeRect(aspectRatio: sessionPreset.cameraImageSize, insideRect: CGRect(x: 0, y: 0, width: orientationFormatVideoSize.width, height: orientationFormatVideoSize.height) )
    
    var width: Int = Int(ceil(size.width))
    var height: Int = Int(ceil(size.height))
    
    width = width % 2 == 0 ? width :  width - 1
    height = height % 2 == 0 ? height :  height - 1
    
    return CGSize(width: width, height: height)
  }
  
}

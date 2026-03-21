//
//  LiveVideoConfiguration.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation
import CoreGraphics

/// Video output orientation (platform-agnostic replacement for UIInterfaceOrientation)
public enum VideoOutputOrientation: Sendable {
  case portrait
  case portraitUpsideDown
  case landscapeLeft
  case landscapeRight
}

public enum LiveVideoSessionPreset {
  /// Low resolution
  case preset360x640
  /// Medium resolution
  case preset540x960
  /// High resolution
  case preset720x1280

  var cameraImageSize: CGSize {
    switch self {
    case .preset360x640:
      return CGSize(width: 360, height: 640)
    case .preset540x960:
      return CGSize(width: 540, height: 960)
    case .preset720x1280:
      return CGSize(width: 720, height: 1280)
    }
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
  package let videoSize: CGSize

  // Whether the output image is aspect-ratio-respectful. Default is false.
  package var videoSizeRespectingAspectRatio: Bool = false

  // Video output orientation
  package var outputImageOrientation: VideoOutputOrientation = .portrait

  // Auto rotation (here, only supports left-to-right and portrait-to-portraitUpsideDown)
  package var autorotate: Bool = true

  // Video frame rate, i.e., fps
  package let videoFrameRate: UInt

  // Video minimum frame rate, i.e., fps
  package let videoMinFrameRate: UInt
  // Video maximum frame rate, i.e., fps
  package let videoMaxFrameRate: UInt

  // Maximum keyframe interval, can be set to 2 times the fps, affects the size of a gop
  package var videoMaxKeyframeInterval: UInt {
    videoFrameRate * 2
  }

  // Video bitrate, unit is bps
  package let videoBitRate: UInt
  // Video maximum bitrate, unit is bps
  package let videoMaxBitRate: UInt

  // Video minimum bitrate, unit is bps
  package let videoMinBitRate: UInt

  // Session preset for resolution
  package let sessionPreset: LiveVideoSessionPreset
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
    let aspectRatio = sessionPreset.cameraImageSize
    let insideSize = orientationFormatVideoSize

    // Pure CoreGraphics replacement for AVMakeRect(aspectRatio:insideRect:)
    let widthRatio = insideSize.width / aspectRatio.width
    let heightRatio = insideSize.height / aspectRatio.height
    let scale = min(widthRatio, heightRatio)
    let fittedSize = CGSize(width: aspectRatio.width * scale, height: aspectRatio.height * scale)

    var width: Int = Int(ceil(fittedSize.width))
    var height: Int = Int(ceil(fittedSize.height))

    width = width % 2 == 0 ? width : width - 1
    height = height % 2 == 0 ? height : height - 1

    return CGSize(width: width, height: height)
  }
}

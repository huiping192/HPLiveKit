//
//  VideoFrame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public struct VideoFrame: Frame {
  public let timestamp: UInt64
  
  public let data: Data?
  
  public let header: Data?
  
  public let isKeyFrame: Bool
  
  // compositionTime = (presentationTimeStamp - decodeTimeStamp) * 1000
  // signed Int24
  public let compositionTime: Int32
  public let sps: Data?
  public let pps: Data?
  
  
  public static func == (lhs: VideoFrame, rhs: VideoFrame) -> Bool {
    return lhs.timestamp == rhs.timestamp && lhs.data == rhs.data
  }
}

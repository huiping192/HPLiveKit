//
//  VideoFrame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public class VideoFrame: Frame {
  public var isKeyFrame: Bool = false
  
  // compositionTime = (presentationTimeStamp - decodeTimeStamp) * 1000
  // signed Int24
  public var compositionTime: Int32 = 0
  public var sps: Data?
  public var pps: Data?
}

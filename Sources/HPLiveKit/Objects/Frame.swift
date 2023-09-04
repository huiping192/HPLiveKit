//
//  Frame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public class Frame: Equatable {
  // decodeTimeStamp
  public var timestamp: UInt64 = 0
    
  // frame data
  public var data: Data?
  
  // rtmp header data
  public var header: Data?
  
  public static func == (lhs: Frame, rhs: Frame) -> Bool {
    return lhs.timestamp == rhs.timestamp && lhs.data == lhs.data
  }
}

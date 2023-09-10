//
//  AudioFrame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public struct AudioFrame: Frame {
  public static func == (lhs: AudioFrame, rhs: AudioFrame) -> Bool {
    return lhs.timestamp == rhs.timestamp && lhs.data == rhs.data
  }
  
  public let timestamp: UInt64
  
  public let data: Data?
  
  public let header: Data?
  
  public let aacHeader: Data?
}

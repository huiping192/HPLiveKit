//
//  Frame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public protocol Frame: Equatable, Sendable {
  // decodeTimeStamp
  var timestamp: UInt64  { get }

  // frame data
  var data: Data?  { get }

  // rtmp header data
  var header: Data?  { get }
}

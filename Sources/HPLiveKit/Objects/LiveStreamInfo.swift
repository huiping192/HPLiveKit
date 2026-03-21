//
//  LiveStreamInfo.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2018/08/20.
//  Copyright © 2018 Huiping Guo. All rights reserved.
//

import Foundation

// Stream status
public enum LiveState: Int, Sendable {
  /// Ready
  case ready = 0
  /// Connecting
  case pending = 1
  /// Connected
  case start = 2
  /// Disconnected
  case stop = 3
  /// Connection error
  case error = 4
  /// Refreshing
  case refresh = 5
}

// Socket Error Codes
public enum LiveSocketErrorCode: Int, Sendable {
  /// Preview failure
  case previewFail = 201
  /// Failed to get stream info
  case getStreamInfo = 202
  /// Failed to connect socket
  case connectSocket = 203
  /// Failed to verify the server
  case verification = 204
  /// Reconnection timeout
  case reconnectTimeOut = 205
}

// Stream Information
public struct LiveStreamInfo: Sendable, Equatable {
  public let id: String
  public let url: String

  var audioConfiguration: LiveAudioConfiguration?
  var videoConfiguration: LiveVideoConfiguration?

  public init(url: String, id: String = UUID().uuidString) {
    self.id = id
    self.url = url
  }

  public static func == (lhs: LiveStreamInfo, rhs: LiveStreamInfo) -> Bool {
    lhs.id == rhs.id
  }
}

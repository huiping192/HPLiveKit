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
public struct LiveStreamInfo: Sendable {
  // --- RTMP ---
  
  public let url: String
  
  /// Audio Configuration
  var audioConfiguration: LiveAudioConfiguration?
  /// Video Configuration
  var videoConfiguration: LiveVideoConfiguration?
  
  public init(url: String) {
    self.url = url
  }
}

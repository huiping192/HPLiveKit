//
//  Publisher.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/25.
//

import Foundation

protocol PublisherDelegate: AnyObject, Sendable {
  /** callback buffer current status */
  func publisher(publisher: Publisher, bufferStatus: BufferState)
  /** callback publish current status */
  func publisher(publisher: Publisher, publishStatus: LiveState)
  /** callback publish error */
  func publisher(publisher: Publisher, errorCode: LiveSocketErrorCode)
  /** callback debugInfo */
  func publisher(publisher: Publisher, debugInfo: LiveDebug)
}

protocol Publisher: Sendable {

  func setDelegate(delegate: PublisherDelegate?) async

  // start publishing
  func start() async

  // stop publishing
  func stop() async

  // send video or video frame data
  func send(frame: any Frame) async
}

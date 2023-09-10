//
//  Publisher.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/25.
//

import Foundation

protocol PublisherDelegate: class {
    /** callback buffer current status (回调当前缓冲区情况，可实现相关切换帧率 码率等策略)*/
    func publisher(publisher: Publisher, bufferStatus: BufferState)
    /** callback publish current status (回调当前网络情况) */
    func publisher(publisher: Publisher, publishStatus: LiveState)
    /** callback publish error */
    func publisher(publisher: Publisher, errorCode: LiveSocketErrorCode)
    /** callback debugInfo */
    func publisher(publisher: Publisher, debugInfo: LiveDebug)
}

protocol Publisher {
  
  func setDelegate(delegate: PublisherDelegate?) async
  
  // start publishing
  func start() async
  
  // stop publishing
  func stop() async
  
  // send video or video frame data
  func send(frame: any Frame) async
}

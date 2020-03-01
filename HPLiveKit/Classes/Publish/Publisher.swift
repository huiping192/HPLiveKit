//
//  Publisher.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/25.
//

import Foundation

protocol PublisherDelegate: class {
    /** callback buffer current status (回调当前缓冲区情况，可实现相关切换帧率 码率等策略)*/
    func socketBufferStatus(publisher: Publisher, status: BufferState)
    /** callback socket current status (回调当前网络情况) */
    func socketStatus(publisher: Publisher, status: LiveState)
    /** callback socket errorcode */
    func socketDidError(publisher: Publisher, errorCode: LiveSocketErrorCode)

    /** callback debugInfo */
    func socketDebug(publisher: Publisher, debugInfo: LiveDebug)
}

protocol Publisher {
    var delegate: PublisherDelegate? {
        get
        set
    }

    func start()
    func stop()

    func send(frame: Frame)
}

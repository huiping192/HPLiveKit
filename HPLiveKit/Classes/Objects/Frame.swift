//
//  Frame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

class Frame: Equatable {
    // pts
    var timestamp: Timestamp = 0

    // frame data
    var data: Data?

    // rtmp包头
    // rtmp header data
    var header: Data?

    static func == (lhs: Frame, rhs: Frame) -> Bool {
        return lhs.timestamp == rhs.timestamp && lhs.data == lhs.data
    }
}

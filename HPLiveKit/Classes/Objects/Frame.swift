//
//  Frame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

public class Frame: Equatable {
    // pts
    public var timestamp: Timestamp = 0

    // frame data
    public var data: Data?

    // rtmp包头
    // rtmp header data
    public var header: Data?

    public static func == (lhs: Frame, rhs: Frame) -> Bool {
        return lhs.timestamp == rhs.timestamp && lhs.data == lhs.data
    }
}

//
//  Frame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

class Frame: Equatable {
    var timestamp: Timestamp = 0
    var data: Data?

    ///< flv或者rtmp包头
    var header: Data?

    static func == (lhs: Frame, rhs: Frame) -> Bool {
        return lhs.timestamp == rhs.timestamp && lhs.data == lhs.data
    }
}

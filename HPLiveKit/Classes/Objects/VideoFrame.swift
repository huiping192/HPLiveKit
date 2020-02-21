//
//  VideoFrame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

struct VideoFrame: Frame {
    var timestampe: UInt64
    var data: Data
    var header: Data

    var isKeyFrame: Bool

    var sps: Data
    var pps: Data
}

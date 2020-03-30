//
//  VideoFrame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

class VideoFrame: Frame {
    var isKeyFrame: Bool = false

    var sps: Data?
    var pps: Data?
}

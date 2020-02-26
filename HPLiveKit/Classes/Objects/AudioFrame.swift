//
//  AudioFrame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

struct AudioFrame: Frame {
    var timestamp: UInt64 = 0

    var data: Data?

    var header: Data?

    /// flv打包中aac的header
    var audioInfo: Data?
}

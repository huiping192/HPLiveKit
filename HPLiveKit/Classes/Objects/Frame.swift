//
//  Frame.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/02/21.
//

import Foundation

protocol Frame {
    var timestampe: UInt64 {
        get
    }
    var data: Data {
        get
    }

    /////< flv或者rtmp包头
    var header: Data {
        get
    }
}

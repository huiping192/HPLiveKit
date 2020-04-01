//
//  UInt64Extension.swift
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/04/02.
//

import Foundation

typealias Timestamp = UInt64

extension UInt64 {
    static var now: UInt64 {
        UInt64(CACurrentMediaTime() * 1000)
    }
}
